//! Vinted selling helper.
//!
//! Commands:
//!   inbox                        List photos waiting in inbox/ and make JPEG previews
//!   group NAME PHOTO [...]       Move loose inbox photos into one item folder
//!   comps QUERY [--brand B] [--size S] [--limit N]
//!                                Search live Vinted listings for comparable items
//!   new SLUG PHOTO [PHOTO ...]   Create items/NNNN-SLUG/ from inbox photos
//!   status ID STATUS [--price P] [--url U]
//!                                Set status (planned|listed|reserved|sold|withdrawn)
//!   set ID[,ID...] KEY=VALUE [...]
//!                                Set frontmatter fields of one or more items
//!   todo ID [N] [--open] [--add TEXT]
//!                                List to-dos in Notizen, check (uncheck) to-do N, or add one
//!   answer ID N ANSWER           Answer a QUESTION to-do (fills its field)
//!   accept ID N [--value V]      Apply a SUGGEST to-do
//!   dismiss ID N                 Close a QUESTION or SUGGEST to-do without applying it
//!   apply-draft ID FILE          Fill an item from a JSON listing draft (FILE or - for stdin)
//!   index                        Regenerate INVENTORY.md
//!   agent status|config|run      AI agents (Claude Code, Codex) with your own login

mod agent;
mod comps;
mod inventory;
mod listing;
mod todo;
mod library;

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand, ValueEnum};

const IMAGE_EXTS: [&str; 5] = ["heic", "jpg", "jpeg", "png", "webp"];

#[derive(Parser)]
#[command(name = "vinted", about = "Vinted selling helper", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create an empty, portable selling library (the folder must be empty)
    Init { directory: PathBuf },
    /// List photos waiting in inbox/ and make JPEG previews
    Inbox,
    /// Move loose inbox photos into one item folder
    Group {
        name: String,
        #[arg(required = true)]
        photos: Vec<PathBuf>,
    },
    /// Search live Vinted listings for comparable items
    Comps {
        query: String,
        #[arg(long)]
        brand: Option<String>,
        #[arg(long)]
        size: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        /// e.g. newest_first, price_low_to_high
        #[arg(long)]
        order: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Create items/NNNN-SLUG/ from inbox photos
    New {
        slug: String,
        #[arg(required = true)]
        photos: Vec<PathBuf>,
    },
    /// Set an item's status (stamps dates and regenerates INVENTORY.md)
    Status {
        id: String,
        status: Status,
        #[arg(long)]
        price: Option<String>,
        #[arg(long)]
        url: Option<String>,
    },
    /// Set frontmatter fields of items (ID or ID,ID,…; key=value; empty value clears)
    Set {
        #[arg(value_name = "ID[,ID...]")]
        id: String,
        #[arg(required = true, value_name = "KEY=VALUE")]
        fields: Vec<String>,
    },
    /// List the to-dos in Notizen, check to-do N (1-based; --open unchecks it), or --add one
    Todo {
        id: String,
        n: Option<usize>,
        #[arg(long)]
        open: bool,
        /// Append a to-do, e.g. "QUESTION(size): Welche Größe steht auf dem Etikett?"
        #[arg(long, conflicts_with_all = ["n", "open"])]
        add: Option<String>,
    },
    /// Answer QUESTION to-do N; fills the field named in QUESTION(field)
    Answer {
        id: String,
        n: usize,
        #[arg(required = true, num_args = 1..)]
        answer: Vec<String>,
    },
    /// Apply SUGGEST to-do N (--value replaces the suggested value)
    Accept {
        id: String,
        n: usize,
        #[arg(long)]
        value: Option<String>,
    },
    /// Close QUESTION or SUGGEST to-do N without applying anything
    Dismiss { id: String, n: usize },
    /// Fill an item from a JSON listing draft (path, or - for stdin)
    ApplyDraft { id: String, file: PathBuf },
    /// Regenerate INVENTORY.md
    Index,
    /// AI agents (Claude Code, Codex) running in this repository with your own login
    Agent {
        #[command(subcommand)]
        command: agent::AgentCmd,
    },
}

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Status {
    Planned,
    Listed,
    Reserved,
    Sold,
    Withdrawn,
}

impl Status {
    pub const ALL: [Status; 5] = [Status::Planned, Status::Listed, Status::Reserved, Status::Sold, Status::Withdrawn];

