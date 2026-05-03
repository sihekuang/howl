#!/usr/bin/env bash
# Configures GitHub Actions secrets for macOS notarization on this repo.
#
# Prerequisites (one-time, in the Apple Developer portal):
#   1. Create a "Developer ID Application" certificate (Xcode →
#      Settings → Accounts → Manage Certificates, or
#      developer.apple.com/account/resources/certificates).
#   2. Export it from Keychain Access as a .p12 with a password.
#   3. Create an App Store Connect API key with the "Developer" role
#      (appstoreconnect.apple.com → Users and Access → Integrations →
#      Team Keys). Download the .p8 file (one-shot download). Note the
#      Key ID and Issuer ID.
#
# What this script does:
#   - Validates the .p12 imports cleanly into a temp keychain and
#     extracts the signing-identity common name.
#   - Validates the App Store Connect API key authenticates against
#     Apple (calls `notarytool history` — catches typos before they
#     poison the repo).
#   - Pushes 8 secrets into the GitHub repo via `gh secret set`.
#
# Usage (interactive):
#   ./scripts/setup-notarization.sh
#
# Usage (non-interactive — useful for cert rotation):
#   MACOS_CERT_P12=/path/to/cert.p12 \
#   MACOS_CERT_PASSWORD=... \
#   APPLE_API_KEY_P8=/path/to/AuthKey_XXXXXXXXXX.p8 \
#   APPLE_API_KEY_ID=XXXXXXXXXX \
#   APPLE_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
#   APPLE_TEAM_ID=ABCDE12345 \
#     ./scripts/setup-notarization.sh

set -euo pipefail

bail() { echo "✗ $*" >&2; exit 1; }
say()  { echo "→ $*"; }
ok()   { echo "✓ $*"; }

# --- preflight ---------------------------------------------------------

command -v gh >/dev/null     || bail "gh CLI not installed. brew install gh"
command -v xcrun >/dev/null  || bail "xcrun not found (need Xcode command line tools)"
command -v base64 >/dev/null || bail "base64 not found (should be in macOS by default)"

gh auth status >/dev/null 2>&1 || bail "gh not authenticated. Run: gh auth login"

git rev-parse --show-toplevel >/dev/null 2>&1 || bail "not in a git repo"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
  || bail "could not resolve GitHub repo (is the remote pushed?)"
say "target repo: $REPO"

# --- collect inputs ----------------------------------------------------

prompt() {
  local var=$1 msg=$2 silent=${3:-}
  local cur="${!var:-}"
  if [[ -n "$cur" ]]; then return; fi
  if [[ "$silent" == "silent" ]]; then
    read -r -s -p "$msg: " val; echo
  else
    read -r -p "$msg: " val
  fi
  printf -v "$var" '%s' "$val"
}

prompt MACOS_CERT_P12         "Path to Developer ID Application .p12 file"
[[ -f "$MACOS_CERT_P12" ]] || bail "p12 not found: $MACOS_CERT_P12"

prompt MACOS_CERT_PASSWORD    ".p12 export password" silent
[[ -n "${MACOS_CERT_PASSWORD:-}" ]] || bail "p12 password is required"

prompt APPLE_API_KEY_P8       "Path to App Store Connect API key (.p8)"
[[ -f "$APPLE_API_KEY_P8" ]] || bail "p8 not found: $APPLE_API_KEY_P8"

prompt APPLE_API_KEY_ID       "App Store Connect Key ID (e.g. ABCDE12345)"
prompt APPLE_API_ISSUER_ID    "App Store Connect Issuer ID (UUID format)"
prompt APPLE_TEAM_ID          "Apple Team ID (10-char alphanumeric)"

# --- validate cert by importing into a temp keychain -------------------

TMPDIR_LOCAL="$(mktemp -d)"
KC="$TMPDIR_LOCAL/setup.keychain-db"
KC_PW="$(openssl rand -base64 24)"

