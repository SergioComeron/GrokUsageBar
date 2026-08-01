#!/usr/bin/env bash
# Build Release, tag vX.Y.Z from MARKETING_VERSION, and create a GitHub release
# with a zip of GrokUsageBar.app.
#
# Usage:
#   ./scripts/release.sh              # full release
#   ./scripts/release.sh --dry-run    # build + zip only, no tag/push/gh
#   ./scripts/release.sh --skip-build # reuse existing Release .app
#
# Requires: xcodebuild (Xcode), gh (authenticated), clean git tree (except dry-run).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GrokUsageBar"
BUNDLE_ID="com.sergiocomeron.GrokUsageBar"
DERIVED="${ROOT}/build"
TEAM_ID="${DEVELOPMENT_TEAM:-6PUHQ5CYQS}"
DRY_RUN=0
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
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
ZIP="${DIST}/${APP_NAME}-${VERSION}-macos.zip"

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

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  echo "→ Building Release…"
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

mkdir -p "${DIST}"
rm -f "${ZIP}"
echo "→ Zipping ${ZIP}"
# ditto preserves code signature better than zip -r for macOS apps.
ditto -c -k --sequesterRsrc --keepParent "${SRC}" "${ZIP}"

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
1. Download \`${APP_NAME}-${VERSION}-macos.zip\`
2. Unzip → move \`${APP_NAME}.app\` to **Applications**
3. Open once (right-click → Open if Gatekeeper blocks Development-signed builds)
4. Ensure you are logged in with \`grok login\`

### Build
- Bundle ID: \`${BUNDLE_ID}\`
- Signed with Apple Development (team \`${TEAM_ID}\`)
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