    pub fn as_str(self) -> &'static str {
        match self {
            Status::Planned => "planned",
            Status::Listed => "listed",
            Status::Reserved => "reserved",
            Status::Sold => "sold",
            Status::Withdrawn => "withdrawn",
        }
    }
}

/// Repository layout, rooted at `$VINTED_REPO` or the nearest parent with `items/` and `templates/`.
pub struct Repo {
    pub root: PathBuf,
}

impl Repo {
    fn locate() -> Result<Repo> {
        if let Ok(root) = env::var("VINTED_REPO") {
            // Canonical, so it compares equal to canonical cwd-based paths (/var vs /private/var).
            let root = PathBuf::from(root);
            return Ok(Repo { root: fs::canonicalize(&root).unwrap_or(root) });
        }
        let mut dir = env::current_dir()?;
        loop {
            if dir.join("items").is_dir() && dir.join("templates").is_dir() {
                return Ok(Repo { root: dir });
            }
            if !dir.pop() {
                bail!("Not inside the Vinted repository (no items/ and templates/ found). Set VINTED_REPO.");
            }
        }
    }

    pub fn inbox(&self) -> PathBuf { self.root.join("inbox") }
    pub fn items(&self) -> PathBuf { self.root.join("items") }
    fn cache(&self) -> PathBuf { self.root.join(".cache") }
    fn template(&self) -> PathBuf { self.root.join("templates/listing.md") }
    pub fn inventory(&self) -> PathBuf { self.root.join("INVENTORY.md") }

    pub fn find_item(&self, id: &str) -> Result<PathBuf> {
        let wanted = format!("{:04}", id.trim().parse::<u32>().with_context(|| format!("invalid id {id}"))?);
        for folder in sorted_dir(&self.items()) {
            let name = file_name(&folder);
            if name.starts_with(&format!("{wanted}-")) && folder.join("listing.md").is_file() {
                return Ok(folder.join("listing.md"));
            }
        }
        bail!("No item with id {wanted}")
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("{err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    if let Cmd::Init { directory } = &cli.command {
        return library::initialize(directory);
    }
    let repo = Repo::locate()?;
    match cli.command {
        Cmd::Init { .. } => unreachable!(),
        Cmd::Inbox => cmd_inbox(&repo),
        Cmd::Group { name, photos } => cmd_group(&repo, &name, &photos),
        Cmd::Comps { query, brand, size, limit, order, json } => {
            cmd_comps(&query, brand.as_deref(), size.as_deref(), limit, order.as_deref(), json)
        }
        Cmd::New { slug, photos } => cmd_new(&repo, &slug, &photos),
        Cmd::Status { id, status, price, url } => cmd_status(&repo, &id, status, price, url),
        Cmd::Set { id, fields } => cmd_set(&repo, &id, &fields),
        Cmd::Todo { id, n, open, add } => cmd_todo(&repo, &id, n, open, add),
        Cmd::Answer { id, n, answer } => cmd_resolve(&repo, &id, n, todo::Resolution::Answer(answer.join(" "))),
        Cmd::Accept { id, n, value } => cmd_resolve(&repo, &id, n, todo::Resolution::Accept(value)),
        Cmd::Dismiss { id, n } => cmd_resolve(&repo, &id, n, todo::Resolution::Dismiss),
        Cmd::ApplyDraft { id, file } => cmd_apply_draft(&repo, &id, &file),
        Cmd::Index => inventory::write(&repo),
        Cmd::Agent { command } => {
            let code = agent::command(&repo, command)?;
            if code != 0 {
                std::process::exit(code);
            }
            Ok(())
        }
    }
}

// ---------------------------------------------------------------- images

pub fn is_image(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| IMAGE_EXTS.contains(&e.to_lowercase().as_str()))
}

fn has_program(name: &str) -> bool {
    env::var_os("PATH").is_some_and(|paths| env::split_paths(&paths).any(|dir| dir.join(name).is_file()))
}

