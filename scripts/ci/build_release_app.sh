#!/usr/bin/env bash
set -euo pipefail

SCHEME="${SCHEME:-UniFiRebootManager}"
PROJECT_PATH="${PROJECT_PATH:-macos/UniFiRebootManager.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_ROOT="${BUILD_ROOT:-$PWD/build}"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project not found at: $PROJECT_PATH" >&2
  exit 1
fi

# Build with code signing when DEVELOPMENT_TEAM is set, otherwise unsigned
SIGNING_ARGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
  echo "Code signing enabled (team: $DEVELOPMENT_TEAM, identity: $CODE_SIGN_IDENTITY)"
  SIGNING_ARGS+=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Manual
    OTHER_CODE_SIGN_FLAGS=--timestamp
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  )
else
  echo "Code signing disabled (set DEVELOPMENT_TEAM to enable)"
  SIGNING_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi

echo "Building scheme '$SCHEME' ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "${SIGNING_ARGS[@]}" \
  clean build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/${SCHEME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at expected path: $APP_PATH" >&2
  exit 1
fi

echo "Built app: $APP_PATH"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "app_path=$APP_PATH" >> "$GITHUB_OUTPUT"
fi
