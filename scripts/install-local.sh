#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_TARGET_DIR="$HOME/Applications"

cd "$ROOT_DIR"
swift build -c release --product catdex
APP_PATH="$($ROOT_DIR/scripts/build-app.sh)"

mkdir -p "$BIN_DIR" "$APP_TARGET_DIR"
TMP_CATDEX="$BIN_DIR/.catdex.tmp.$$"
cp "$ROOT_DIR/.build/release/catdex" "$TMP_CATDEX"
chmod 755 "$TMP_CATDEX"
mv -f "$TMP_CATDEX" "$BIN_DIR/catdex"
rm -rf "$APP_TARGET_DIR/CatdexMenu.app"
cp -R "$APP_PATH" "$APP_TARGET_DIR/CatdexMenu.app"

cat <<MSG
Installed:
  $BIN_DIR/catdex
  $APP_TARGET_DIR/CatdexMenu.app
MSG
