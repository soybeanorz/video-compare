#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_DIR="$ROOT_DIR/dist/VideoCompare.app"
EXECUTABLE="$ROOT_DIR/.build/$CONFIGURATION/VideoCompare"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/VideoCompare"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
find "$ROOT_DIR/Resources" -maxdepth 1 -type f ! -name "Info.plist" -exec cp {} "$APP_DIR/Contents/Resources/" \;
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "$APP_DIR"
