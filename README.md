# GrokUsageBar

Menubar utility for macOS that shows **Grok Build weekly usage %** — the same number as the in-app `/usage` (alias `/cost`) **Weekly limit**.

```
Barra:  [logo] 46% wk
Clic:   plan · weekly limit · ventana 7 días · productos · créditos mensuales
```

## Requirements

- macOS 14+ (built against Xcode 27 / macOS 27 SDK)
- [Grok Build](https://grok.com) session via `grok login` → `~/.grok/auth.json`
- Xcode (this machine has `/Applications/Xcode-beta.app`)

## Install (recommended, daily use)

Signed **Release** build → `/Applications`, then open:

```bash
cd /path/to/GrokUsageBar
./install.sh
```

Then in the menu panel → **Settings…** → enable **Open at login**.

Requires Xcode and your Apple Development certificate. The project uses
team `6PUHQ5CYQS` (override with `DEVELOPMENT_TEAM=… ./install.sh` if needed).

### Releases on GitHub

Tagged builds are published under [Releases](https://github.com/SergioComeron/GrokUsageBar/releases).

From a clean tree with the version already bumped in Xcode:

```bash
./scripts/release.sh          # builds, tags vX.Y.Z, uploads .zip via gh
./scripts/release.sh --dry-run
```

The script reads `MARKETING_VERSION` from the Xcode project (currently **0.2.0**).

> **Note:** Builds are signed with **Apple Development**. On another Mac you may
> need right-click → Open the first time, or a **Developer ID** + notarization
> for smoother Gatekeeper.

## Develop

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
open GrokUsageBar.xcodeproj
```

Run the **GrokUsageBar** scheme (⌘R). The app is an **agent** (`LSUIElement`):
no Dock icon, only the menu bar.

### Signing & distribution

| Goal | What you need |
|---|---|
| Run on **your** Mac | **Apple Development** + `./install.sh` |
| Share .app with others / fewer Gatekeeper prompts | **Developer ID Application** + **notarization** |
| Mac App Store | **Apple Distribution** + App Store Connect |

## Data source (same as `/usage`)

**Primary (weekly limit — what gates usage):**

```http
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <token from ~/.grok/auth.json>
```

```json
{
  "config": {
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "…",
      "end": "…"
    },
    "creditUsagePercent": 46.0,
    "productUsage": [
      { "product": "GrokBuild", "usagePercent": 41.0 }
    ]
  }
}
```

Displayed **weekly** percent = `creditUsagePercent`. The window is a **rolling 7 days** from your account, not Mon–Sun.

**Secondary (monthly credit units):**

```http
GET https://cli-chat-proxy.grok.com/v1/billing
```

**Plan name (SuperGrok / Heavy / …):** best-effort from the OAuth JWT claim `tier`
(and optional billing fields if the API starts sending them).

## What’s implemented

| Piece | Status |
|---|---|
| `MenuBarExtra` label + panel | Done |
| Weekly limit (`?format=credits`) | Done |
| Period range + “resets in N days” | Done |
| Product breakdown (Build / Chat / …) | Done |
| Monthly units (secondary) | Done |
| Subscription plan badge (JWT `tier`) | Done |
| Read `~/.grok/auth.json` + OIDC refresh | Done |
| Notifications at 80/100 % | Done |
| Open at login (`SMAppService`) | Done |
| History sparkline (monthly) | Done |
| GitHub releases (`scripts/release.sh`) | Done |

## Layout

```
GrokUsageBar/
├── GrokUsageBar.xcodeproj
├── install.sh
├── scripts/release.sh
├── README.md
└── GrokUsageBar/
    ├── GrokUsageBarApp.swift
    ├── Models/BillingUsage.swift
    ├── Services/
    │   ├── GrokAuthStore.swift
    │   ├── BillingService.swift
    │   ├── UsageStore.swift
    │   ├── UsageNotifier.swift
    │   └── LaunchAtLogin.swift
    ├── Views/
    │   ├── MenuBarLabel.swift
    │   ├── MenuBarPanel.swift
    │   └── SettingsView.swift
    ├── Assets.xcassets
    └── GrokUsageBar.entitlements
```

## Auth refresh

When the access token expires within 5 minutes (or the billing API returns 401),
the app POSTs to `{oidc_issuer}/oauth2/token` with `grant_type=refresh_token`
and updates `key`, `refresh_token` and `expires_at` in `~/.grok/auth.json`
(mode `0600`). Grok Build and this app then share the renewed session.

## Notifications

When enabled (default), crossing **80%** or **100%** of the **weekly** limit
posts a local notification once per period. Toggle in Settings.

## Privacy

- Reads only your local Grok session file.
- Does not send tokens anywhere except the billing host you configure.
- No analytics.

## Licence

Personal utility — Copyright © 2026 Sergio Comerón.
