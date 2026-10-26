#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Ckcsys"
BUNDLE_ID="com.andrewlam.inputmethod.ckc"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Cleaning $APP"
rm -rf "$APP"
# Also remove legacy Chinese-named build product if present
rm -rf "$BUILD_DIR/CKC縱橫.app"
mkdir -p "$MACOS" "$RES/tables"

echo "==> Compiling Swift sources"
swiftc -O \
  -framework Cocoa \
  -framework InputMethodKit \
  -framework Carbon \
  -target arm64-apple-macos13.0 \
  -module-name CKCZongheng \
  -parse-as-library \
  -Xfrontend -disable-availability-checking \
  -o "$MACOS/${APP_NAME}" \
  "$ROOT/Sources/main.swift" \
  "$ROOT/Sources/DictionaryStore.swift" \
  "$ROOT/Sources/CandidateWindow.swift" \
  "$ROOT/Sources/StatusConsole.swift" \
  "$ROOT/Sources/AddPhrasePanel.swift" \
  "$ROOT/Sources/CKCInputController.swift"

echo "==> Copying resources"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/ckc_seed.txt" "$RES/ckc_seed.txt"
if [[ ! -d "$ROOT/Resources/tables" ]]; then
  echo "ERROR: Resources/tables missing — place cht_zimb_VISTA.tsv / cht_cimb_VISTA.tsv" >&2
  exit 1
fi
shopt -s nullglob
TABLE_FILES=("$ROOT/Resources/tables"/*.tsv)
shopt -u nullglob
if [[ ${#TABLE_FILES[@]} -eq 0 ]]; then
  echo "ERROR: Resources/tables has no .tsv lexicon files" >&2
  exit 1
fi
cp -R "$ROOT/Resources/tables/." "$RES/tables/"
echo "==> Bundled tables: $(ls -1 "$RES/tables"/*.tsv | wc -l | tr -d ' ') tsv file(s)"
ls -la "$RES/tables"/*.tsv

# Localized display name (Ckcsys) — critical so Input Sources never shows bundle id
for loc in Base.lproj en.lproj zh-Hant.lproj zh-Hans.lproj; do
  if [[ -d "$ROOT/Resources/$loc" ]]; then
    mkdir -p "$RES/$loc"
    cp -R "$ROOT/Resources/$loc/." "$RES/$loc/"
  fi
done

# App / Input Source icon
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
  echo "==> AppIcon.icns bundled"
else
  echo "WARNING: Resources/AppIcon.icns missing" >&2
fi

# Menu-bar Input Source icon (template TIFF; AppIcon.icns is full-color and shows blank)
if [[ -f "$ROOT/Resources/menuIcon.tiff" ]]; then
  cp "$ROOT/Resources/menuIcon.tiff" "$RES/menuIcon.tiff"
  echo "==> menuIcon.tiff bundled"
else
  echo "WARNING: Resources/menuIcon.tiff missing — menu bar icon will be blank" >&2
fi
if [[ -f "$ROOT/Resources/menuIcon.png" ]]; then
  cp "$ROOT/Resources/menuIcon.png" "$RES/menuIcon.png"
fi
if [[ -f "$ROOT/Resources/menuIcon.icns" ]]; then
  cp "$ROOT/Resources/menuIcon.icns" "$RES/menuIcon.icns"
fi

chmod +x "$MACOS/${APP_NAME}"

echo "==> Ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> Verifying bundle"
plutil -lint "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$CONTENTS/Info.plist" || true
ls -la "$RES/AppIcon.icns" "$RES/menuIcon.tiff" 2>/dev/null || true
ls "$RES"/*.lproj 2>/dev/null || true
codesign -dv "$APP" 2>&1 | head -20
echo "BUILD OK: $APP"
