//! What an agent should do, and the prompt that tells it.

use std::path::Path;

use anyhow::{Result, bail};

use crate::{Repo, is_image, listing, walk};

pub enum Task {
    /// Group one new batch of loose inbox photos by item.
    Cluster { photos: Vec<String> },
    /// Turn one inbox group (a subfolder or a single photo) into a listing draft.
    Draft { group: String, photos: Vec<String> },
    /// Process everything in `inbox/`.
    Inbox,
    /// Re-run the price research for an item.
    Price { id: String, title: String },
    /// Work the user's answers and resolved suggestions back into an item.
    Revise { id: String, title: String },
    /// Free-form instruction, e.g. "item 4 sold for 4 €".
    Ask { text: String },
}

/// Shared rules for non-interactive runs (see AGENTS.md).
const CONTEXT: &str = "You are running non-interactively (started via `./vinted agent`) in this repository; \
follow AGENTS.md. You cannot ask the user anything, and the user answers later, not during this run. If something \
isn't visible in the photos or you're unsure, don't guess: leave the field empty and add a to-do under Notizen \
(`./vinted todo ID --add \"…\"`):\n\
- `TODO: …` for something the user has to do or check physically.\n\
- `QUESTION(field): Frage? | Option | Option` for a fact only the user knows; `field` is the frontmatter key \
the answer fills (e.g. material, size, brand), omit `(field)` if none; the `| options` are optional.\n\
- `SUGGEST(key=value): Begründung` to propose changing a field instead of changing it yourself where the user \
should decide (e.g. `SUGGEST(price_listed=5): …` for an item already on Vinted). For a new description use \
`SUGGEST(description): Begründung` and put the proposed text on indented `  > ` lines right below the to-do.\n\
Resolved to-dos read `- [x] QUESTION(material): … → Antwort: …`; use those answers. Also list your open \
questions at the end of your reply. Change items only through `./vinted` (status, set, todo, new, apply-draft, \
group) or by editing listing.md; never touch files outside this repository. Finish with a short summary of what \
you changed.";

impl Task {
    pub fn cluster(repo: &Repo, photos: &[String]) -> Result<Task> {
        if photos.is_empty() {
            bail!("no photos to group");
        }
        let mut checked = Vec::with_capacity(photos.len());
        for photo in photos {
            let relative = photo.strip_prefix("inbox/").unwrap_or(photo);
            let path = Path::new(relative);
            if path.components().count() != 1
                || !matches!(
                    path.components().next(),
                    Some(std::path::Component::Normal(_))
                )
                || !repo.inbox().join(path).is_file()
                || !is_image(path)
            {
                bail!("not a loose inbox photo: {photo}");
            }
            checked.push(format!("inbox/{relative}"));
        }
        Ok(Task::Cluster { photos: checked })
    }

    /// `group` is a folder or photo inside `inbox/`.
    pub fn draft(repo: &Repo, group: &str) -> Result<Task> {
        let group = group.trim_start_matches("inbox/").trim_end_matches('/');
        if group.is_empty()
            || Path::new(group).is_absolute()
            || Path::new(group)
                .components()
                .any(|part| !matches!(part, std::path::Component::Normal(_)))
        {
            bail!("draft group must be a photo or folder directly inside inbox/");
        }
        let path = repo.inbox().join(group);
        let photos: Vec<String> = if path.is_dir() {
            walk(&path)
                .into_iter()
                .filter(|p| is_image(p))
                .map(|p| relative(repo, &p))
                .collect()
        } else if path.is_file() && is_image(&path) {
            vec![relative(repo, &path)]
        } else {
            bail!("inbox/{group} is not a photo or photo folder in the inbox");
        };
        if photos.is_empty() {
            bail!("inbox/{group} contains no photos");
        }
        Ok(Task::Draft {
            group: group.to_string(),
            photos,
        })
    }

    pub fn price(repo: &Repo, id: &str) -> Result<Task> {
        let listing_path = repo.find_item(id)?;
        let (meta, _) = listing::read(&listing_path)?;
        let id = meta.get("id").cloned().unwrap_or_else(|| id.to_string());
        Ok(Task::Price {
            title: meta.get("title").cloned().unwrap_or_default(),
            id,
        })
    }

