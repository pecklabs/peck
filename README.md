# Peck

A lightweight macOS **menu bar** app that watches your GitHub pull requests and helps you review them with a Claude agent. Native SwiftUI, single self-contained `.app`, no Node/Electron runtime.

## What it does

- **Review queue with an AI agent.** When someone requests your review, an agent reads the PR and drafts a plain-language **explanation** plus a recommended verdict (**Approve / Request changes / Comment**) and a ready-to-post review body. You confirm with one click before anything is posted to GitHub.
  - The agent is steered by **skills** — markdown instruction files you can add or edit (see below).
- **Your PRs at a glance.** A dashboard shows every PR you authored with its review decision, CI checks, approval count, and pending reviewers.
- **Gamified review progress.** Each of your PRs shows a "review quest" — a mascot that levels up as approvals come in, toward the number of approvals the branch actually requires (read from branch-protection rules). Conflicts show a "boss" state.
- **Approved-but-conflicted is called out.** A PR that is fully approved but blocked by a merge conflict gets a distinct orange treatment (and a notification) so it never silently stalls.
- **Menu bar shows two live counts:** how many of your PRs **need action** (mergeable now, or a conflict to fix) and how many PRs are **waiting for your review**.
- **Language option.** Choose the language for the explanation you read and, separately, for the review body posted to GitHub (e.g. read in Korean, post in English). Currently English / 한국어.
- **Near-real-time, no server.** A cheap conditional poll of GitHub's Notifications API (free `304`s) fires an immediate desktop notification the moment a review is requested. Also notifies on conflicts and "all approved".

Secrets (GitHub token, Anthropic key) are stored in the **macOS Keychain** — never in plain files.

## Requirements

- macOS 14+
- Xcode / Swift 6 toolchain (`swift --version`)
- For GitHub: either the [`gh` CLI](https://cli.github.com) logged in (`gh auth login`), or a personal access token with `repo` + `read:org` scopes
- For the agent: one of — the `claude` CLI (Claude Code), the `codex` CLI, or an Anthropic API key

## Build & run

```bash
cd macos
./build.sh            # builds and assembles "build/Peck.app"
open "build/Peck.app"
```

The app appears as an icon in the menu bar (no dock icon). Click it, open **Settings**, connect GitHub, pick an agent backend, and it starts polling.

For development you can also just run `swift run` from `macos/` (notifications need the bundled, signed `.app`).

## Authentication & agent backends

**GitHub** — two ways, chosen in Settings:
- **GitHub CLI (recommended):** "Sign in with GitHub CLI" reuses your existing `gh auth login` token via `gh auth token`. Nothing to paste. Run `gh auth login` in a terminal first if needed.
- **Personal access token:** paste a `repo` + `read:org` token; it's stored in the Keychain.

**Review agent** — pick a backend in Settings (no API key needed for the CLI options):
- **Claude Code (`claude` CLI):** runs `claude -p` headless, using your existing Claude login/subscription.
- **Codex / ChatGPT (`codex` CLI):** runs `codex exec` with a strict output schema, using your ChatGPT login.
- **Anthropic API key:** calls the Messages API directly with forced tool-use (most deterministic); requires a key billed to your account, and lets you set the model.

> Note: a ChatGPT or Claude *web subscription* can't be called as an API directly — but the `claude`/`codex` CLIs already authenticate with those logins, so routing the review through them is how you "use your login" without a separate API key.

## Distribution (signed + notarized DMG)

The app can't be sandboxed (it spawns `gh`/`claude`/`codex` and uses the Keychain), so it ships as a **Developer ID**-signed, notarized DMG — not via the Mac App Store.

One-time setup:
1. Join the Apple Developer Program ($99/yr).
2. Create a **Developer ID Application** certificate in your login keychain (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application). Check with `security find-identity -v -p codesigning` — you need a `Developer ID Application: …` entry (an `Apple Development` cert is **not** enough).
3. Create a notarization profile with an [app-specific password](https://appleid.apple.com):
   ```bash
   xcrun notarytool store-credentials "PRAgentNotary" \
     --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
   ```

Each release:
```bash
cd macos
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="PRAgentNotary" \
./release.sh
```
This builds, signs (hardened runtime), notarizes, staples, and produces `build/Peck.dmg` that installs without Gatekeeper warnings.

> Recipients still need one agent backend available — the `gh`/`claude`/`codex` CLIs or an Anthropic API key.

## Auto-update (Sparkle)

The app embeds [Sparkle](https://sparkle-project.org). It checks an appcast feed and updates itself in the background; users can also pick **Check for Updates…** from the menu.

Setup:
1. Generate an EdDSA key pair once with Sparkle's tools: `./bin/generate_keys` prints the **public** key (and stores the private key); `./bin/generate_keys -x private.key` exports the **private** key.
2. Build with the feed + public key wired in (the `release.sh` / CI path passes these):
   ```bash
   SU_PUBLIC_KEY="<public key>" \
   SU_FEED_URL="https://github.com/OWNER/REPO/releases/latest/download/appcast.xml" \
   ./build.sh release
   ```
   Until a real public key is set the updater stays dormant (no crashes, the menu item is hidden).

## CI (GitHub Actions)

`.github/workflows/release.yml` builds, signs, notarizes, packages, signs the Sparkle update, and publishes a GitHub Release (DMG + `appcast.xml`) on every push to `main` (version `0.1.<run number>`). It needs these repository secrets:

| Secret | What |
|--------|------|
| `BUILD_CERTIFICATE_BASE64` / `P12_PASSWORD` | base64 of your Developer ID `.p12` and its password |
| `KEYCHAIN_PASSWORD` | throwaway password for the CI keychain |
| `DEVELOPER_ID_NAME` | `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_SPECIFIC_PASSWORD` | notarization credentials |
| `SPARKLE_PUBLIC_KEY` / `SPARKLE_PRIVATE_KEY` | Sparkle update-signing keys |

## Skills (custom review instructions)

Skills are plain markdown files in:

```
~/Library/Application Support/PRAgent/skills/
```

A `default-review.md` is seeded on first launch. Add more `.md` files — their contents are appended to the agent's system prompt for every review. Optional frontmatter:

```markdown
---
name: security-focus
description: Extra scrutiny on auth and input handling
enabled: true
---

Pay special attention to authorization checks and untrusted input...
```

Set `enabled: false` to turn one off. Hit **Reload skills** in Settings after editing.

## Architecture

Everything is native Swift in `macos/Sources/PRAgent/`:

| File | Role |
|------|------|
| `PRAgentApp.swift` | `@main` app, `MenuBarExtra`, accessory activation, notification delegate |
| `AppModel.swift` | Observable state, polling loop, review/submit actions, notification logic |
| `GitHubClient.swift` | GitHub GraphQL (review requests + my PRs) and REST (diff, submit review) |
| `ReviewAgent.swift` | Anthropic Messages API with tool-use → structured `ReviewDraft` |
| `Skills.swift` | Loads/seeds markdown skill files |
| `Keychain.swift` | Token storage via the Security framework |
| `Notifier.swift` | `UNUserNotificationCenter` wrapper |
| `Models.swift` | Data types + menu-bar state derivation |
| `Views/` | SwiftUI: status icon, My PRs, Review queue, Settings |

Default agent model: `claude-opus-4-8` (changeable in Settings). Polling is used instead of webhooks because the app runs locally with no public endpoint.