/// Convert any image to an upright JPEG without metadata (GPS etc.).
///
/// Packaged apps use the native ImageIO helper; source checkouts use ImageMagick.
fn to_jpeg(src: &Path, dest: &Path, max_px: Option<u32>) -> Result<()> {
    let mut cmd;
    if let Some(helper) = env::var_os("VINTED_IMAGE_CONVERTER") {
        cmd = Command::new(helper);
        cmd.arg(src).arg(dest);
        if let Some(px) = max_px { cmd.arg(px.to_string()); }
    } else if has_program("magick") {
        cmd = Command::new("magick");
        cmd.arg(src).args(["-auto-orient", "-strip", "-quality", "90"]);
        if let Some(px) = max_px {
            cmd.args(["-resize", &format!("{px}x{px}>")]);
        }
        cmd.arg(dest);
    } else {
        bail!("Photo conversion requires Vinted Manager's bundled converter or ImageMagick (brew install imagemagick).");
    }
    let out = cmd.output().with_context(|| format!("converting {}", src.display()))?;
    if !out.status.success() {
        bail!("converting {} failed: {}", src.display(), String::from_utf8_lossy(&out.stderr));
    }
    Ok(())
}

// ---------------------------------------------------------------- commands

fn cmd_inbox(repo: &Repo) -> Result<()> {
    let photos: Vec<PathBuf> = walk(&repo.inbox()).into_iter().filter(|p| is_image(p)).collect();
    if photos.is_empty() {
        println!("Inbox is empty.");
        return Ok(());
    }
    let previews = repo.cache().join("previews");
    fs::create_dir_all(&previews)?;
    for photo in photos {
        let rel = photo.strip_prefix(repo.inbox())?;
        let stem = rel.with_extension("").to_string_lossy().replace('/', "__");
        let preview = previews.join(format!("{stem}.jpg"));
        if !preview.exists() {
            to_jpeg(&photo, &preview, Some(1200))?;
        }
        let group = if rel.components().count() > 1 {
            rel.components().next().unwrap().as_os_str().to_string_lossy().to_string()
        } else {
            "-".to_string()
        };
        println!("{}\tgroup={group}\tpreview={}", rel.display(), preview.strip_prefix(&repo.root)?.display());
    }
    Ok(())
}

fn cmd_group(repo: &Repo, name: &str, photos: &[PathBuf]) -> Result<()> {
    let inbox = repo.inbox();
    let mut sources = Vec::with_capacity(photos.len());
    for photo in photos {
        let relative = photo.strip_prefix("inbox").unwrap_or(photo);
        if relative.components().count() != 1
            || !matches!(relative.components().next(), Some(std::path::Component::Normal(_)))
        {
            bail!("group accepts only loose photos directly inside inbox/: {}", photo.display());
        }
        let source = inbox.join(relative);
        let metadata = fs::symlink_metadata(&source)
            .with_context(|| format!("reading {}", source.display()))?;
        if !metadata.file_type().is_file() || !is_image(&source) {
            bail!("not an inbox photo: {}", source.display());
        }
        if sources.contains(&source) {
            bail!("photo repeated: {}", source.display());
        }
        sources.push(source);
    }
    let base = slugify(name);
    if base.is_empty() {
        bail!("group name must contain letters or numbers");
    }
    let mut destination = inbox.join(&base);
    let mut number = 2;
    while destination.exists() {
        destination = inbox.join(format!("{base}-{number}"));
        number += 1;
    }
    fs::create_dir(&destination)?;
    for source in &sources {
        fs::rename(source, destination.join(source.file_name().unwrap()))?;
    }
    println!("Grouped {} photo(s) in {}", sources.len(), destination.display());
    Ok(())
}

