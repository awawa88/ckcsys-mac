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

# Refuse to install a bundle that is missing the Windows lexicon tables.
TABLES_SRC="$SRC/Contents/Resources/tables"
for req in cht_zimb_VISTA.tsv cht_cimb_VISTA.tsv; do
  if [[ ! -f "$TABLES_SRC/$req" ]]; then
    echo "ERROR: $TABLES_SRC/$req missing — rebuild with Resources/tables populated" >&2
    exit 1
  fi
done
ZIMB_SZ=$(wc -c < "$TABLES_SRC/cht_zimb_VISTA.tsv" | tr -d ' ')
CIMB_SZ=$(wc -c < "$TABLES_SRC/cht_cimb_VISTA.tsv" | tr -d ' ')
if [[ "$ZIMB_SZ" -lt 100000 || "$CIMB_SZ" -lt 1000000 ]]; then
  echo "ERROR: lexicon tables look truncated (zimb=${ZIMB_SZ}B cimb=${CIMB_SZ}B)" >&2
  exit 1
fi

kill_ime() {
  pkill -f "Ckcsys.app/Contents/MacOS/Ckcsys" 2>/dev/null || true
  pkill -f "CKC縱橫" 2>/dev/null || true
}

wait_ime_gone() {
  local i
  for i in $(seq 1 40); do
    if ! pgrep -f "Ckcsys.app/Contents/MacOS/Ckcsys" >/dev/null 2>&1 \
       && ! pgrep -f "CKC縱橫.app/Contents/MacOS" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  # Last resort — install must not race with a half-dead process.
  pkill -9 -f "Ckcsys.app/Contents/MacOS/Ckcsys" 2>/dev/null || true
  pkill -9 -f "CKC縱橫" 2>/dev/null || true
  sleep 0.5
}

echo "==> Installing to $DEST"
mkdir -p "$DEST_DIR"
echo "==> Stopping running IME (avoid load during bundle replace)"
kill_ime
wait_ime_gone

rm -rf "$DEST"
rm -rf "$DEST_DIR/CKC縱橫.app"
cp -R "$SRC" "$DEST"
codesign --force --deep --sign - "$DEST"

# TextInputMenu may have auto-relaunched mid-copy; kill again then open the finished bundle.
kill_ime
wait_ime_gone

echo "==> Registering input source"
/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Support/InputMethodInstaller.app/Contents/MacOS/InputMethodInstaller "$DEST" 2>/dev/null || true
touch "$DEST_DIR"
open "$DEST" 2>/dev/null || true
sleep 1

echo "==> Installed:"
ls -la "$DEST"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$DEST/Contents/Info.plist"
ls -la "$DEST/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "NO ICON"
ls -la "$DEST/Contents/Resources/tables/"*.tsv
echo "INSTALL OK (lexicon zimb=${ZIMB_SZ}B cimb=${CIMB_SZ}B)"