    pub fn revise(repo: &Repo, id: &str) -> Result<Task> {
        let Task::Price { id, title } = Task::price(repo, id)? else { unreachable!() };
        Ok(Task::Revise { id, title })
    }

    pub fn title(&self) -> String {
        match self {
            Task::Cluster { photos } => format!("Group {} new photo(s) by item", photos.len()),
            Task::Draft { group, .. } => format!("Draft listing: {group}"),
            Task::Inbox => "Process inbox".into(),
            Task::Price { id, .. } => format!("Re-check price: {id}"),
            Task::Revise { id, .. } => format!("Update listing with answers: {id}"),
            Task::Ask { text } => text.clone(),
        }
    }

    pub fn prompt(&self) -> String {
        let body = match self {
            Task::Cluster { photos } => format!(
                "Inspect every photo below and sort this batch into one inbox/ folder per distinct item. \
                 Use `./vinted inbox` for preview paths when needed, and look at the images, including \
                 back views and label/detail shots. For each item, call `./vinted group NAME PHOTO [PHOTO ...]` \
                 with only the photos of that item. Use a short descriptive German NAME. \
                 Group even single-photo items. If uncertain whether two photos are the same item, \
                 put them in separate folders. Only move the listed photos; do not create listings, \
                 research prices, or alter existing items. Photos:\n{}",
                photos
                    .iter()
                    .map(|p| format!("- {p}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ),
            Task::Draft { photos, .. } => format!(
                "Turn these inbox photos into ONE Vinted listing draft, following \
                 .agents/skills/process-inbox/SKILL.md (all steps, including price research and \
                 `./vinted index`). Only use these photos:\n{}",
                photos
                    .iter()
                    .map(|p| format!("- {p}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ),
            Task::Inbox => {
                "Process all photos in inbox/, following .agents/skills/process-inbox/SKILL.md."
                    .into()
            }
            Task::Price { id, title } => format!(
                "Re-check the price of item {id} ({title}): search comparable listings with `./vinted comps` \
                 and rewrite the Preisrecherche section of its listing.md. Don't change any price yourself: \
                 if a different price is better, add `SUGGEST(price_suggested=…)` (planned items) or \
                 `SUGGEST(price_listed=…)` (listed/reserved) with a one-line reason via `./vinted todo {id} --add`, \
                 replacing any open price suggestion you made earlier (dismiss it with `./vinted dismiss`)."
            ),
            Task::Revise { id, title } => format!(
                "The user answered questions or resolved suggestions in the Notizen of item {id} ({title}) \
                 (`- [x] QUESTION… → Antwort: …`, `→ angenommen`, `→ abgelehnt`). Work the answers into the \
                 listing: fill fields that are still empty with `./vinted set`, and adjust title and Beschreibung \
                 where an answer changes them. If you'd change text the user already accepted or wrote, propose it \
                 as a SUGGEST to-do instead. Don't reopen resolved to-dos."
            ),
            Task::Ask { text } => text.clone(),
        };
        format!("{body}\n\n{CONTEXT}")
    }
}

fn relative(repo: &Repo, path: &Path) -> String {
    path.strip_prefix(&repo.root)
        .unwrap_or(path)
        .to_string_lossy()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_carry_the_rules() {
        let task = Task::Draft {
            group: "jacke".into(),
            photos: vec!["inbox/jacke/a.HEIC".into()],
        };
        assert!(task.prompt().contains("- inbox/jacke/a.HEIC"));
        assert!(task.prompt().contains("cannot ask the user"));
        let price = Task::Price {
            id: "0004".into(),
            title: "Cargohose".into(),
        };
        assert!(price.prompt().contains("SUGGEST(price_suggested=…)"));
        assert!(price.prompt().contains("QUESTION(field)"));
    }

    #[test]
    fn cluster_prompt_scopes_the_batch() {
        let temp = tempfile::tempdir().unwrap();
        let repo = Repo {
            root: temp.path().to_path_buf(),
        };
        std::fs::create_dir(repo.inbox()).unwrap();
        std::fs::write(repo.inbox().join("front.jpg"), b"photo").unwrap();
        let task = Task::cluster(&repo, &["inbox/front.jpg".into()]).unwrap();
        assert!(task.prompt().contains("./vinted group"));
        assert!(task.prompt().contains("- inbox/front.jpg"));
        assert!(Task::cluster(&repo, &["../front.jpg".into()]).is_err());
    }
}
