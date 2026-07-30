# GrokUsageBar

Menubar utility for macOS that shows **Grok Build credit usage %** — the same idea as the in-app `/usage` (alias `/cost`) command.

```
Barra:  ⚡ 37%
Clic:   detalle del periodo · Refresh · Billing… · Quit
```

## Requirements

- macOS 14+ (built against Xcode 27 / macOS 27 SDK)
- [Grok Build](https://grok.com) session via `grok login` → `~/.grok/auth.json`
- Xcode (this machine has `/Applications/Xcode-beta.app`)

## Open & run

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
open /Users/sergiocomeron/projects/GrokUsageBar/GrokUsageBar.xcodeproj
```

In Xcode: select the **GrokUsageBar** scheme → **Run** (⌘R).

Or from the terminal:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd /Users/sergiocomeron/projects/GrokUsageBar
xcodebuild -scheme GrokUsageBar -configuration Debug build
# then open the .app under DerivedData, or:
xcodebuild -scheme GrokUsageBar -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/GrokUsageBar.app
```

The app is an **agent** (`LSUIElement`): no Dock icon, only the menu bar.

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
| Token refresh like the CLI | Not yet (re-login when expired) |
| Notifications at 80/100 % | Not yet |
| Grok logo in menubar | Not yet |

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
    │   ├── BillingService.swift   # Mock + Live stub
    │   └── UsageStore.swift       # poll + state
    ├── Views/
    │   ├── MenuBarLabel.swift
    │   ├── MenuBarPanel.swift
    │   └── SettingsView.swift
    ├── Assets.xcassets
    └── GrokUsageBar.entitlements  # sandbox OFF (reads home auth file)
```

## Next steps

1. Capture Grok Build’s `/usage` billing request (host, path, body, response JSON).
2. Point `LiveBillingService` at it and map `creditUsagePercent`.
3. Implement OIDC refresh using `refresh_token` + `oidc_issuer` / `oidc_client_id`.
4. Optional: Launch at login, colour thresholds, sparkline.

## Privacy

- Reads only your local Grok session file.
- Does not send tokens anywhere except the billing host you configure.
- No analytics.

## Licence

Personal utility — Copyright © 2026 Sergio Comerón.
