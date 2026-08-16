#!/usr/bin/env bash
# Build Release, Developer ID + notarize, tag vX.Y.Z, GitHub release.
#
# Usage:
#   ./scripts/release.sh                 # full release (always notarized)
#   ./scripts/release.sh --dry-run       # notarized zip only, no tag/push/gh
#   ./scripts/release.sh --skip-build    # reuse existing Release .app, then notarize
#   ./scripts/release.sh --skip-notarize # emergency: zip without Apple notary
#
# Requires: Developer ID in Keychain, notarytool profile GrokUsageBar-notary,
# xcodebuild, gh (except dry-run), clean git tree (except dry-run).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GrokUsageBar"
BUNDLE_ID="com.sergiocomeron.GrokUsageBar"
DERIVED="${ROOT}/build"
TEAM_ID="${DEVELOPMENT_TEAM:-6PUHQ5CYQS}"
DRY_RUN=0
SKIP_BUILD=0
SKIP_NOTARIZE=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
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

# MARKETING_VERSION from pbxproj (first match).
VERSION="$(
  grep -m1 'MARKETING_VERSION' "${ROOT}/${APP_NAME}.xcodeproj/project.pbxproj" \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/' \
    | tr -d ' '
)"
if [[ -z "${VERSION}" ]]; then
  echo "error: could not read MARKETING_VERSION from project.pbxproj" >&2
  exit 1
fi
TAG="v${VERSION}"
SRC="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
DIST="${ROOT}/dist"
ZIP_NOTARIZED="${DIST}/${APP_NAME}-${VERSION}-macos-notarized.zip"
ZIP_PLAIN="${DIST}/${APP_NAME}-${VERSION}-macos.zip"

echo "→ Version ${VERSION}  tag ${TAG}"

if [[ "${DRY_RUN}" -eq 0 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI required (brew install gh && gh auth login)" >&2
    exit 1
  fi
  if [[ -n "$(git -C "${ROOT}" status --porcelain)" ]]; then
    echo "error: working tree not clean. Commit first." >&2
    git -C "${ROOT}" status -sb
    exit 1
  fi
  if git -C "${ROOT}" rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "error: tag ${TAG} already exists" >&2
    exit 1
  fi
fi

mkdir -p "${DIST}"

if [[ "${SKIP_NOTARIZE}" -eq 0 ]]; then
  echo "→ Notarizing (Developer ID + notarytool)…"
  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    "${ROOT}/scripts/notarize.sh" --skip-build
  else
    "${ROOT}/scripts/notarize.sh"
  fi
  ZIP="${ZIP_NOTARIZED}"
  SIGNING_LINE="Developer ID Application + notarized (team ${TEAM_ID})"
  INSTALL_GATEKEEPER="Open the app (Gatekeeper should accept it as notarized)."
else
  echo "warning: --skip-notarize set; zip will NOT be accepted by Gatekeeper on other Macs" >&2
  if [[ "${SKIP_BUILD}" -eq 0 ]]; then
    echo "→ Building Release (unsigned-for-distribution)…"
    xcodebuild \
      -project "${ROOT}/${APP_NAME}.xcodeproj" \
      -scheme "${APP_NAME}" \
      -configuration Release \
      -derivedDataPath "${DERIVED}" \
      -destination 'platform=macOS' \
      DEVELOPMENT_TEAM="${TEAM_ID}" \
      CODE_SIGN_STYLE=Automatic \
      build
  else
    echo "→ Skipping build (using existing ${SRC})"
  fi
  if [[ ! -d "${SRC}" ]]; then
    echo "error: missing ${SRC}" >&2
    exit 1
  fi
  rm -f "${ZIP_PLAIN}"
  ditto -c -k --sequesterRsrc --keepParent "${SRC}" "${ZIP_PLAIN}"
  ZIP="${ZIP_PLAIN}"
  SIGNING_LINE="Apple Development only (team ${TEAM_ID}) — not notarized"
  INSTALL_GATEKEEPER="Right-click → Open the first time (this build is not notarized)."
fi

if [[ ! -f "${ZIP}" ]]; then
  echo "error: missing zip ${ZIP}" >&2
  exit 1
fi

NOTES="${DIST}/release-notes-${VERSION}.md"
cat > "${NOTES}" <<EOF
## GrokUsageBar ${VERSION}

Menubar usage for Grok Build — same weekly limit as \`/usage\`.

### Highlights
- **Weekly limit** from \`GET /v1/billing?format=credits\` (\`creditUsagePercent\`)
- Rolling **7-day window** with range + “resets in N days”
- **Plan** badge (SuperGrok / Heavy / … via JWT \`tier\`)
- Product breakdown (Build, Chat, Imagine, …)
- Monthly credit units as secondary info

### Install
1. Download \`$(basename "${ZIP}")\`
2. Unzip → move \`${APP_NAME}.app\` to **Applications**
3. ${INSTALL_GATEKEEPER}
4. Ensure you are logged in with \`grok login\`

### Build
- Bundle ID: \`${BUNDLE_ID}\`
- ${SIGNING_LINE}
EOF

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "→ Dry run complete."
  echo "  App:  ${SRC}"
  echo "  Zip:  ${ZIP}"
  echo "  Notes:${NOTES}"
  exit 0
fi

echo "→ Tagging ${TAG}"
git -C "${ROOT}" tag -a "${TAG}" -m "Release ${TAG}"
git -C "${ROOT}" push origin HEAD
git -C "${ROOT}" push origin "${TAG}"

echo "→ Creating GitHub release ${TAG}"
gh release create "${TAG}" \
  --title "GrokUsageBar ${VERSION}" \
  --notes-file "${NOTES}" \
  "${ZIP}"

echo ""
echo "Published: https://github.com/SergioComeron/GrokUsageBar/releases/tag/${TAG}"