fn cmd_comps(query: &str, brand: Option<&str>, size: Option<&str>, limit: usize, order: Option<&str>, json: bool) -> Result<()> {
    let mut results = comps::fetch(query, order)?;
    if let Some(brand) = brand {
        results.retain(|r| r.brand.to_lowercase().contains(&brand.to_lowercase()));
    }
    if let Some(size) = size {
        results.retain(|r| r.size.to_lowercase() == size.to_lowercase());
    }
    if json {
        let list: Vec<serde_json::Value> = results
            .iter()
            .take(limit)
            .map(|r| {
                serde_json::json!({"title": r.title, "brand": r.brand, "size": r.size, "condition": r.condition,
                                   "price": r.price, "favs": r.favs, "url": r.url})
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&list)?);
        return Ok(());
    }
    println!("Query: \"{query}\" on {} — {} matching listings\n", comps::DOMAIN, results.len());
    for r in results.iter().take(limit) {
        println!(
            "{:7.2} €  {:18}  {:10}  {:18}  ♥{:<4} {}",
            r.price,
            truncate(&r.brand, 18),
            truncate(&r.size, 10),
            truncate(&r.condition, 18),
            r.favs,
            truncate(&r.title, 50)
        );
        println!("           {}", r.url);
    }
    let prices: Vec<f64> = results.iter().map(|r| r.price).collect();
    if prices.len() >= 2 {
        let q = comps::quantiles(&prices, 4);
        let min = prices.iter().copied().fold(f64::INFINITY, f64::min);
        let max = prices.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        println!(
            "\nn={}  min={min:.2}  p25={:.2}  median={:.2}  p75={:.2}  max={max:.2}",
            prices.len(),
            q[0],
            q[1],
            q[2]
        );
    }
    Ok(())
}

fn cmd_new(repo: &Repo, slug: &str, photos: &[PathBuf]) -> Result<()> {
    let slug = slugify(slug);
    let id = format!("{:04}", next_id(repo));
    let item_dir = repo.items().join(format!("{id}-{slug}"));
    fs::create_dir_all(item_dir.join("photos"))?;
    fs::create_dir(item_dir.join("originals"))?;

    let cwd = env::current_dir()?;
    let mut photo_lines = Vec::new();
    for (n, src) in photos.iter().enumerate() {
        let n = n + 1;
        let src = if src.is_absolute() {
            src.clone()
        } else if cwd.join(src).exists() {
            cwd.join(src)
        } else if repo.root.join(src).exists() {
            repo.root.join(src)
        } else {
            repo.inbox().join(src)
        };
        let jpg = item_dir.join("photos").join(format!("{n:02}.jpg"));
        to_jpeg(&src, &jpg, Some(2400))?;
        let original = item_dir.join("originals").join(src.file_name().context("photo without file name")?);
        fs::rename(&src, &original).or_else(|_| fs::copy(&src, &original).and_then(|_| fs::remove_file(&src)))?;
        photo_lines.push(format!("![Foto {n}](photos/{n:02}.jpg)"));
        // Remove an inbox subfolder once it's empty.
        let parent = src.parent().unwrap_or(Path::new(""));
        if parent != repo.inbox() && parent.starts_with(repo.inbox()) && fs::read_dir(parent)?.next().is_none() {
            fs::remove_dir(parent)?;
        }
    }

    let text = fs::read_to_string(repo.template())?
        .replace("{{id}}", &id)
        .replace("{{created}}", &today())
        .replace("{{photos}}", &photo_lines.join("\n"));
    fs::write(item_dir.join("listing.md"), text)?;
    println!("{}", item_dir.join("listing.md").strip_prefix(&repo.root)?.display());
    Ok(())
}

fn cmd_status(repo: &Repo, id: &str, status: Status, price: Option<String>, url: Option<String>) -> Result<()> {
    let listing = repo.find_item(id)?;
    let today = today();
    let mut updates: Vec<(&str, String)> = vec![("status", status.as_str().to_string())];
    let price = price.filter(|p| !p.is_empty());
    match status {
        Status::Listed => {
            updates.push(("listed_at", today));
            if let Some(p) = price {
                updates.push(("price_listed", p));
            }
        }
        Status::Sold => {
            updates.push(("sold_at", today));
            if let Some(p) = price {
                updates.push(("price_sold", p));
            }
        }
        _ => {
            if let Some(p) = price {
                updates.push(("price_listed", p));
            }
        }
    }
    if let Some(url) = url.filter(|u| !u.is_empty()) {
        updates.push(("vinted_url", url));
    }
    listing::update_file(&listing, &updates)?;
    let summary: Vec<String> = updates.iter().map(|(k, v)| format!("{k}={v}")).collect();
    println!("{}: {}", file_name(listing.parent().unwrap()), summary.join(", "));
    inventory::write(repo)
}

