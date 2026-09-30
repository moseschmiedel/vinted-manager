//! `listing.md` frontmatter: flat `key: value` lines with optional `# comments`.

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use anyhow::Result;
use regex::Regex;

static DOCUMENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)^---\n(.*?)\n---\n?(.*)$").unwrap());

/// Parsed frontmatter fields and the Markdown body.
pub fn parse(text: &str) -> (HashMap<String, String>, String) {
    let Some(caps) = DOCUMENT.captures(text) else {
        return (HashMap::new(), text.to_string());
    };
    let mut meta = HashMap::new();
    for line in caps[1].lines() {
        let line = line.split(" #").next().unwrap_or("").trim_end();
        if line.is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else { continue };
        meta.insert(key.trim().to_string(), value.trim().trim_matches('"').to_string());
    }
    (meta, caps[2].to_string())
}

pub fn read(path: &Path) -> Result<(HashMap<String, String>, String)> {
    Ok(parse(&fs::read_to_string(path)?))
}

/// Update frontmatter fields in place, keeping order and comments. Missing keys are appended.
pub fn set_fields(text: &str, updates: &[(&str, String)]) -> String {
    let after_open = text.get(4..).unwrap_or("");
    let (head, rest) = match after_open.find("\n---") {
        Some(i) => (&after_open[..i], &after_open[i..]),
        None => (after_open, ""),
    };
    let mut lines: Vec<String> = head.split('\n').map(String::from).collect();
    for (key, value) in updates {
        let pattern = Regex::new(&format!(r"^{}:[^#\n]*?(\s+#.*)?$", regex::escape(key))).unwrap();
        match lines.iter().position(|line| pattern.is_match(line)) {
            Some(i) => {
                let comment = pattern
                    .captures(&lines[i])
                    .and_then(|c| c.get(1))
                    .map_or(String::new(), |m| m.as_str().to_string());
                lines[i] = format!("{key}: {value}{comment}");
            }
            None => lines.push(format!("{key}: {value}")),
        }
    }
    format!("---\n{}{}", lines.join("\n"), rest)
}

/// Replace the text under `## heading` (up to the next `## ` heading) with `content`.
/// Appends the section if it doesn't exist.
pub fn set_section(text: &str, heading: &str, content: &str) -> String {
    let marker = format!("## {heading}\n");
    let content = content.trim();
    let start = if text.starts_with(&marker) {
        Some(0)
    } else {
        text.find(&format!("\n{marker}")).map(|i| i + 1)
    };
    let Some(start) = start else {
        return format!("{}\n\n## {heading}\n\n{content}\n", text.trim_end());
    };
    let body_start = start + marker.len();
    match text[body_start..].find("\n## ") {
        Some(i) => format!("{}\n{content}\n\n{}", &text[..body_start], &text[body_start + i + 1..]),
        None => format!("{}\n{content}\n", &text[..body_start]),
    }
}

/// Checkbox lines (`- [ ]` / `- [x]`) under `## Notizen`, as (done, text).
pub fn todos(text: &str) -> Vec<(bool, String)> {
    notes_lines(text).filter_map(|line| checkbox(line)).collect()
}

/// A checkbox line plus the indented `> ` lines right below it (e.g. a proposed description).
#[derive(Debug, PartialEq)]
pub struct TodoLine {
    pub done: bool,
    pub text: String,
    pub quote: Vec<String>,
}

pub fn todo_lines(text: &str) -> Vec<TodoLine> {
    let mut result: Vec<TodoLine> = Vec::new();
    let mut in_todo = false;
    for line in notes_lines(text) {
        if let Some((done, text)) = checkbox(line) {
            result.push(TodoLine { done, text, quote: Vec::new() });
            in_todo = true;
        } else if let (true, Some(quote)) = (in_todo, quote_line(line)) {
            result.last_mut().unwrap().quote.push(quote);
        } else {
            in_todo = false;
        }
    }
    result
}

/// Check or uncheck the `n`-th (1-based) checkbox line under `## Notizen`.
pub fn set_todo(text: &str, n: usize, done: bool) -> Result<String> {
    rewrite_todo(text, n, false, |line| format!("{}{}", if done { "- [x]" } else { "- [ ]" }, &line[5..]))
}

/// Replace the `n`-th checkbox line (given without indentation) and optionally drop its `> ` lines.
pub fn rewrite_todo(text: &str, n: usize, drop_quote: bool, replace: impl FnOnce(&str) -> String) -> Result<String> {
    let range = notes_range(text).ok_or_else(|| anyhow::anyhow!("no Notizen section"))?;
    let mut count = 0;
    let mut replace = Some(replace);
    let mut skipping = false;
    let mut out = String::with_capacity(text.len());
    out.push_str(&text[..range.start]);
    for line in text[range.clone()].split_inclusive('\n') {
        if skipping && quote_line(line).is_some() {
            continue;
        }
        skipping = false;
        if checkbox(line).is_some() {
            count += 1;
            if count == n {
                let indent = line.len() - line.trim_start().len();
                out.push_str(&line[..indent]);
                out.push_str(&(replace.take().unwrap())(line.trim()));
                if line.ends_with('\n') {
                    out.push('\n');
                }
                skipping = drop_quote;
                continue;
            }
        }
        out.push_str(line);
    }
    if count < n || n == 0 {
        anyhow::bail!("to-do {n} not found ({count} in Notizen)");
    }
    out.push_str(&text[range.end..]);
    Ok(out)
}

/// Append `- [ ] todo` to Notizen (creating the section if needed).
pub fn add_todo(text: &str, todo: &str) -> String {
    let line = format!("- [ ] {}", todo.trim());
    match notes_range(text) {
        Some(range) => {
            let body = text[range.clone()].trim_end();
            let body = if body.trim().is_empty() { line } else { format!("{body}\n{line}") };
            set_section(text, "Notizen", &body)
        }
        None => set_section(text, "Notizen", &line),
    }
}

