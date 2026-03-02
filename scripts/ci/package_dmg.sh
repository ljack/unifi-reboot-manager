#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?Usage: package_dmg.sh <app_path> <dmg_path> [volume_name]}"
DMG_PATH="${2:?Usage: package_dmg.sh <app_path> <dmg_path> [volume_name]}"
VOLUME_NAME="${3:-UniFi Reboot Manager}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$DMG_PATH")"

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Sign the DMG if a signing identity is available
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  echo "Signing DMG with: $CODE_SIGN_IDENTITY"
  codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo "Created DMG: $DMG_PATH"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "dmg_path=$DMG_PATH" >> "$GITHUB_OUTPUT"
fi
