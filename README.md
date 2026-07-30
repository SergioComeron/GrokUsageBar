# GrokUsageBar

Menubar utility for macOS that shows **Grok Build credit usage %** — the same idea as the in-app `/usage` (alias `/cost`) command.

```
Barra:  [logo] 0.7%
Clic:   detalle del periodo · Refresh · Billing… · Settings… · Quit
```

## Requirements

- macOS 14+ (built against Xcode 27 / macOS 27 SDK)
- [Grok Build](https://grok.com) session via `grok login` → `~/.grok/auth.json`
- Xcode (this machine has `/Applications/Xcode-beta.app`)

## Install (recommended, daily use)

Signed **Release** build → `/Applications`, then open:

```bash
cd /Users/sergiocomeron/projects/GrokUsageBar
./install.sh
```

Then in the menu panel → **Settings…** → enable **Open at login**.

Requires Xcode and your Apple Development certificate. The project uses
team `6PUHQ5CYQS` (override with `DEVELOPMENT_TEAM=… ./install.sh` if needed).

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
| Run on **your** Mac | **Apple Development** (you already have this) + `./install.sh` |
| Share .app with others / fewer Gatekeeper prompts | **Developer ID Application** cert + **notarization** (`notarytool`) |
| Mac App Store | **Apple Distribution** + App Store Connect (different pipeline) |

You currently have Development identities installed. For Developer ID:

1. [developer.apple.com](https://developer.apple.com/account/resources/certificates/list) → Certificates → **Developer ID Application**
2. Install the cert in Keychain
3. Archive/sign Release with that identity and submit with `xcrun notarytool`

## Data source (same as `/usage`)

```http
GET https://cli-chat-proxy.grok.com/v1/billing
Authorization: Bearer <token from ~/.grok/auth.json>
```

Example response (fields abbreviated):

```json
{
  "config": {
    "monthlyLimit": { "val": 15000 },
    "used": { "val": 103 },
    "onDemandCap": { "val": 0 },
    "billingPeriodStart": "2026-07-01T00:00:00+00:00",
    "billingPeriodEnd": "2026-08-01T00:00:00+00:00",
    "history": [ … ]
  }
}
```

Displayed percent = `used.val / monthlyLimit.val * 100`.

## What’s implemented

| Piece | Status |
|---|---|
| `MenuBarExtra` label + panel | Done |
| Read `~/.grok/auth.json` | Done |
| Live billing API | Done |
| Mock fallback (`GROK_USAGE_MOCK=1`) | Done |
| OIDC token refresh (writes back to auth.json) | Done |
| Grok logo in menubar | Done |
| Finer percent under 10% | Done |
| Notifications at 80/100 % | Done |
| Open at login (`SMAppService`) | Done |
| History sparkline | Done |

## Layout

```
GrokUsageBar/
├── GrokUsageBar.xcodeproj
├── README.md
└── GrokUsageBar/
    ├── GrokUsageBarApp.swift      # MenuBarExtra + Settings
    ├── Models/BillingUsage.swift
    ├── Services/
    │   ├── GrokAuthStore.swift    # ~/.grok/auth.json
    │   ├── BillingService.swift   # Mock + Live
    │   ├── UsageStore.swift       # poll + state
    │   ├── UsageNotifier.swift
    │   └── LaunchAtLogin.swift
    ├── Views/
    │   ├── MenuBarLabel.swift
    │   ├── MenuBarPanel.swift
    │   └── SettingsView.swift
    ├── Assets.xcassets
    └── GrokUsageBar.entitlements  # sandbox OFF (reads home auth file)
```

## Auth refresh

When the access token expires within 5 minutes (or the billing API returns 401),
the app POSTs to `{oidc_issuer}/oauth2/token` with `grant_type=refresh_token`
and updates `key`, `refresh_token` and `expires_at` in `~/.grok/auth.json`
(mode `0600`). Grok Build and this app then share the renewed session.

## Notifications

When enabled (default), crossing **80%** or **100%** posts a local notification
once per billing period. Toggle in Settings. macOS may ask for notification
permission on first launch.

## Open at login

Settings → **Open at login** registers the app with `SMAppService.mainApp`.
macOS may list it under *System Settings → General → Login Items*. Use the
built `.app` (e.g. under `build/Build/Products/Debug/`) so the login item
points at a real bundle path.

## History sparkline

The panel shows a compact bar chart of past billing cycles plus the current
period (from the API `history` array and live `used` value). Hover a bar for
the month total.

## Privacy

- Reads only your local Grok session file.
- Does not send tokens anywhere except the billing host you configure.
- No analytics.

## Licence

Personal utility — Copyright © 2026 Sergio Comerón.
