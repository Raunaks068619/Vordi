#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/DerivedData"
PROJECT_NAME="Vordi"
APP_NAME="Vordi"
BUILT_APP="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

cd "$PROJECT_DIR"

xcodebuild \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$PROJECT_NAME" \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  build

pkill -f "/$APP_NAME.app" 2>/dev/null || true

rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
codesign --force --deep --options runtime \
  --entitlements "$PROJECT_DIR/Resources/Vordi.entitlements" \
  --sign - "$INSTALLED_APP"

open "$INSTALLED_APP"
pgrep -fl "$INSTALLED_APP/Contents/MacOS/$APP_NAME" || true
