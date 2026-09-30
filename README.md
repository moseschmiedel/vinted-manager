# Vinted Manager

Tools for selling on Vinted: a Rust CLI and a native macOS app that keep track of what you plan
to sell, what's listed and what's sold. Items are plain Markdown + photos in a folder (a "selling
library"); `./vinted index` writes an `INVENTORY.md` overview.

This repository contains only the code. Your own items, photos and `INVENTORY.md` are
git-ignored here — keep them in a separate library (the app can create one) or a private fork.

## Workflow

1. **Photograph** items and drop the photos into [`inbox/`](inbox/).
   One photo per item, or put several photos of the same item in a subfolder
   (`inbox/blue-jacket/…`).
2. **Generate listings**: ask your coding agent to "process the inbox" (in Claude Code:
   `/process-inbox`). For every item it
   - writes title, description, category, size, condition, colours, material,
   - searches similar live listings on vinted.de and suggests a price,
   - creates `items/NNNN-slug/` with upload-ready JPEGs (upright, GPS removed).
3. **Review** each `listing.md`, fix anything marked `- [ ] TODO`.
4. **List on Vinted** (manually — ask the agent "help me list item 1" to get copy-paste fields),
   then tell the agent or run:
   ```sh
   ./vinted status 1 listed --price 6 --url https://www.vinted.de/items/…
   ```
5. **Sold?**
   ```sh
   ./vinted status 1 sold --price 5
   ```

## Commands

```sh
./vinted inbox                        # list inbox photos (+ previews)
./vinted group "blaue jacke" inbox/front.HEIC inbox/back.HEIC
./vinted comps "levis 501" --size M   # comparable Vinted listings + price stats
./vinted new <slug> <photo>...        # create an item from inbox photos
./vinted status <id> <status> [--price P] [--url U]
./vinted set <id> key=value ...       # set any frontmatter field
./vinted apply-draft <id> draft.json  # fill an item from a JSON listing draft
./vinted index                        # regenerate INVENTORY.md
./vinted agent status --json          # installed agents, login and settings
./vinted agent run inbox --json       # run an agent with a shared event stream
./vinted agent run cluster inbox/front.HEIC inbox/back.HEIC --json
./vinted agent run price 1 --provider codex
./vinted agent config set claude.model sonnet
```

Statuses: `planned`, `listed`, `reserved`, `sold`, `withdrawn`.

`./vinted` runs the Rust CLI in [`cli/`](cli/) and rebuilds it when the source changed.
Requires Rust (`rustup`) and ImageMagick (`brew install imagemagick`) for HEIC conversion and
removing photo metadata.

## macOS app

[`app/`](app/) is a native app for the same workflow: browse items by status, drop photos into
the inbox, copy the Vinted form fields, drag photos into the browser upload, and set status and
prices. It can also run Claude Code or Codex with your own login to draft listings, re-check
prices or carry out instructions like "item 4 sold for 4 €". The Rust CLI handles all agent
interaction. Build the app with `app/build-app.sh` —
details and signing/notarization instructions in [`app/README.md`](app/README.md).
Packaged builds include the CLI and photo converter and can create an empty selling library
on another Mac (macOS 26+); AI assistance is optional and appears when an installed assistant
is logged in. The AI roadmap is in [`docs/ai-assist.md`](docs/ai-assist.md).

## Agents

Instructions live in [`AGENTS.md`](AGENTS.md) (`CLAUDE.md` just imports it) and skills in
[`.agents/skills/`](.agents/skills/) (`.claude/skills` is a symlink), so Claude Code, Codex,
Cursor, Gemini CLI and other agents that read `AGENTS.md` / Agent Skills all use the same playbooks.

Price research reads the public vinted.de search page. Those are **asking prices** of active
listings, not sold prices — treat the suggestion as a starting point.
