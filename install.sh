#!/usr/bin/env bash
# Build a signed Release build and install to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="GrokUsageBar"
BUNDLE_ID="com.sergiocomeron.GrokUsageBar"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DERIVED="${ROOT}/build"
# Override if you need the other team: DEVELOPMENT_TEAM=A68GM9LK49 ./install.sh
TEAM_ID="${DEVELOPMENT_TEAM:-6PUHQ5CYQS}"

if [[ -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
elif [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

echo "→ Building Release (team ${TEAM_ID})…"
xcodebuild \
  -project "${ROOT}/${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED}" \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_STYLE=Automatic \
  build

SRC="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
DST="${INSTALL_DIR}/${APP_NAME}.app"

if [[ ! -d "${SRC}" ]]; then
  echo "error: build product missing: ${SRC}" >&2
  exit 1
fi

echo "→ Codesign identity:"
codesign -dv --verbose=2 "${SRC}" 2>&1 | grep -E 'Authority|Identifier|TeamIdentifier|Signature' || true

# Quit running instance so we can replace the bundle.
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "→ Quitting running ${APP_NAME}…"
  pkill -x "${APP_NAME}" || true
  sleep 0.4
fi

echo "→ Installing to ${DST}"
rm -rf "${DST}"
cp -R "${SRC}" "${DST}"

# Ad-hoc re-register with Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${DST}" >/dev/null 2>&1 || true

# Login must always start /Applications, never a Debug/Xcode product.
# The app also reconciles this on launch; do it here so a failed open still pins login.
AGENT_LABEL="com.sergiocomeron.GrokUsageBar.login"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
UID_NUM="$(id -u)"
had_login=0
if [[ -f "${AGENT_PLIST}" ]]; then
  had_login=1
fi
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q 'GrokUsageBar'; then
  had_login=1
fi

osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application "System Events"
  set doomed to {}
  repeat with li in (get login items)
    if name of li is "GrokUsageBar" then set end of doomed to li
  end repeat
  repeat with li in doomed
    delete li
  end repeat
end tell
APPLESCRIPT

if [[ "${had_login}" -eq 1 ]]; then
  echo "→ Pinning Open at login to ${DST}"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "${AGENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>${DST}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/${UID_NUM}/${AGENT_LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${UID_NUM}" "${AGENT_PLIST}" >/dev/null 2>&1 || true
fi

echo "→ Opening ${DST}"
open "${DST}"

cat <<EOF

Installed: ${DST}
Bundle ID: ${BUNDLE_ID}

Open at login always starts ${DST} (not an Xcode Debug build).
If it was already enabled, it has been re-pinned to this copy.

Next:
  1. Menu bar → Settings… → enable “Open at login” if you want it.
  2. Keep using Grok Build with \`grok login\` as usual.

Developer ID + notarization (optional, for sharing outside your Mac):
  Create a “Developer ID Application” certificate in developer.apple.com,
  then sign with that identity and run \`xcrun notarytool\`.
EOF
