# Vinted Manager (macOS app)

A native SwiftUI app for managing Vinted listings on macOS 26+. Listings and photos
stay in a folder you choose, using the same Markdown format as `./vinted`.
The packaged app includes the CLI and a native photo converter: recipients do not
need this source checkout, Rust, Xcode, Homebrew, ImageMagick, or an AI assistant.

On first launch choose **New Library…**, then a location for your listings and photos,
or **Open Library…** to use an existing library. Copy the app to `/Applications`;
keep the library in a writable folder outside the app bundle. The library choice is remembered.
Libraries can be copied to another Mac; they contain your data, a standalone CLI,
the listing template, and the agent instructions. They also contain original photos
with their source metadata, so share a library only when you intend to share those originals.

One window in the macOS 26 Liquid Glass style: a glass toolbar, the dashboard, and a floating glass
sidebar for to-dos and agent runs.

- **Toolbar:** filter by person (Everyone / one wallet), Gallery or Compact board, asking and
  revenue totals, reload, and the to-do sidebar toggle with the number of open to-dos.
- **Inbox:** the drop zone. Drop photos (or choose them) to copy them into `inbox/`.
  Without AI, “Several photos = one item” groups an import. Use **Create listing** on a group,
  then fill in the fields and description on its item page. With a ready assistant, “Group by item”
  is on by default and asks the configured agent to inspect each new batch, then put photos of the
  same item in a folder. Turn it off to use “Several photos = one item” manually. Each inbox group
  has “Draft with AI”; “Process inbox” drafts them all.
- **Items:** a kanban board (Planned, Listed, Reserved, Sold; Withdrawn when used). **Gallery** shows
  photo cards (busy columns get more room) with glass tags for size and open questions, suggestions
  and to-dos; **Compact** shows rows. Click a card for the item page, drag it to another column (or
  use the context menu) to change its status. Right-click › Belongs to assigns the item to a person.
  ⌘-click (or ⇧-click) cards to select several — or right-click a column header › Select All — then
  assign or move them together from the glass bar at the bottom (Esc clears); dragging a selected
  card moves the whole selection. A card the agent is working on gets a purple outline.
- **Wallets:** revenue (sold), asking (listed/reserved) and planned value per person, from the
  `owner` field. Click a wallet to show only that person's items and to-dos.
