---
name: process-inbox
description: Turn photos in inbox/ into Vinted listing drafts (item metadata, description, price suggestion from comparable Vinted listings). Use when the user says they added photos, asks to process the inbox, or asks to create listings.
---

# Process the inbox

Turn every photo in `inbox/` into an item under `items/` with a finished `listing.md`.
Listing text is German (vinted.de); prices are EUR.

## 1. Look at the photos

```sh
./vinted inbox
```

This prints each photo with its group and a JPEG preview path under `.cache/previews/`
(HEIC can't be viewed directly). Open and look at every preview image.

Grouping:
- A subfolder in `inbox/` is **one item** with several photos (`group=<folder>`).
- Loose photos (`group=-`) are one item each, **unless** they clearly show the same
  item (same garment from another angle, a close-up of its label). Then group them.
- If unsure whether two photos are the same item, ask the user.

## 2. Identify each item

Read everything visible: brand, size and fit from labels, material/care tags, colour,
pattern, cut, special features (pockets, buttons, collar type). Judge the condition
from what you can see — default to `Sehr gut` for clean used items; never claim
`Neu mit Etikett` unless a tag is visible.

Never invent facts you can't see. If the size or material is not readable, leave the
field empty and add a question under **Notizen**, e.g.
`- [ ] QUESTION(size): Welche Größe steht auf dem Etikett?` — the answer fills the field
when the user replies in the app (see "To-dos, questions and suggestions" in AGENTS.md).

## 3. Research the price

Search live listings for comparable items, from specific to broad:

```sh
./vinted comps "c&a jeanshemd herren" --brand "C&A"
./vinted comps "jeanshemd herren" --size M
```

- Run 2–4 queries per item. Use German terms buyers would type.
- Prefer comps with the same brand, similar type and condition. Ignore outliers
  (bundles, "Neu mit Etikett" if ours is used, very different items).
- These are **asking prices of active listings**, not sold prices. Items that sell
  fast are usually priced at or a little below the median of good comps, so suggest
  a price around the p25–median range, rounded to a whole euro (or x.50 under 10 €).
- Popular comps (many ♥ favourites) show what buyers want; mention that in the note.

If the comps command fails (Vinted changed its page or blocked the request), fall back
to your web search / fetch tools on vinted.de and say in the listing that the research is thinner.

## 4. Create the item

```sh
./vinted new <short-german-slug> inbox/IMG_0001.HEIC [inbox/IMG_0002.HEIC …]
```

This creates `items/NNNN-slug/` with JPEG photos (upload-ready), moves the originals
into `originals/`, and writes `listing.md` from the template. Pass the photo you want
as the Vinted cover first.

## 5. Fill in listing.md

- Frontmatter: fill `title`, `brand`, `category`, `size`, `condition`, `colors`,
  `material`, `price_suggested`. Leave `status: planned`. Keep the comments.
- Replace `{{title}}` in the heading with the title.
- **Title**: `Marke + Artikel + wichtigstes Merkmal + Größe`, e.g.
  `C&A Jeanshemd Western Style dunkelblau Gr. M`. Max ~60 chars.
- **Beschreibung**: friendly, factual, 3–6 short lines — what it is, fit, material,
  condition, size. End with a line of relevant hashtags (max 5). No emojis spam,
  no invented measurements.
- **Preisrecherche**: a small table of the 3–6 best comps (price, brand, size,
  condition, link) plus one sentence on how you chose the price.
- **Notizen**: `QUESTION(field): …` for facts only the user can tell (size, material, brand),
  `TODO: …` for things to do or check (flaws, measurements, cleaning).

## 6. Wrap up

```sh
./vinted index
```

Then report a short table to the user: ID, title, suggested price, open TODOs.
