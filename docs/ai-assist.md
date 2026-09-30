# AI assist roadmap

`./vinted agent` is the single entry point for AI work. It owns provider detection, per-user
settings, task prompts, process permissions, cancellation, and event parsing. The macOS app runs
this CLI and renders its JSON-line event stream; other desktop apps can do the same.

## Current workflow

| Command | Purpose |
|---|---|
| `./vinted agent status --json` | Installed providers, login status, settings |
| `./vinted agent config path` | Per-user settings file location |
| `./vinted agent config set claude.model sonnet` | Change a provider setting |
| `./vinted agent run draft inbox/jacket --json` | Draft one listing |
| `./vinted agent run cluster inbox/front.HEIC inbox/back.HEIC --json` | Group an imported photo batch by item |
| `./vinted agent run inbox --json` | Process the inbox |
| `./vinted agent run price 0001 --json` | Re-check a price |
| `./vinted agent run instruction "item 4 sold for 4 €" --provider codex --json` | Free-form task |

Claude Code and Codex use their own installed CLIs and your login. Claude runs with `dontAsk`
and a restricted tool list; Codex runs in a workspace sandbox with network access for price
research. The Rust CLI translates their output into `run`, `started`, `tool`, `message`, `notice`,
and `finished` events. A non-interactive run follows `AGENTS.md` and the process-inbox skill.
The app's Settings › Agents reads and writes the CLI's per-user configuration. Existing app
preferences are imported once if no CLI configuration exists.
The inbox's automatic grouping toggle is on by default. On import, the app asks the configured
agent to inspect only the new batch and use `./vinted group` to create one folder per item.
Turning the toggle off restores manual grouping controls; loose photos can also be grouped later.

## Next steps

1. **Review loop:** show a draft's open questions as forms in the app, then resume its agent
   session through a CLI command.
2. **Apple Intelligence:** a small Swift helper exposes Apple's on-device model to Rust.
   The CLI supplies photos, instructions and comparable listings, receives a structured draft,
   and applies it with `./vinted apply-draft`. Other platforms can use a local model or API helper.
3. **More providers:** add adapters behind `./vinted agent`, keeping the event format stable.
4. **Phones:** expose the Rust task and listing logic as a library for iOS and Android, where
   launching agent executables is unavailable.