- **Item page:** a large photo (drag it straight into Vinted's upload in the browser) with a strip of
  all photos, the owner menu, every Vinted form field with a copy button and a pencil to edit it
  (`vinted set`), the description, status/price/link editor, price research and notes. Open
  questions and suggestions from the agent appear right at their field, answerable in place.
- **Sidebar** (toggle in the toolbar), three tabs:
  - **To-dos:** “From your agent” — questions (quick answers, a text field, “Can't tell”) and
    suggestions (Accept, Edit…, Dismiss; description changes show the proposed text) — and
    “For you”, the plain checkbox to-dos. On an item page it shows only that item's to-dos, plus
    “Update listing with my answers”, which lets the agent work the answers into title and
    description.
  - **Agent runs:** ask your agent anything (“item 4 sold for 4 €”); each run shows its title,
    current step and a stop button. Click a run for the transcript.
  - **Done:** finished to-dos with the answer or outcome.
- **Live updates:** the app watches `items/` and `inbox/`, so changes made by an agent or the
  CLI show up immediately.
- **Agents (optional):** Claude Code or Codex run with your own login. Configure them in
  **Settings › Agents** (⌘,): executable, model, environment variables. Detection checks
  the executable and login status. AI actions appear only with a ready assistant;
  manual imports, listing creation, editing, to-dos, statuses and wallets work without one.
  After installing or logging in to an assistant, use **Check again** in Settings.

### Questions and suggestions

Agents never wait for an answer. They write what they need to know as typed to-dos in Notizen
(`QUESTION(field): …`, `SUGGEST(key=value): …`, see AGENTS.md), and you answer whenever it suits
you. Answering runs `vinted answer` / `accept` / `dismiss`, which fills the field and records the
outcome in the to-do line, so the next agent run sees it.

## Build and run

Building from source requires macOS 26+, Xcode 26+ (Swift 6.2+) and Rust (`rustup`).
The app requires macOS 26+ because it uses Liquid Glass. The bundle declares the same minimum.

```sh
app/build-app.sh                      # → app/build/Vinted Manager.app
open "app/build/Vinted Manager.app"
```

The default build targets the build machine's architecture and is ad-hoc signed for local testing.
For development: `cd app && swift run VintedManager`, and `swift test` for the tests.
Source-checkout photo conversion through `./vinted` requires ImageMagick; packaged builds use ImageIO.

The app finds the repository by walking up from its own location (so the built app inside
`app/build/` just works). Otherwise use **File › New Library…** or **Open Library…** (⌘O).

## Direct distribution

Build for both Apple silicon and Intel Macs:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
ARCHS="arm64 x86_64" app/build-app.sh
app/make-dmg.sh                       # → app/build/Vinted-Manager.dmg
```

`make-dmg.sh` wraps the app in a disk image that opens as a "drag to Applications" window
(layout in `dmg/settings.py`, background drawn in `dmg/background.svg`). It uses
[dmgbuild](https://github.com/dmgbuild/dmgbuild), installed with `pipx install dmgbuild`
or run through `uvx` automatically.

For a release that passes Gatekeeper, install a **Developer ID Application** certificate
and store your notarization credentials with `xcrun notarytool store-credentials`.
Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
describes certificate and Keychain profile setup. Then run:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="vinted-notary" \
APP_VERSION="0.1.0" APP_BUILD="1" \
app/package-release.sh
```

The release script builds a universal app, signs its nested executables and app with
the hardened runtime and timestamps, submits it to Apple, checks for acceptance,
staples the ticket and verifies Gatekeeper acceptance. It then puts the app in
**app/build/Vinted-Manager.dmg**, which it signs, notarizes and staples as well.
It sends only the app and the disk image to Apple; no libraries, listings, photos or agent credentials are bundled.
`ARCHS=arm64` or `ARCHS=x86_64` can be used for an architecture-specific release.
Ad-hoc builds are for local testing and are not a notarized public release.

Before distributing, test the downloaded disk image on another Mac with macOS 26+ and no
developer tools or AI CLIs: move it to Applications, create a library, import photos,
create/edit a listing, change its status, quit and reopen. Also test with an installed
but logged-out assistant, and then with one logged in. Only the last case should expose AI actions.

## GitHub Actions and Releases

Use **GitHub Releases** for app downloads. GitHub Packages provides registries for
package ecosystems and container images; Releases can attach the disk image and its
checksum directly. See [GitHub's release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

Two workflows are included:

- **macOS build** (`.github/workflows/macos.yml`) runs on PRs, pushes to `main`, or
  manually from Actions. It tests and builds separately on Apple silicon and Intel
  macOS 26 runners. Download the ad-hoc signed test disk images from the run's Artifacts.
  These expire after 14 days and are intended for testing.
- **Release macOS app** (`.github/workflows/release.yml`) runs when you push a tag
  such as `v0.1.0`. It tests, builds a universal app, signs and notarizes it, then
  publishes a GitHub Release with `Vinted-Manager.dmg`, a SHA-256 checksum, and
  generated release notes. Failed notarization stops the workflow before it publishes
  anything. Release tags must be `vMAJOR.MINOR.PATCH`.

Without any Apple secrets, the release workflow publishes an **ad-hoc signed** build instead,
with a note in the release explaining how to get past Gatekeeper (`xattr -dr com.apple.quarantine`
or **Open Anyway** in System Settings › Privacy & Security). Setting only some of the secrets
fails the workflow, so a typo can't silently downgrade a release.

For notarized releases, configure these repository secrets in
**Settings › Secrets and variables › Actions**:

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate **and private key**, exported from Keychain Access as a password-protected `.p12`, then base64 encoded |
| `P12_PASSWORD` | Password for that `.p12` export |
| `SIGNING_IDENTITY` | Full certificate name, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that account, used by `notarytool` |

To copy the certificate to your clipboard without printing it in a terminal:

```sh
base64 -i /path/to/DeveloperID.p12 | pbcopy
```

The release job imports credentials into a temporary keychain and deletes it when
the job ends, following [GitHub's certificate installation guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
Only the release job has permission to write Releases. PR builds have read-only
repository access and do not use Apple credentials. No personal access token is
required: publication uses the workflow's `GITHUB_TOKEN`.

After committing the app and workflows to a GitHub repository, publish a version:

```sh
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

The tag controls the app's displayed version; the workflow run number supplies its
build number. A published version is immutable in this workflow: a rerun will refuse
to create a Release that already exists. Push a new version tag for the next release.
For a private repository, recipients need repository access to download its releases;
use a public repository if you want public downloads.

## Structure

| Path | Purpose |
|---|---|
| `Sources/VintedCore/` | UI-free logic: parsing `listing.md`, loading items and the inbox, importing photos, running `./vinted` |
| `Sources/VintedManager/` | SwiftUI app: store, file watcher, thumbnails, views |
| `Tests/VintedCoreTests/` | Parser tests plus write tests on a temporary repository with sample items |
| `Resources/AppIcon.icon` | App icon (Icon Composer format, SVG layers); `build-app.sh` compiles it with `actool` |

Reading is done in Swift. **All writes to items go through `./vinted`** (e.g. `vinted status`),
so dates, formatting and `INVENTORY.md` stay exactly as the CLI and agents produce them.
Importing photos into `inbox/` is the only data the app writes itself; library creation
also goes through `vinted init`. Description editing uses `vinted set ID description=…`.
The packaged app always runs its own matching CLI against the selected library,
and passes that runtime to agent runs. A new library also gets a portable CLI copy
so `./vinted` works in a terminal without Rust.

## Agents

`./vinted agent` owns provider detection, settings, prompts, permissions, and stream parsing.
The app uses your own agent login and only displays CLI results:

| File | Purpose |
|---|---|
| `AgentProvider.swift` | UI types decoded from `./vinted agent status --json` |
| `AgentTask.swift` | Maps app actions to `./vinted agent run` commands |
| `AgentRun.swift` | Starts the Rust CLI and streams its JSON lines |
| `AgentEvent.swift` | Decodes the shared CLI event format |

Provider integrations and future model helpers belong behind the Rust CLI; see
[`docs/ai-assist.md`](../docs/ai-assist.md) for the roadmap.
