#!/usr/bin/env bash
# Sign with Developer ID, notarize with notarytool, staple, and zip for distribution.
#
# Prerequisites (one-time):
#   1. Apple Developer Program membership
#   2. Certificate "Developer ID Application" installed in Keychain
#      (developer.apple.com → Certificates → + → Developer ID Application)
#   3. App-specific password OR App Store Connect API key, then:
#        xcrun notarytool store-credentials "GrokUsageBar-notary" \
#          --apple-id "you@icloud.com" \
#          --team-id "6PUHQ5CYQS" \
#          --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password
#      (or use --key / --key-id / --issuer for API key)
#
# Usage:
#   ./scripts/notarize.sh                 # build + notarize + zip
#   ./scripts/notarize.sh --skip-build    # reuse existing Release .app
#   NOTARY_PROFILE=MyProfile ./scripts/notarize.sh
#
# Env:
#   DEVELOPMENT_TEAM   default 6PUHQ5CYQS
#   NOTARY_PROFILE     keychain profile name (default GrokUsageBar-notary)
#   DEVELOPER_ID_IDENTITY  optional full codesign identity string
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GrokUsageBar"
BUNDLE_ID="com.sergiocomeron.GrokUsageBar"
DERIVED="${ROOT}/build"
DIST="${ROOT}/dist"
TEAM_ID="${DEVELOPMENT_TEAM:-6PUHQ5CYQS}"
NOTARY_PROFILE="${NOTARY_PROFILE:-GrokUsageBar-notary}"
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
elif [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

VERSION="$(
  grep -m1 'MARKETING_VERSION' "${ROOT}/${APP_NAME}.xcodeproj/project.pbxproj" \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/' \
    | tr -d ' '
)"
APP="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
ZIP_SUBMIT="${DIST}/${APP_NAME}-${VERSION}-submit.zip"
ZIP_DIST="${DIST}/${APP_NAME}-${VERSION}-macos-notarized.zip"

# ── 1. Find Developer ID identity ──────────────────────────────────────────
if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
  IDENTITY="${DEVELOPER_ID_IDENTITY}"
else
  IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | grep "Developer ID Application" \
      | head -1 \
      | sed -E 's/.*"([^"]+)".*/\1/' || true
  )"
fi

if [[ -z "${IDENTITY}" ]]; then
  cat <<EOF >&2
error: no "Developer ID Application" identity in Keychain.

Apple Development certs only work on this Mac. Sharing needs Developer ID + notarization.

One-time setup:
  ./scripts/setup-signing.sh          # what is missing
  ./scripts/setup-signing.sh csr      # or create the cert in Xcode → Manage Certificates
  ./scripts/setup-signing.sh import ~/Downloads/developerID_application.cer
  ./scripts/setup-signing.sh notary

Then re-run:  ./scripts/notarize.sh
EOF
  exit 1
fi

echo "→ Identity: ${IDENTITY}"
echo "→ Team:     ${TEAM_ID}"
echo "→ Version:  ${VERSION}"

# ── 2. Build (optional) ────────────────────────────────────────────────────
if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  echo "→ Building Release…"
  # Manual Developer ID style: still use Automatic + team if Xcode can pick the cert,
  # then re-sign explicitly below for a clean Developer ID + timestamp signature.
  xcodebuild \
    -project "${ROOT}/${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED}" \
    -destination 'platform=macOS' \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    build || {
      echo "note: xcodebuild with Developer ID failed; building with Automatic then re-signing…"
      xcodebuild \
        -project "${ROOT}/${APP_NAME}.xcodeproj" \
        -scheme "${APP_NAME}" \
        -configuration Release \
        -derivedDataPath "${DERIVED}" \
        -destination 'platform=macOS' \
        DEVELOPMENT_TEAM="${TEAM_ID}" \
        CODE_SIGN_STYLE=Automatic \
        build
    }
fi

if [[ ! -d "${APP}" ]]; then
  echo "error: missing ${APP}" >&2
  exit 1
fi

# ── 3. Re-sign with Developer ID + hardened runtime + secure timestamp ─────
echo "→ codesign (Developer ID, hardened runtime, timestamp)…"
# Deep sign all nested code first, then the bundle.
codesign --force --deep --options runtime --timestamp \
  --sign "${IDENTITY}" \
  --identifier "${BUNDLE_ID}" \
  "${APP}"

codesign --verify --deep --strict --verbose=2 "${APP}"
echo "→ Signature:"
codesign -dv --verbose=2 "${APP}" 2>&1 | grep -E 'Authority|TeamIdentifier|flags|Identifier' || true

# ── 4. Zip for submission (must preserve signature) ───────────────────────
mkdir -p "${DIST}"
rm -f "${ZIP_SUBMIT}" "${ZIP_DIST}"
echo "→ Zip for notary: ${ZIP_SUBMIT}"
ditto -c -k --keepParent "${APP}" "${ZIP_SUBMIT}"

# ── 5. Submit to Apple ────────────────────────────────────────────────────
echo "→ notarytool submit (profile: ${NOTARY_PROFILE})…"
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  cat <<EOF >&2
error: notarytool profile "${NOTARY_PROFILE}" not found.

Create it once (app-specific password from appleid.apple.com → Sign-In and Security):

  xcrun notarytool store-credentials "${NOTARY_PROFILE}" \\
    --apple-id "YOUR_APPLE_ID@email.com" \\
    --team-id "${TEAM_ID}" \\
    --password "xxxx-xxxx-xxxx-xxxx"

Or with App Store Connect API key:
  xcrun notarytool store-credentials "${NOTARY_PROFILE}" \\
    --key ~/AuthKey_XXXXXXXXXX.p8 \\
    --key-id XXXXXXXXXX \\
    --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
EOF
  exit 1
fi

xcrun notarytool submit "${ZIP_SUBMIT}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

# ── 6. Staple ticket onto the .app ────────────────────────────────────────
echo "→ stapler staple…"
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

# Gatekeeper assessment (should say accepted / notarized)
echo "→ spctl assessment:"
spctl --assess --type execute --verbose=4 "${APP}" 2>&1 || true

# ── 7. Distribution zip ───────────────────────────────────────────────────
echo "→ Dist zip: ${ZIP_DIST}"
ditto -c -k --keepParent "${APP}" "${ZIP_DIST}"

cat <<EOF

Notarization complete.

  App:  ${APP}
  Zip:  ${ZIP_DIST}

Install locally:
  cp -R "${APP}" /Applications/

Attach to GitHub release:
  gh release upload v${VERSION} "${ZIP_DIST}" --clobber

Or create a new release with:
  # after bumping MARKETING_VERSION and committing
  ./scripts/release.sh --skip-build   # only if release.sh points at notarized app
EOF
