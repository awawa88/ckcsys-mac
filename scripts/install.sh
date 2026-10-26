#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Ckcsys"
SRC="$ROOT/build/${APP_NAME}.app"
DEST_DIR="$HOME/Library/Input Methods"
DEST="$DEST_DIR/${APP_NAME}.app"

if [[ ! -d "$SRC" ]]; then
  echo "Build first: scripts/build.sh"
  exit 1
fi

echo "==> Installing to $DEST"
mkdir -p "$DEST_DIR"
# Quit existing instances (new + legacy Chinese name)
pkill -f "Ckcsys.app/Contents/MacOS/Ckcsys" 2>/dev/null || true
pkill -f "CKC縱橫" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
rm -rf "$DEST_DIR/CKC縱橫.app"
cp -R "$SRC" "$DEST"
codesign --force --deep --sign - "$DEST"

echo "==> Registering input source"
/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Support/InputMethodInstaller.app/Contents/MacOS/InputMethodInstaller "$DEST" 2>/dev/null || true
touch "$DEST_DIR"
open "$DEST" 2>/dev/null || true
sleep 1

echo "==> Installed:"
ls -la "$DEST"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$DEST/Contents/Info.plist"
ls -la "$DEST/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "NO ICON"
echo "INSTALL OK"
