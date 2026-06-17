# 🐤 Peck

**Your PRs, from 🥚 to 🍗 — reviewed by an AI that pecks through the diff.**

Peck is a lightweight macOS **menu-bar** app that watches your GitHub pull requests and reviews them with an AI agent. Native SwiftUI — no Electron, no server, no account. Just a chick living in your menu bar.

<p align="center">
  <img src="docs/my-prs.png" width="380" alt="My PRs — gamified review quest (egg → chick → chicken → 🍗)">
  &nbsp;
  <img src="docs/reviews.png" width="380" alt="Review queue — the agent drafts an explanation and a verdict">
</p>
<p align="center"><sub>Left: your PRs hatching toward approval. Right: agent-drafted reviews, one click to post.</sub></p>

---

## Why Peck

🔍 **An agent reviews for you.** The moment someone requests your review, Peck reads the PR and drafts a plain-language **explanation** plus a recommended verdict — **Approve**, **Request changes**, or **Comment** — with a ready-to-post body. You confirm with one click.

🔑 **No API key required.** Peck runs the review through your existing **`claude`** (Claude Code) or **`codex`** (ChatGPT) CLI login. Prefer an Anthropic key? That works too.

🥚→🐔 **Your PRs, gamified.** Every PR you open is a quest: it hatches **🥚 → 🐣 → 🐔 → 🍗** as approvals roll in. Approved but blocked by a merge conflict? It gets flagged in orange so nothing silently stalls.

📊 **One glance, two numbers.** The menu bar shows how many of your PRs **need action** and how many are **waiting on your review** — no tab-switching.

🔔 **Notified at the right moment** — a new review request, a conflict on an approved PR, or "everything's approved 🎉".

🧩 **Your rules, not a black box.** Teach the agent how *you* review by dropping in markdown **skill** files — enforce team conventions, demand tests, focus on security, ban an anti-pattern, set the tone. Peck folds every enabled skill straight into the agent's instructions, so reviews match *your* standards instead of generic feedback. Add or edit them anytime in `~/Library/Application Support/PRAgent/skills/` — no rebuild needed.

🔒 **Native & private.** A tiny SwiftUI app (no Electron), with your tokens kept in the macOS **Keychain** — never in a file. UI in **English or 한국어**.

---

## Quick start

1. **[Download the latest release](https://github.com/pecklabs/peck/releases/latest)** and open `Peck.dmg`.
2. Drag **Peck** to your Applications folder and launch it.
3. Click the 🐤 in your menu bar → **Settings** → connect GitHub (reuse your `gh` login) → pick an agent backend. Done.

**Requirements:** macOS 14+ · for the agent: the `claude` or `codex` CLI (or an Anthropic API key) · for GitHub: the `gh` CLI logged in (or a personal access token).

<details>
<summary>Build from source</summary>

```bash
cd macos
./build.sh
open "build/Peck.app"
```
</details>

---

## Auto-updating

Peck ships as a notarized DMG with built-in [Sparkle](https://sparkle-project.org) auto-update — install once, stay current. Build/sign/notarize lives in `macos/release.sh`.

## License

Source code is **MIT**. The mascot artwork is **not** — see [NOTICE](NOTICE).
