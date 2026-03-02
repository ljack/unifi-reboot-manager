#!/usr/bin/env bash
set -euo pipefail

# Imports a Developer ID certificate into a temporary keychain for CI signing.
#
# Required env vars:
#   APPLE_CERTIFICATE_BASE64   - Base64-encoded .p12 certificate
#   APPLE_CERTIFICATE_PASSWORD - Password for the .p12 file

: "${APPLE_CERTIFICATE_BASE64:?Missing APPLE_CERTIFICATE_BASE64}"
: "${APPLE_CERTIFICATE_PASSWORD:?Missing APPLE_CERTIFICATE_PASSWORD}"

KEYCHAIN_NAME="build.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"

CERT_FILE="$(mktemp)"
cleanup() {
  rm -f "$CERT_FILE"
}
trap cleanup EXIT

# Decode certificate (printf avoids echo interpreting escape sequences;
# -D is the BSD/macOS base64 decode flag)
printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 -D > "$CERT_FILE"

# Create and configure temporary keychain
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# Import certificate
security import "$CERT_FILE" \
  -k "$KEYCHAIN_NAME" \
  -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -f pkcs12

# Allow codesign to access the keychain without prompting
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# Prepend the build keychain to the search list so codesign finds it
security list-keychains -d user -s "$KEYCHAIN_NAME" $(security list-keychains -d user | tr -d '"')

echo "Certificate imported into keychain: $KEYCHAIN_NAME"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "keychain_name=$KEYCHAIN_NAME" >> "$GITHUB_OUTPUT"
fi