fn checkbox(line: &str) -> Option<(bool, String)> {
    let line = line.trim();
    let done = match line.get(..5)? {
        "- [ ]" => false,
        "- [x]" | "- [X]" => true,
        _ => return None,
    };
    Some((done, line[5..].trim().to_string()))
}

/// `  > text` below a to-do; returns the text.
fn quote_line(line: &str) -> Option<String> {
    let trimmed = line.trim();
    (line.starts_with(' ') || line.starts_with('\t'))
        .then(|| trimmed.strip_prefix('>'))
        .flatten()
        .map(|rest| rest.strip_prefix(' ').unwrap_or(rest).trim_end().to_string())
}

/// Byte range of the body under `## Notizen`, up to the next `## ` heading.
fn notes_range(text: &str) -> Option<std::ops::Range<usize>> {
    let marker = "## Notizen\n";
    let start = if text.starts_with(marker) { 0 } else { text.find(&format!("\n{marker}"))? + 1 } + marker.len();
    let end = text[start..].find("\n## ").map_or(text.len(), |i| start + i + 1);
    Some(start..end)
}

fn notes_lines(text: &str) -> impl Iterator<Item = &str> {
    notes_range(text).map_or("", |r| &text[r]).lines()
}

pub fn update_file(path: &Path, updates: &[(&str, String)]) -> Result<()> {
    let text = fs::read_to_string(path)?;
    fs::write(path, set_fields(&text, updates))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "---\nid: 0001\nstatus: planned          # planned | listed\ntitle: C&A Hemd  # max ~60 chars\nprice_listed:\n---\n\n# C&A Hemd\n";

    #[test]
    fn parses_fields_and_strips_comments() {
        let (meta, body) = parse(SAMPLE);
        assert_eq!(meta["status"], "planned");
        assert_eq!(meta["title"], "C&A Hemd");
        assert_eq!(meta["price_listed"], "");
        assert_eq!(body, "\n# C&A Hemd\n");
    }

    #[test]
    fn set_fields_keeps_comments_and_appends_missing_keys() {
        let out = set_fields(SAMPLE, &[("status", "listed".into()), ("price_listed", "4".into()), ("sold_at", "x".into())]);
        assert!(out.contains("status: listed          # planned | listed\n"));
        assert!(out.contains("price_listed: 4\n"));
        assert!(out.contains("sold_at: x\n---\n\n# C&A Hemd\n"));
    }

    #[test]
    fn set_section_replaces_or_appends() {
        let doc = "---\nid: 1\n---\n\n# T\n\n## Beschreibung\n\n<!-- hint -->\n\n## Notizen\n\n- alt\n";
        let out = set_section(doc, "Beschreibung", "Neu.\n\n#tag\n");
        assert_eq!(out, "---\nid: 1\n---\n\n# T\n\n## Beschreibung\n\nNeu.\n\n#tag\n\n## Notizen\n\n- alt\n");
        let out = set_section(&out, "Notizen", "- [ ] Frage?");
        assert!(out.ends_with("## Notizen\n\n- [ ] Frage?\n"));
        let out = set_section(&out, "Extra", "x");
        assert!(out.ends_with("- [ ] Frage?\n\n## Extra\n\nx\n"));
    }

    #[test]
    fn toggles_todos_in_notes_only() {
        let doc = "---\nid: 1\n---\n\n## Beschreibung\n\n- [ ] kein Todo\n\n## Notizen\n\n- [x] Material: Baumwolle\n- [ ] TODO: Größe prüfen\n- Hinweis\n";
        assert_eq!(todos(doc), vec![(true, "Material: Baumwolle".into()), (false, "TODO: Größe prüfen".into())]);
        let out = set_todo(doc, 2, true).unwrap();
        assert!(out.ends_with("- [x] Material: Baumwolle\n- [x] TODO: Größe prüfen\n- Hinweis\n"));
        assert!(out.contains("- [ ] kein Todo"));
        let out = set_todo(&out, 1, false).unwrap();
        assert!(out.contains("- [ ] Material: Baumwolle\n"));
        assert!(set_todo(doc, 3, true).is_err());
    }

    #[test]
    fn keeps_quotes_with_their_todo() {
        let doc = "---\nid: 1\n---\n\n## Notizen\n\n- [ ] SUGGEST(description): kürzer\n  > Zeile 1\n  >\n  > Zeile 2\n- [ ] TODO: x\n";
        let lines = todo_lines(doc);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].quote, vec!["Zeile 1", "", "Zeile 2"]);
        assert!(lines[1].quote.is_empty());
        let out = rewrite_todo(doc, 1, true, |_| "- [x] SUGGEST(description): kürzer → angenommen".into()).unwrap();
        assert!(out.ends_with("## Notizen\n\n- [x] SUGGEST(description): kürzer → angenommen\n- [ ] TODO: x\n"));
    }

    #[test]
    fn adds_todos_to_notes() {
        let doc = "---\nid: 1\n---\n\n## Notizen\n\n- [ ] a\n\n## Extra\n\nx\n";
        assert!(add_todo(doc, "b").contains("## Notizen\n\n- [ ] a\n- [ ] b\n\n## Extra"));
        assert!(add_todo("---\nid: 1\n---\n\n# T\n", "b").ends_with("## Notizen\n\n- [ ] b\n"));
    }

    #[test]
    fn text_without_frontmatter_is_body() {
        let (meta, body) = parse("# nur Text");
        assert!(meta.is_empty());
        assert_eq!(body, "# nur Text");
    }
}
