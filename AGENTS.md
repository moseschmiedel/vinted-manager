# Vinted selling

Tracks items for sale on Vinted (vinted.de). The data is Markdown + photos. Code:

- `./vinted` — the CLI (Rust, source in `cli/`). The launcher rebuilds it when the source
  changes; ImageMagick is used for photo conversion. All changes to items go through it.
- `./vinted group <name> <inbox-photo>...` moves loose inbox photos into one item folder.
- `app/` — native macOS app (SwiftUI, see `app/README.md`). A GUI over the same files;
  it calls `./vinted` for anything that writes.

## Layout

- `inbox/` — drop zone. New photos land here. A subfolder = one item with several photos.
- `items/NNNN-slug/listing.md` — one item: frontmatter metadata + German listing text.
  `photos/` holds upload-ready JPEGs (upright, metadata/GPS stripped), `originals/` the source files
  (git-ignored: they still contain GPS/EXIF data).
- `INVENTORY.md` — generated overview. Never edit by hand; run `./vinted index`.
- `templates/listing.md` — template for new items.
- `cli/` — Rust source of `./vinted`. `app/` — the macOS app.

## Statuses

`planned` (not on Vinted yet) → `listed` → `reserved` → `sold`, or `withdrawn`.

## Skills

Task playbooks live in `.agents/skills/<name>/SKILL.md` (Agent Skills format;
`.claude/skills` is a symlink to it). If your agent doesn't load skills automatically,
read the matching `SKILL.md` before starting the task.

| Skill | Use when |
|---|---|
| [`process-inbox`](.agents/skills/process-inbox/SKILL.md) | New photos in `inbox/`, or the user asks to create listings |

## Common requests

- **"I added photos" / "process the inbox"** → follow `.agents/skills/process-inbox/SKILL.md`.
- **"I listed item 2 for 5 €"** → `./vinted status 2 listed --price 5 [--url …]`
- **"Item 2 sold for 4 €"** → `./vinted status 2 sold --price 4`
- **"Item 2 belongs to Anna"** → `./vinted set 2 owner=Anna` (the person's wallet in INVENTORY.md);
  several at once: `./vinted set 2,5,7 owner=Anna`
- **"Help me list item 2"** → show the Vinted form fields from `listing.md` in upload order
  (photos path, title, description, category, brand, size, condition, colors, material,
  price), each in its own code block for easy copying. Remind about open TODOs in Notizen.
- **"Re-check the price"** → `./vinted comps "<query>" [--brand B] [--size S]`,
  then `./vinted set <id> price_suggested=…` and rewrite the Preisrecherche section.

Change fields through the CLI: `./vinted status` for status/price/link,
`./vinted set <id> key=value …` for any other frontmatter field, `./vinted todo <id> [n] [--open]`
to list or check off to-dos in Notizen (`--add "…"` appends one), and
`./vinted apply-draft <id> draft.json` to fill a new item from a JSON draft (title, brand,
category, size, condition, colors, material, price_suggested, description, price_research,
open_questions). Editing listing.md by hand is fine for the text sections; keep the `# comments`.

## To-dos, questions and suggestions

Checkbox lines under Notizen are the to-do list. The app shows them in its sidebar, and the user
deals with them whenever it suits them — agents never wait for an answer. Three kinds:

- `- [ ] TODO: Mantel abbürsten` — something the user has to do or check.
- `- [ ] QUESTION(material): Welches Material steht auf dem Etikett? | Wolle | Polyester` — a fact
  only the user knows. `(field)` names the frontmatter key the answer fills (optional); the
  `| options` are optional quick answers.
- `- [ ] SUGGEST(price_suggested=12): 5 Vergleichsangebote bei 11–15 €` — a proposed change the user
  accepts or dismisses. For a description, use `SUGGEST(description): Begründung` with the proposed
  text on indented `  > ` lines below it.

Resolve them with `./vinted answer <id> <n> <answer>`, `./vinted accept <id> <n> [--value V]` and
`./vinted dismiss <id> <n>`. That checks the line and records the outcome
(`→ Antwort: …`, `→ angenommen`, `→ abgelehnt`), so later runs can use the answers.

## Agent runs

`./vinted agent` and the app can start Claude Code or Codex in this repository with your own login. Those runs are
non-interactive: don't ask questions, record anything unclear as `- [ ] TODO:` under Notizen and
list open questions at the end of the reply. Claude runs with `dontAsk` and may only use file
tools, web search and `./vinted`/`magick`; Codex runs in the `workspace-write` sandbox with
network access for `./vinted comps`.

## Wallets

`owner:` in the frontmatter says whose item it is, i.e. who gets the money. INVENTORY.md sums
revenue, asking and planned value per owner. Use the name exactly as it's already written on other
items. Never guess an owner from the photos; leave it empty unless the user says whose it is.

## Conventions

- Listing text (title, description, categories, conditions) is in German, prices in EUR.
- Never invent facts not visible in the photos; leave the field empty and add a
  `- [ ] TODO` to Notizen instead.
