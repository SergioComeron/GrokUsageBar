#!/usr/bin/env bash
# One-time Developer ID + notarytool setup so GrokUsageBar can be shared.
#
#   ./scripts/setup-signing.sh          # status + next step
#   ./scripts/setup-signing.sh csr      # generate CSR for the Apple portal
#   ./scripts/setup-signing.sh import ~/Downloads/developerID_application.cer
#   ./scripts/setup-signing.sh notary   # store notarytool profile (prompts)
#   ./scripts/setup-signing.sh check
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERTS="${ROOT}/certs"
TEAM_ID="${DEVELOPMENT_TEAM:-6PUHQ5CYQS}"
NOTARY_PROFILE="${NOTARY_PROFILE:-GrokUsageBar-notary}"
APPLE_ID="${APPLE_ID:-sergiocomeron@icloud.com}"
CN="${CERT_CN:-Sergio Comeron Sanchez-Paniagua}"
KEY="${CERTS}/DeveloperID.key"
CSR="${CERTS}/DeveloperID.certSigningRequest"

have_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -q "Developer ID Application"
}

print_identities() {
  security find-identity -v -p codesigning 2>/dev/null || true
}

cmd="${1:-status}"

case "${cmd}" in
  csr)
    mkdir -p "${CERTS}"
    chmod 700 "${CERTS}"
    if [[ -f "${KEY}" && -f "${CSR}" ]]; then
      echo "CSR already exists: ${CSR}"
    else
      echo "→ Generating 2048-bit CSR for ${CN} <${APPLE_ID}>…"
      openssl req -new -newkey rsa:2048 -nodes \
        -keyout "${KEY}" \
        -out "${CSR}" \
        -subj "/emailAddress=${APPLE_ID}/CN=${CN}/C=ES"
      chmod 600 "${KEY}" "${CSR}"
    fi
    echo
    echo "Next (in the browser that just opened, or https://developer.apple.com/account/resources/certificates/add ):"
    echo "  1. Team: ${CN} (${TEAM_ID}) — not the free Personal Team, not UDIMA"
    echo "  2. Software → Developer ID Application"
    echo "  3. G2 Sub-CA is fine (default)"
    echo "  4. Choose File → ${CSR}"
    echo "  5. Download the .cer → then:"
    echo "       ./scripts/setup-signing.sh import ~/Downloads/developerID_application.cer"
    echo
    open "${CERTS}"
    open "https://developer.apple.com/account/resources/certificates/add"
    ;;

  import)
    CER="${2:-}"
    if [[ -z "${CER}" || ! -f "${CER}" ]]; then
      echo "usage: $0 import /path/to/developerID_application.cer" >&2
      exit 1
    fi
    if [[ ! -f "${KEY}" ]]; then
      echo "error: missing ${KEY}. Run: $0 csr" >&2
      exit 1
    fi
    PEM="${CERTS}/DeveloperID.pem"
    P12="${CERTS}/DeveloperID.p12"
    echo "→ Converting ${CER}…"
    openssl x509 -inform DER -in "${CER}" -out "${PEM}" 2>/dev/null \
      || openssl x509 -inform PEM -in "${CER}" -out "${PEM}"
    echo "→ Building .p12 (OpenSSL 3 legacy, so macOS Keychain accepts it)…"
    openssl pkcs12 -export \
      -legacy \
      -inkey "${KEY}" \
      -in "${PEM}" \
      -out "${P12}" \
      -name "Developer ID Application: ${CN}" \
      -passout pass:tmpimport
    chmod 600 "${P12}"
    echo "→ Importing into login keychain…"
    security import "${P12}" -k ~/Library/Keychains/login.keychain-db \
      -P tmpimport -T /usr/bin/codesign -T /usr/bin/security || true
    security add-certificates -k ~/Library/Keychains/login.keychain-db "${CER}" >/dev/null 2>&1 || true
    # Allow codesign to use the key without UI prompt on this Mac.
    IDENTITY="$(
      security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | head -1 \
        | sed -E 's/.*"([^"]+)".*/\1/' || true
    )"
    if [[ -n "${IDENTITY}" ]]; then
      security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
      echo "Installed identity: ${IDENTITY}"
    else
      echo "Imported, but codesign does not see a Developer ID identity yet."
      echo "Open Keychain Access and confirm the cert is paired with the private key."
    fi
    ;;

  notary)
    echo "Stores App Store Connect credentials in the keychain as '${NOTARY_PROFILE}'."
    echo "Create an app-specific password first:"
    echo "  https://appleid.apple.com → Sign-In and Security → App-Specific Passwords"
    echo
    open "https://account.apple.com/account/manage/section/security"
    xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
      --apple-id "${APPLE_ID}" \
      --team-id "${TEAM_ID}"
    echo
    echo "Profile saved. Sign + notarize with:"
    echo "  ./scripts/notarize.sh"
    ;;

  check|status)
    echo "Team:    ${TEAM_ID} (${CN})"
    echo "Profile: ${NOTARY_PROFILE}"
    echo
    echo "Code-signing identities:"
    print_identities
    echo
    if have_developer_id; then
      echo "Developer ID Application: YES"
    else
      echo "Developer ID Application: NO  ← required to share the app"
      echo "  Fast path: Xcode → Settings → Accounts → ${CN} (${TEAM_ID})"
      echo "             → Manage Certificates → + → Developer ID Application"
      echo "  Or:        ./scripts/setup-signing.sh csr"
    fi
    echo
    if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
      echo "notarytool profile '${NOTARY_PROFILE}': YES"
    else
      echo "notarytool profile '${NOTARY_PROFILE}': NO  ← required for Gatekeeper"
      echo "  ./scripts/setup-signing.sh notary"
    fi
    echo
    if have_developer_id && xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
      echo "Ready. Run:  ./scripts/notarize.sh"
    fi
    ;;

  -h|--help)
    sed -n '2,12p' "$0"
    ;;

  *)
    echo "Unknown command: ${cmd}" >&2
    exit 1
    ;;
esac
