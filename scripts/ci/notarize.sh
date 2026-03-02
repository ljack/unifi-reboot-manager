#!/usr/bin/env bash
set -euo pipefail

# Submits a DMG to Apple for notarization and staples the ticket.
#
# Required env vars:
#   APPLE_ID      - Apple ID email
#   APPLE_TEAM_ID - 10-character Team ID
#   APPLE_APP_PASSWORD - App-specific password
#
# Usage: notarize.sh <path-to-dmg>

DMG_PATH="${1:?Usage: notarize.sh <path-to-dmg>}"

: "${APPLE_ID:?Missing APPLE_ID}"
: "${APPLE_TEAM_ID:?Missing APPLE_TEAM_ID}"
: "${APPLE_APP_PASSWORD:?Missing APPLE_APP_PASSWORD}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

echo "Submitting for notarization: $DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "Notarization complete: $DMG_PATH"
