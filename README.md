# GrokUsageBar

Menubar app for macOS that shows your **Grok Build weekly usage %** — the same figure as `/usage` in Grok Build.

```
Bar:   [logo] 46% wk
Click: plan · weekly limit · 7-day window · products · monthly credits
```

## Requirements

- macOS 14+
- A Grok account

You do **not** need Grok Build installed or running. Sign in from the menu bar.

## Install

1. Download the latest `GrokUsageBar-*-macos.zip` from [Releases](https://github.com/SergioComeron/GrokUsageBar/releases/latest).
2. Unzip and move `GrokUsageBar.app` to **Applications**.
3. Open it (releases are Developer ID + notarized).
4. If there is no session, click **Sign in with Grok** and finish in the browser.

In the panel → **Settings…** you can turn on **Open at login**, alerts at 80% / 100%, and **Sign out**.

`grok login` still works if you already use Grok Build; both apps share the same local session.

## What you see

- Weekly limit (rolling 7 days from your account, not Monday–Sunday)
- Plan name when the session has it
- Breakdown by product (Build, Chat, …)
- Monthly credit units, when the API still sends them
- A small history sparkline

The app lives in the menu bar only — no Dock icon.

## Privacy

- Sign-in and usage go to xAI (the same hosts Grok Build uses).
- The session is stored only on this Mac (`~/.grok/auth.json`, owner-only).
- No analytics.

## Build from source

```bash
open GrokUsageBar.xcodeproj
```

Run the **GrokUsageBar** scheme. To install a local Release build into `/Applications`:

```bash
./install.sh
```

Needs Xcode and a signing identity on this Mac.

## Licence

Personal utility — Copyright © 2026 Sergio Comerón.
