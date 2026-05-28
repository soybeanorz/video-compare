#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/VideoCompare.app"
INSTALL_DIR="/Applications/VideoCompare.app"

"$ROOT_DIR/scripts/build_app.sh" release
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"
echo "$INSTALL_DIR"
