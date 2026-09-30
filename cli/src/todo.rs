//! Typed to-dos in Notizen, so agents can leave questions and suggestions for later:
//!
//! - `- [ ] TODO: Mantel abbürsten` — something for the user to do or check.
//! - `- [ ] QUESTION(material): Welches Material steht auf dem Etikett? | Wolle | Polyester`
//!   — a fact only the user knows; the answer fills the field in parentheses (optional),
//!   `|` separates optional answer choices.
//! - `- [ ] SUGGEST(price_suggested=12): 5 Vergleichsangebote bei 11–15 €` — a proposed change.
//!   `SUGGEST(description): …` carries the proposed text as indented `  > ` lines below.
//!
//! Resolving checks the line and records the outcome after ` → `, so a later agent run sees it.

use anyhow::{Result, bail};

use crate::listing;

#[derive(Debug, PartialEq)]
pub enum Kind {
    Task,
    Question { field: Option<String>, options: Vec<String> },
    Suggest { key: String, value: Option<String> },
}

#[derive(Debug, PartialEq)]
pub struct Todo {
    pub kind: Kind,
    /// Question or reason, without the prefix, choices and outcome.
    pub text: String,
}

pub fn parse(line: &str) -> Todo {
    let line = line.split(" → ").next().unwrap_or(line).trim();
    let (prefix, rest) = match line.split_once(':') {
        Some((prefix, rest)) if !prefix.contains(' ') || prefix.contains('(') => (prefix.trim(), rest.trim()),
        _ => return Todo { kind: Kind::Task, text: line.to_string() },
    };
    let (name, argument) = match prefix.split_once('(') {
        Some((name, arg)) if arg.ends_with(')') => (name, Some(arg[..arg.len() - 1].trim())),
        _ => (prefix, None),
    };
    match (name, argument) {
        ("QUESTION", _) => {
            let mut parts = rest.split('|').map(str::trim);
            let text = parts.next().unwrap_or("").to_string();
            let options = parts.filter(|p| !p.is_empty()).map(String::from).collect();
            let field = argument.filter(|f| !f.is_empty()).map(String::from);
            Todo { kind: Kind::Question { field, options }, text }
        }
        ("SUGGEST", Some(argument)) => {
            let (key, value) = match argument.split_once('=') {
                Some((key, value)) => (key.trim(), Some(value.trim().to_string())),
                None => (argument, None),
            };
            Todo { kind: Kind::Suggest { key: key.to_string(), value }, text: rest.to_string() }
        }
        ("TODO", _) => Todo { kind: Kind::Task, text: rest.to_string() },
        _ => Todo { kind: Kind::Task, text: line.to_string() },
    }
}

pub enum Resolution {
    Answer(String),
    Accept(Option<String>),
    Dismiss,
}

