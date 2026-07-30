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

echo "→ Opening ${DST}"
open "${DST}"

cat <<EOF

Installed: ${DST}
Bundle ID: ${BUNDLE_ID}

Next:
  1. Menu bar → Settings… → enable “Open at login” (from this copy).
  2. Keep using Grok Build with \`grok login\` as usual.

Developer ID + notarization (optional, for sharing outside your Mac):
  Create a “Developer ID Application” certificate in developer.apple.com,
  then sign with that identity and run \`xcrun notarytool\`.
EOF
