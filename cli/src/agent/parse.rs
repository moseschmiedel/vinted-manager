//! Turn each agent's own JSON stream into one common `Event` format.

use serde_json::{Value, json};

/// What every front end (terminal, macOS app, …) sees from an agent run.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Started {
        session_id: String,
        model: Option<String>,
    },
    Message {
        text: String,
    },
    Tool {
        name: String,
        detail: String,
    },
    Finished {
        summary: Option<String>,
        is_error: bool,
        cost_usd: Option<f64>,
    },
    Notice {
        text: String,
    },
}

impl Event {
    pub fn to_json(&self) -> Value {
        match self {
            Event::Started { session_id, model } => {
                json!({"type": "started", "session_id": session_id, "model": model})
            }
            Event::Message { text } => json!({"type": "message", "text": text}),
            Event::Tool { name, detail } => json!({"type": "tool", "name": name, "detail": detail}),
            Event::Finished {
                summary,
                is_error,
                cost_usd,
            } => {
                json!({"type": "finished", "summary": summary, "is_error": is_error, "cost_usd": cost_usd})
            }
            Event::Notice { text } => json!({"type": "notice", "text": text}),
        }
    }
}

fn str_of(value: &Value) -> String {
    value.as_str().unwrap_or("").to_string()
}

/// `claude -p --output-format stream-json --verbose`
pub fn claude(line: &str) -> Vec<Event> {
    let Ok(event) = serde_json::from_str::<Value>(line) else {
        return vec![];
    };
    match event["type"].as_str() {
        Some("system") if event["subtype"] == "init" => vec![Event::Started {
            session_id: str_of(&event["session_id"]),
            model: event["model"].as_str().map(String::from),
        }],
        Some("assistant") => event["message"]["content"]
            .as_array()
            .map(|blocks| {
                blocks
                    .iter()
                    .filter_map(|block| match block["type"].as_str() {
                        Some("text") => {
                            let text = str_of(&block["text"]).trim().to_string();
                            (!text.is_empty()).then_some(Event::Message { text })
                        }
                        Some("tool_use") => Some(Event::Tool {
                            name: block["name"].as_str().unwrap_or("tool").to_string(),
                            detail: describe_input(&block["input"]),
                        }),
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default(),
        Some("result") => vec![Event::Finished {
            summary: event["result"].as_str().map(String::from),
            is_error: event["is_error"]
                .as_bool()
                .unwrap_or(event["subtype"] != "success"),
            cost_usd: event["total_cost_usd"].as_f64(),
        }],
        _ => vec![],
    }
}

fn describe_input(input: &Value) -> String {
    [
        "command",
        "file_path",
        "path",
        "pattern",
        "url",
        "query",
        "description",
    ]
    .iter()
    .find_map(|key| input[*key].as_str())
    .unwrap_or("")
    .to_string()
}

/// `codex exec --json`
pub fn codex(line: &str) -> Vec<Event> {
    let Ok(event) = serde_json::from_str::<Value>(line) else {
        return vec![];
    };
    let item = &event["item"];
    match (event["type"].as_str(), item["type"].as_str()) {
        (Some("thread.started"), _) => vec![Event::Started {
            session_id: str_of(&event["thread_id"]),
            model: None,
        }],
        (Some("item.started"), Some("command_execution")) => {
            vec![Event::Tool {
                name: "Shell".into(),
                detail: unwrap_shell(item["command"].as_str().unwrap_or("")),
            }]
        }
        (Some("item.completed"), Some("agent_message")) => {
            let text = str_of(&item["text"]).trim().to_string();
            if text.is_empty() {
                vec![]
            } else {
                vec![Event::Message { text }]
            }
        }
        (Some("item.completed"), Some("file_change")) => {
            let paths: Vec<String> = item["changes"]
                .as_array()
                .map(|c| {
                    c.iter()
                        .filter_map(|c| c["path"].as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            vec![Event::Tool {
                name: "Edit".into(),
                detail: paths.join(", "),
            }]
        }
        (Some("item.started"), Some("web_search")) => {
            vec![Event::Tool {
                name: "WebSearch".into(),
                detail: str_of(&item["query"]),
            }]
        }
        (Some("turn.completed"), _) => vec![Event::Finished {
            summary: None,
            is_error: false,
            cost_usd: None,
        }],
        (Some("turn.failed") | Some("error"), _) => {
            let message = event["error"]["message"]
                .as_str()
                .or(event["message"].as_str())
                .unwrap_or("Codex failed");
            vec![Event::Finished {
                summary: Some(message.to_string()),
                is_error: true,
                cost_usd: None,
            }]
        }
        _ => vec![],
    }
}

/// `/bin/zsh -lc 'cat note.txt'` → `cat note.txt`
fn unwrap_shell(command: &str) -> String {
    match command.split_once(" -lc ") {
        Some((_, inner)) => inner.trim_matches(|c| c == '\'' || c == '"').to_string(),
        None => command.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Lines recorded from real `claude -p --output-format stream-json --verbose` and `codex exec --json` runs.

    #[test]
    fn parses_claude_stream() {
        let lines = [
            r#"{"type":"system","subtype":"hook_started","session_id":"s1"}"#,
            r#"{"type":"system","subtype":"init","session_id":"0d5cc793","model":"claude-haiku-4-5-20251001"}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/note.txt"}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"hallo"}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hallo"}]}}"#,
            r#"{"type":"result","subtype":"success","is_error":false,"result":"Hallo","total_cost_usd":0.01544,"session_id":"0d5cc793"}"#,
            "not json",
        ];
        let events: Vec<Event> = lines.iter().flat_map(|l| claude(l)).collect();
        assert_eq!(
            events,
            vec![
                Event::Started {
                    session_id: "0d5cc793".into(),
                    model: Some("claude-haiku-4-5-20251001".into())
                },
                Event::Tool {
                    name: "Read".into(),
                    detail: "/tmp/note.txt".into()
                },
                Event::Message {
                    text: "Hallo".into()
                },
                Event::Finished {
                    summary: Some("Hallo".into()),
                    is_error: false,
                    cost_usd: Some(0.01544)
                },
            ]
        );
    }

    #[test]
    fn parses_codex_stream() {
        let lines = [
            r#"{"type":"thread.started","thread_id":"01a0ec95"}"#,
            r#"{"type":"turn.started"}"#,
            r#"{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"/bin/zsh -lc 'cat note.txt'","status":"in_progress"}}"#,
            r#"{"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"/bin/zsh -lc 'cat note.txt'","exit_code":0}}"#,
            r#"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"hallo"}}"#,
            r#"{"type":"turn.completed","usage":{"input_tokens":31586}}"#,
        ];
        let events: Vec<Event> = lines.iter().flat_map(|l| codex(l)).collect();
        assert_eq!(
            events,
            vec![
                Event::Started {
                    session_id: "01a0ec95".into(),
                    model: None
                },
                Event::Tool {
                    name: "Shell".into(),
                    detail: "cat note.txt".into()
                },
                Event::Message {
                    text: "hallo".into()
                },
                Event::Finished {
                    summary: None,
                    is_error: false,
                    cost_usd: None
                },
            ]
        );
    }

    #[test]
    fn events_serialize_to_the_shared_format() {
        let json = Event::Finished {
            summary: None,
            is_error: true,
            cost_usd: Some(0.5),
        }
        .to_json();
        assert_eq!(
            json.to_string(),
            r#"{"type":"finished","summary":null,"is_error":true,"cost_usd":0.5}"#
        );
    }
}
