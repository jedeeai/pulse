# Pulse

[中文说明](README.zh-CN.md)

A macOS menu bar app that shows your Claude Code and Codex usage at a glance: today's token count, how fast you're burning through your current 5-hour window, and how much of your weekly quota is left. Everything is parsed locally from your own session files, no telemetry, no account required.

<!-- screenshot: docs/panel.png -->
![Pulse panel](docs/panel.png)

## Features

- **Menu bar glance**: a small ring showing how much quota is left in the current 5-hour window, time until it resets, today's total token count, and your weekly quota remaining, e.g. `◔ 4:47  176M  27%`.
- **Expandable panel** with five cards:
  - **Today's tokens**: total plus a breakdown per tool.
  - **5-hour countdown**: a ring (fill = quota remaining, not time) with the remaining time inside it, plus a pace label (On track / Fast / Too fast).
  - **Plan quota**: 5-hour and weekly progress bars, with a Claude / Codex switcher in the corner (your choice is remembered).
  - **5-day trend** line chart.
  - **Monthly heatmap** calendar of daily activity.
- **100% local token stats** — parses `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/*.jsonl` directly, no network call involved.
- **Quota reuses your existing login** — Claude quota is read using the OAuth token your local Claude Code CLI already has; Codex quota is read from files Codex itself already writes locally. Pulse never asks you to log in separately.
- **Event-driven, not polling** — after an initial one-time scan, an FSEvents watcher picks up new sessions incrementally. CPU usage is 0% while idle.
- **Follows your system language** — Chinese system shows Chinese labels and 亿/万 units; anything else shows English and B/M/K units.
- **Colorblind-safe** — status is never conveyed by red vs. green alone; every state has a text label, and the only accent colors used are blue and orange.
- Single-instance (a second launch quits immediately), quit from the "Quit" button at the bottom of the panel.

## Install

### Option A: Download a release

1. Download the latest zip from [Releases](../../releases), unzip it, and drag `Pulse.app` into `/Applications`.
2. Pulse isn't notarized or signed with an Apple Developer certificate, so Gatekeeper will block the first launch ("Pulse.app is damaged" or "cannot be opened"). Fix it with either:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Pulse.app
   ```
   or right-click `Pulse.app` → **Open** → confirm in the dialog.

### Option B: Build from source

Requires macOS 13+ and Xcode Command Line Tools (no full Xcode needed):

```bash
xcode-select --install   # skip if already installed
git clone https://github.com/jedeeai/pulse.git
cd pulse
bash scripts/build-app.sh
open dist/Pulse.app
```

## How it works

Pulse only ever looks at data your CLI tools already generate on disk, and re-uses credentials they've already stored.

| Tool | Tokens source | Quota source |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl`, deduplicated by `message.id`. Counted as input + output + cache_creation + cache_read (matches ccusage's Total). | `https://api.anthropic.com/api/oauth/usage` (the same endpoint claude.ai/settings/usage uses), authenticated with the `accessToken` your local Claude Code CLI already stored in the Keychain (`Claude Code-credentials`), or `~/.claude/.credentials.json` as a fallback. |
| Codex | `~/.codex/sessions/**/*.jsonl` `token_count` events. Counted as input + output + reasoning. | The most recent `rate_limits` event Codex itself writes into your local session file after each request — Pulse makes no network call for this. It only appears, and only updates, once you've actually used Codex. |

Only tools you actually have installed and have used will show data.

Scanning is event-driven: Pulse does one full scan on launch (which can take up to a minute or so on very large histories, shown as `…` in the menu bar), then listens for filesystem changes and only re-parses what changed. Claude quota is polled every 5 minutes; the 5-hour window auto-refreshes when it resets.

## Privacy

- **Reads**: your local `~/.claude` and `~/.codex` session files (never modified), and the Claude Code OAuth `accessToken` from your Keychain.
- **Never reads or touches**: your Claude Code `refreshToken` — Pulse only ever reads the short-lived `accessToken` and never writes to the Keychain or your credential files.
- **Sends**: exactly one kind of network request — to Anthropic's own usage endpoint, using your own already-issued token, to read your remaining quota. That's it.
- **Never sends**: source code, prompts, conversation content, file contents, or any analytics/telemetry. Pulse has no backend of its own.
- **Fully offline mode**: switch the plan quota card to Codex and Pulse makes zero network requests, since Codex quota is read from local files only.

## Menu bar & panel

Menu bar example: `◔ 4:47  176M  27%`

- `◔` — a small ring: how much quota is *left* in the current 5-hour session window (a full ring = full quota remaining, an empty ring = about to hit the limit).
- `4:47` — time remaining until that 5-hour window resets.
- `176M` — total tokens used today, across all tools.
- `27%` — your weekly quota remaining.

In the panel, the 5-hour card shows the same ring (fill = quota remaining), but with the *time* remaining written inside it — the two numbers are meant to be compared against each other. Next to it is a pace label:

- **On track** (blue): remaining-quota fraction minus remaining-time fraction is ≥ 0 — you'll comfortably make it to reset.
- **Fast** (orange): that gap is between -20 and 0 — you're burning quota faster than time is passing.
- **Too fast** (bold orange): that gap is below -20 — you're on track to run out before the window resets.

## Accessibility

Pulse is built by and for someone with red-green color blindness, so:

- No status is ever conveyed by red vs. green alone.
- The only accent colors used for state are blue and orange, chosen to stay distinguishable under red-green color blindness.
- Every colored state also has a text label (e.g. "On track" / "Fast" / "Too fast") — color is decoration, not the only signal.

## Customize / Fork

The codebase is small and split by concern:

- `Sources/Pulse/UsageScanner.swift` — parses local session files into token counts.
- `Sources/Pulse/PlanUsage.swift` + `Sources/Pulse/CodexQuota.swift` — quota fetching/adapters for Claude and Codex respectively.
- `Sources/Pulse/PulseApp.swift` — menu bar item and panel UI.
- `Sources/Pulse/L10n.swift` — user-facing strings and number formatting.

To add support for another tool, write an adapter that follows the Codex one (a local-file reader, no login flow) or the Claude one (an OAuth-token reuse reader), then wire it into the scanner and the panel's tool switcher.

## Roadmap

- Estimated cost ($) alongside token counts.
- Support for more coding agents.

## License

[MIT](LICENSE)