cleanup() {
  if [[ -f "$KC" ]]; then
    security delete-keychain "$KC" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR_LOCAL"
}
trap cleanup EXIT

say "validating .p12 (importing into temp keychain)…"
security create-keychain -p "$KC_PW" "$KC" >/dev/null
security set-keychain-settings -lut 600 "$KC" >/dev/null
security unlock-keychain -p "$KC_PW" "$KC" >/dev/null
if ! security import "$MACOS_CERT_P12" \
        -k "$KC" \
        -P "$MACOS_CERT_PASSWORD"; then
  bail ".p12 import failed (wrong password, or corrupt file) — see security output above"
fi

# Show what's actually in the .p12 — useful when something doesn't match.
echo "  identities found in .p12:"
security find-identity -v -p codesigning "$KC" | sed 's/^/    /'

# Extract the Developer ID identity. There may be multiple identities
# in the cert; the Developer ID Application one is what we want.
IDENTITY="$(security find-identity -v -p codesigning "$KC" \
  | grep -E '"Developer ID Application:' \
  | head -n1 \
  | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.+)"$/\1/')"

[[ -n "$IDENTITY" ]] \
  || bail "no 'Developer ID Application' identity in this .p12 — see list above. Did you export the right cert?"

ok "signing identity: $IDENTITY"


# --- validate notarytool creds -----------------------------------------

say "validating App Store Connect API key against Apple…"
# `notarytool history` is a cheap auth check — it lists past submissions
# without uploading anything. Failure here = wrong Key ID / Issuer ID /
# .p8 mismatch / revoked key.
if ! xcrun notarytool history \
        --key "$APPLE_API_KEY_P8" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" \
        >/dev/null 2>&1; then
  bail "notarytool authentication failed. Check Key ID / Issuer ID / .p8 file."
fi
ok "notarytool credentials authenticated"

# --- push secrets ------------------------------------------------------

# `gh secret set --body -` reads from stdin so the secret never lands
# on disk or in argv. base64 is line-broken on macOS by default; gh
# stores it verbatim and the workflow decodes with `base64 --decode`.

set_secret() {
  local name=$1 value=$2
  # `gh secret set` reads from stdin when no --body is given. Older
  # workarounds used `--body -` but on some gh versions that stores the
  # literal string "-" instead of consuming stdin, which silently breaks
  # everything downstream. Pipe-to-stdin is the documented form.
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO"
  ok "set $name"
}

set_secret_from_file() {
  local name=$1 path=$2
  base64 -i "$path" | gh secret set "$name" --repo "$REPO"
  ok "set $name (base64 of $(basename "$path"))"
}

say "pushing secrets to ${REPO}…"
set_secret_from_file MACOS_CERT_P12_BASE64    "$MACOS_CERT_P12"
set_secret           MACOS_CERT_PASSWORD      "$MACOS_CERT_PASSWORD"
set_secret           MACOS_KEYCHAIN_PASSWORD  "$(openssl rand -base64 24)"
set_secret           MACOS_SIGNING_IDENTITY   "$IDENTITY"
set_secret_from_file APPLE_API_KEY_BASE64     "$APPLE_API_KEY_P8"
set_secret           APPLE_API_KEY_ID         "$APPLE_API_KEY_ID"
set_secret           APPLE_API_ISSUER_ID      "$APPLE_API_ISSUER_ID"
set_secret           APPLE_TEAM_ID            "$APPLE_TEAM_ID"

cat <<EOF

✓ All 8 notarization secrets are now set on $REPO.

Next:
  - Update .github/workflows/build.yml to import the cert, sign with
    Developer ID, submit to notarytool, and staple. Ask Claude to
    do this — credentials are now in place.
  - The signing identity is also available as the secret
    MACOS_SIGNING_IDENTITY (= "$IDENTITY") so the workflow doesn't
    need to hardcode the team name.
EOF