fn cmd_set(repo: &Repo, ids: &str, fields: &[String]) -> Result<()> {
    let listings = ids
        .split(',')
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(|id| repo.find_item(id))
        .collect::<Result<Vec<_>>>()?;
    if listings.is_empty() {
        bail!("no item id given");
    }
    let mut updates = Vec::new();
    for field in fields {
        let Some((key, value)) = field.split_once('=') else {
            bail!("expected KEY=VALUE, got {field:?}");
        };
        let key = key.trim();
        if key.is_empty() || key.contains(char::is_whitespace) {
            bail!("invalid key {key:?}");
        }
        updates.push((key, value.trim().to_string()));
    }
    let summary: Vec<String> = updates.iter().map(|(k, v)| format!("{k}={v}")).collect();
    for listing in &listings {
        let fields: Vec<_> = updates.iter().filter(|(key, _)| *key != "description").cloned().collect();
        listing::update_file(listing, &fields)?;
        if let Some((_, title)) = updates.iter().rev().find(|(key, _)| *key == "title") {
            let text = fs::read_to_string(listing)?;
            fs::write(listing, text.replace("# {{title}}", &format!("# {title}")))?;
        }
        if let Some((_, value)) = updates.iter().rev().find(|(key, _)| *key == "description") {
            let text = fs::read_to_string(listing)?;
            fs::write(listing, listing::set_section(&text, "Beschreibung", value))?;
        }
        println!("{}: {}", file_name(listing.parent().unwrap()), summary.join(", "));
    }
    inventory::write(repo)
}

fn cmd_todo(repo: &Repo, id: &str, n: Option<usize>, open: bool, add: Option<String>) -> Result<()> {
    let listing_path = repo.find_item(id)?;
    let text = fs::read_to_string(&listing_path)?;
    if let Some(add) = add.filter(|a| !a.trim().is_empty()) {
        fs::write(&listing_path, listing::add_todo(&text, &add))?;
        println!("{}: added to-do {}", file_name(listing_path.parent().unwrap()), listing::todos(&fs::read_to_string(&listing_path)?).len());
        return Ok(());
    }
    let Some(n) = n else {
        for (i, (done, todo)) in listing::todos(&text).iter().enumerate() {
            println!("{}\t[{}]\t{todo}", i + 1, if *done { "x" } else { " " });
        }
        return Ok(());
    };
    fs::write(&listing_path, listing::set_todo(&text, n, !open)?)?;
    println!("{}: to-do {n} {}", file_name(listing_path.parent().unwrap()), if open { "reopened" } else { "done" });
    Ok(())
}

fn cmd_resolve(repo: &Repo, id: &str, n: usize, resolution: todo::Resolution) -> Result<()> {
    let listing_path = repo.find_item(id)?;
    let (text, frontmatter) = todo::resolve(&fs::read_to_string(&listing_path)?, n, resolution)?;
    fs::write(&listing_path, text)?;
    println!("{}: to-do {n} resolved", file_name(listing_path.parent().unwrap()));
    if frontmatter { inventory::write(repo) } else { Ok(()) }
}

/// Frontmatter keys a draft may set, in template order.
const DRAFT_FIELDS: [&str; 8] = ["title", "brand", "category", "size", "condition", "colors", "material", "price_suggested"];

fn cmd_apply_draft(repo: &Repo, id: &str, file: &Path) -> Result<()> {
    let listing_path = repo.find_item(id)?;
    let json = if file == Path::new("-") {
        std::io::read_to_string(std::io::stdin())?
    } else {
        fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?
    };
    let draft: serde_json::Value = serde_json::from_str(&json).context("draft is not valid JSON")?;
    let text_of = |key: &str| -> String {
        match &draft[key] {
            serde_json::Value::String(s) => s.trim().to_string(),
            serde_json::Value::Number(n) => n.to_string(),
            _ => String::new(),
        }
    };

    let updates: Vec<(&str, String)> =
        DRAFT_FIELDS.iter().map(|k| (*k, text_of(k))).filter(|(_, v)| !v.is_empty()).collect();
    let mut text = listing::set_fields(&fs::read_to_string(&listing_path)?, &updates);

    let title = text_of("title");
    if !title.is_empty() {
        text = text.replace("# {{title}}", &format!("# {title}"));
    }
    for (heading, key) in [("Beschreibung", "description"), ("Preisrecherche", "price_research")] {
        let content = text_of(key);
        if !content.is_empty() {
            text = listing::set_section(&text, heading, &content);
        }
    }
    let mut notes: Vec<String> = text_of("notes").lines().map(String::from).filter(|l| !l.trim().is_empty()).collect();
    if let Some(questions) = draft["open_questions"].as_array() {
        notes.extend(questions.iter().filter_map(|q| q.as_str()).map(|q| format!("- [ ] {}", q.trim())));
    }
    if !notes.is_empty() {
        text = listing::set_section(&text, "Notizen", &notes.join("\n"));
    }
    fs::write(&listing_path, text)?;

    let keys: Vec<&str> = updates.iter().map(|(k, _)| *k).collect();
    println!("{}: applied draft ({})", file_name(listing_path.parent().unwrap()), keys.join(", "));
    inventory::write(repo)
}