/// Applies the resolution to the listing text: fills the field (if any) and checks the to-do.
/// Returns the new text and whether frontmatter changed (so INVENTORY.md needs a rebuild).
pub fn resolve(text: &str, n: usize, resolution: Resolution) -> Result<(String, bool)> {
    let lines = listing::todo_lines(text);
    let Some(line) = n.checked_sub(1).and_then(|i| lines.get(i)) else {
        bail!("to-do {n} not found ({} in Notizen)", lines.len());
    };
    if line.done {
        bail!("to-do {n} is already done");
    }
    let todo = parse(&line.text);
    let mut head = line.text.split(" → ").next().unwrap_or(&line.text);
    if let Kind::Question { .. } = todo.kind {
        head = head.split(" | ").next().unwrap_or(head);
    }
    let head = head.trim().to_string();
    let (field, value, outcome) = match (&todo.kind, resolution) {
        (Kind::Question { field, .. }, Resolution::Answer(answer)) => {
            let answer = answer.trim().to_string();
            if answer.is_empty() {
                bail!("empty answer");
            }
            (field.clone(), answer.clone(), format!("Antwort: {answer}"))
        }
        (Kind::Question { .. }, Resolution::Dismiss) => (None, String::new(), "unklar".to_string()),
        (Kind::Suggest { key, value }, Resolution::Accept(custom)) => {
            let proposed = value.clone().unwrap_or_else(|| line.quote.join("\n"));
            let chosen = custom.map(|c| c.trim().to_string()).filter(|c| !c.is_empty()).unwrap_or(proposed.clone());
            if chosen.is_empty() {
                bail!("the suggestion has no value; pass --value");
            }
            let outcome = if chosen == proposed { "angenommen".to_string() } else { format!("angenommen: {chosen}") };
            (Some(key.clone()), chosen, outcome)
        }
        (Kind::Suggest { .. }, Resolution::Dismiss) => (None, String::new(), "abgelehnt".to_string()),
        (Kind::Task, _) => bail!("to-do {n} is a plain to-do; check it with `vinted todo`"),
        (Kind::Question { .. }, _) => bail!("to-do {n} is a question; answer it with `vinted answer`"),
        (Kind::Suggest { .. }, _) => bail!("to-do {n} is a suggestion; use `vinted accept` or `vinted dismiss`"),
    };

    let mut text = listing::rewrite_todo(text, n, true, |_| format!("- [x] {head} → {outcome}"))?;
    let mut frontmatter = false;
    match field.as_deref() {
        None => {}
        Some("description") => text = listing::set_section(&text, "Beschreibung", &value),
        Some(key) => {
            let old_title = listing::parse(&text).0.get("title").cloned().unwrap_or_default();
            text = listing::set_fields(&text, &[(key, value.replace('\n', " "))]);
            if key == "title" {
                text = text.replacen(&format!("\n# {old_title}\n"), &format!("\n# {value}\n"), 1);
            }
            frontmatter = true;
        }
    }
    Ok((text, frontmatter))
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOC: &str = "---\nid: 0016\ntitle: Mantel\nmaterial:            # z. B. Baumwolle\nprice_suggested: 15\n---\n\n# Mantel\n\n## Beschreibung\n\nAlt.\n\n## Notizen\n\n- [ ] TODO: abbürsten\n- [ ] QUESTION(material): Welches Material? | Wolle | Polyester\n- [ ] SUGGEST(price_suggested=12): 5 Angebote bei 11–15 €\n- [ ] SUGGEST(description): kürzer\n  > Neu.\n  >\n  > #mantel\n- [ ] QUESTION: Gürtel abnehmbar?\n";

    #[test]
    fn parses_kinds() {
        assert_eq!(parse("TODO: abbürsten"), Todo { kind: Kind::Task, text: "abbürsten".into() });
        assert_eq!(parse("Foto ergänzen: Etikett"), Todo { kind: Kind::Task, text: "Foto ergänzen: Etikett".into() });
        assert_eq!(
            parse("QUESTION(material): Welches Material? | Wolle | Polyester"),
            Todo { kind: Kind::Question { field: Some("material".into()), options: vec!["Wolle".into(), "Polyester".into()] }, text: "Welches Material?".into() }
        );
        assert_eq!(
            parse("SUGGEST(price_suggested=12): billiger → abgelehnt"),
            Todo { kind: Kind::Suggest { key: "price_suggested".into(), value: Some("12".into()) }, text: "billiger".into() }
        );
    }

    #[test]
    fn answers_fill_the_field() {
        let (out, frontmatter) = resolve(DOC, 2, Resolution::Answer("70 % Wolle".into())).unwrap();
        assert!(frontmatter);
        assert!(out.contains("material: 70 % Wolle            # z. B. Baumwolle\n"));
        assert!(out.contains("- [x] QUESTION(material): Welches Material? → Antwort: 70 % Wolle\n"));
        let (out, frontmatter) = resolve(DOC, 5, Resolution::Answer("ja".into())).unwrap();
        assert!(!frontmatter);
        assert!(out.ends_with("- [x] QUESTION: Gürtel abnehmbar? → Antwort: ja\n"));
    }

    #[test]
    fn accepts_and_dismisses_suggestions() {
        let (out, _) = resolve(DOC, 3, Resolution::Accept(None)).unwrap();
        assert!(out.contains("price_suggested: 12\n"));
        assert!(out.contains("- [x] SUGGEST(price_suggested=12): 5 Angebote bei 11–15 € → angenommen\n"));
        let (out, _) = resolve(DOC, 3, Resolution::Accept(Some("13".into()))).unwrap();
        assert!(out.contains("price_suggested: 13\n") && out.contains("→ angenommen: 13\n"));
        let (out, _) = resolve(DOC, 4, Resolution::Accept(None)).unwrap();
        assert!(out.contains("## Beschreibung\n\nNeu.\n\n#mantel\n\n## Notizen"));
        assert!(out.contains("- [x] SUGGEST(description): kürzer → angenommen\n- [ ] QUESTION: Gürtel"));
        let (out, frontmatter) = resolve(DOC, 4, Resolution::Dismiss).unwrap();
        assert!(!frontmatter);
        assert!(out.contains("## Beschreibung\n\nAlt.\n") && out.contains("kürzer → abgelehnt\n- [ ] QUESTION"));
    }

    #[test]
    fn refuses_the_wrong_kind() {
        assert!(resolve(DOC, 1, Resolution::Dismiss).is_err());
        assert!(resolve(DOC, 2, Resolution::Accept(None)).is_err());
        assert!(resolve(DOC, 3, Resolution::Answer("x".into())).is_err());
        assert!(resolve(DOC, 9, Resolution::Dismiss).is_err());
    }
}
