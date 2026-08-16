# GrokUsageBar

Menubar utility for macOS that shows **Grok Build weekly usage %** — the same number as the in-app `/usage` (alias `/cost`) **Weekly limit**.

```
Barra:  [logo] 46% wk
Clic:   plan · weekly limit · ventana 7 días · productos · créditos mensuales
```

## Requirements

- macOS 14+
- A Grok account. Sign in from the menu bar (**Sign in with Grok**) or with `grok login`. The TUI does **not** need to be installed or left open.

## Install (anyone)

1. Download **`GrokUsageBar-*-macos.zip`** from [Releases](https://github.com/SergioComeron/GrokUsageBar/releases/latest).
2. Unzip and move `GrokUsageBar.app` to **Applications**.
3. Open it. Releases from **0.2.2** are **Developer ID + notarized**; Gatekeeper should accept a double-click.
4. If the bar says there is no session, click **Sign in with Grok** and finish in the browser. (`grok login` still works if you prefer.)

Then in the menu panel → **Settings…** → enable **Open at login** if you want it at boot.

## Build from source (this Mac)

Signed **Release** build → `/Applications`:

```bash
cd /path/to/GrokUsageBar
./install.sh
```

Requires Xcode and your Apple Development certificate. Team `6PUHQ5CYQS`
(override with `DEVELOPMENT_TEAM=… ./install.sh` if needed).

`./install.sh` always pins **Open at login** to `/Applications/GrokUsageBar.app`,
even if you toggled the switch from an Xcode Debug build.

### Cut a GitHub release

From a clean tree with `MARKETING_VERSION` already bumped in Xcode (currently **0.2.3**):

```bash
./scripts/release.sh          # build + Developer ID + notarize + tag + GitHub zip
./scripts/release.sh --dry-run
```

Every zip from `release.sh` is notarized unless you pass `--skip-notarize`.

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

To hand the zip to someone else (no “unidentified developer” block):

```bash
./scripts/setup-signing.sh          # checks cert + notary profile
./scripts/setup-signing.sh csr      # one-time: upload CSR at developer.apple.com
./scripts/setup-signing.sh import ~/Downloads/developerID_application.cer
./scripts/setup-signing.sh notary   # one-time: app-specific password
./scripts/notarize.sh               # signed + notarized zip in dist/
```

Use team **6PUHQ5CYQS** (Sergio Comeron Sanchez-Paniagua), not the free Personal Team and not UDIMA. The private key stays in `certs/` (gitignored).

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
| In-app Grok sign-in (device code) | Done |
| Read `~/.grok/auth.json` + OIDC refresh | Done |
| Notifications at 80/100 % | Done |
| Open at login (`/Applications` LaunchAgent, never Debug) | Done |
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
    │   ├── GrokDeviceLogin.swift
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