// ---------------------------------------------------------------- helpers

fn next_id(repo: &Repo) -> u32 {
    sorted_dir(&repo.items())
        .iter()
        .filter_map(|p| {
            let name = file_name(p);
            let (num, rest) = name.split_at_checked(4)?;
            (num.chars().all(|c| c.is_ascii_digit()) && rest.starts_with('-')).then(|| num.parse().ok())?
        })
        .max()
        .unwrap_or(0)
        + 1
}

fn slugify(text: &str) -> String {
    let lower = text.to_lowercase();
    let mut slug = String::new();
    let mut gap = false;
    for c in lower.chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            if gap && !slug.is_empty() {
                slug.push('-');
            }
            gap = false;
            slug.push(c);
        } else {
            gap = true;
        }
    }
    slug
}

fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

pub fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
}

pub fn sorted_dir(dir: &Path) -> Vec<PathBuf> {
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    entries.sort();
    entries
}

/// All files below `dir`, sorted (like Python's `sorted(rglob("*"))`).
pub fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in sorted_dir(dir) {
        if entry.is_dir() {
            files.extend(walk(&entry));
        } else {
            files.push(entry);
        }
    }
    files.sort();
    files
}

/// First `n` characters (Python's `s[:n]`), padded by the caller's format width.
fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_matches_python() {
        assert_eq!(slugify("C&A Jeans hellblau W34 L30"), "c-a-jeans-hellblau-w34-l30");
        assert_eq!(slugify("--Größe M--"), "gr-e-m");
        assert_eq!(slugify("smog-hemd-grau"), "smog-hemd-grau");
    }

    #[test]
    fn groups_only_loose_inbox_photos() {
        let temp = tempfile::tempdir().unwrap();
        let repo = Repo { root: temp.path().to_path_buf() };
        fs::create_dir(repo.inbox()).unwrap();
        fs::write(repo.inbox().join("front.jpg"), b"photo").unwrap();
        fs::write(repo.inbox().join("back.jpg"), b"photo").unwrap();
        assert!(cmd_group(&repo, "Jacke", &[PathBuf::from("../outside.jpg")]).is_err());
        cmd_group(&repo, "Jacke", &[PathBuf::from("inbox/front.jpg"), PathBuf::from("back.jpg")]).unwrap();
        assert!(repo.inbox().join("jacke/front.jpg").is_file());
        assert!(repo.inbox().join("jacke/back.jpg").is_file());
        assert!(!repo.inbox().join("front.jpg").exists());
    }

    #[test]
    fn detects_images() {
        assert!(is_image(Path::new("a/IMG_1.HEIC")));
        assert!(is_image(Path::new("b.jpg")));
        assert!(!is_image(Path::new(".gitkeep")));
    }

    #[test]
    fn set_description_updates_body_without_changing_notes() {
        let temp = tempfile::tempdir().unwrap();
        let repo = Repo { root: temp.path().to_path_buf() };
        let folder = repo.items().join("0001-test");
        fs::create_dir_all(&folder).unwrap();
        let path = folder.join("listing.md");
        fs::write(&path, "---\nid: 0001\ntitle: Test\nstatus: planned\n---\n\n## Beschreibung\n\nAlt.\n\n## Notizen\n\n- [ ] TODO: prüfen\n").unwrap();
        cmd_set(&repo, "1", &["description=Neu.\n\n#kleidung".into()]).unwrap();
        let text = fs::read_to_string(path).unwrap();
        assert!(text.contains("Neu.\n\n#kleidung"));
        assert!(text.contains("- [ ] TODO: prüfen"));
        assert!(!text.contains("description:"));
    }
}
