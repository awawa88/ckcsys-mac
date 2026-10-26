#!/bin/bash
# Build a double-clickable user-domain installer for Ckcsys.
# Output: ~/Desktop/Ckcsys-Installer.pkg (+ README beside it)
# Installs to: ~/Library/Input Methods/Ckcsys.app (no SIP, no admin when possible)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Ckcsys"
BUNDLE_ID="com.andrewlam.inputmethod.ckc"
PKG_ID="${BUNDLE_ID}.installer"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo "0.1.0")"
BUILD_APP="$ROOT/build/${APP_NAME}.app"
DESKTOP="${HOME}/Desktop"
OUT_PKG="${DESKTOP}/${APP_NAME}-Installer.pkg"
OUT_README="${DESKTOP}/${APP_NAME}-Installer-README.txt"

REBUILD=0
for arg in "$@"; do
  case "$arg" in
    --rebuild|-r) REBUILD=1 ;;
    --help|-h)
      echo "Usage: $0 [--rebuild]"
      echo "  Produces ${APP_NAME}-Installer.pkg on the Desktop."
      exit 0
      ;;
  esac
done

if [[ "$REBUILD" -eq 1 || ! -d "$BUILD_APP" ]]; then
  echo "==> Building app first"
  "$ROOT/scripts/build.sh"
fi

if [[ ! -d "$BUILD_APP" ]]; then
  echo "ERROR: missing $BUILD_APP — run scripts/build.sh" >&2
  exit 1
fi

echo "==> Ad-hoc codesign of app bundle"
codesign --force --deep --sign - "$BUILD_APP"

WORKDIR="$(mktemp -d /tmp/ckc-make-installer.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

PAYLOAD="$WORKDIR/payload"
SCRIPTS="$WORKDIR/scripts"
RES_DIR="$WORKDIR/resources"
mkdir -p "$PAYLOAD" "$SCRIPTS" "$RES_DIR"

echo "==> Staging payload (relative to user home via installer domain)"
ditto "$BUILD_APP" "$PAYLOAD/${APP_NAME}.app"

# postinstall: finalize ownership, re-sign, register, show instructions
cat > "$SCRIPTS/postinstall" << 'POST'
#!/bin/bash
set -euo pipefail

APP_NAME="Ckcsys"

if [[ "$(id -u)" -eq 0 ]]; then
  CONSOLE_USER="$(stat -f '%Su' /dev/console)"
  if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
    CONSOLE_USER="$(/usr/bin/logname 2>/dev/null || true)"
  fi
  USER_HOME="$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
else
  CONSOLE_USER="$(id -un)"
  USER_HOME="${HOME}"
fi

if [[ -z "${USER_HOME:-}" || ! -d "$USER_HOME" ]]; then
  echo "postinstall: could not resolve home directory" >&2
  exit 1
fi

# Installer passes: $1=pkg-path $2=destination-path $3=… 
# For home-domain installs, $2 is typically "~/Library/Input Methods"
if [[ -n "${2:-}" && -d "${2}/${APP_NAME}.app" ]]; then
  DEST_DIR="$2"
elif [[ -n "${2:-}" && "$(basename "$2")" == "${APP_NAME}.app" ]]; then
  DEST_DIR="$(dirname "$2")"
else
  DEST_DIR="${USER_HOME}/Library/Input Methods"
fi
DEST="${DEST_DIR}/${APP_NAME}.app"

# If the package domain landed the app somewhere unexpected, find it
if [[ ! -d "$DEST" ]]; then
  for candidate in \
    "${2:-}/${APP_NAME}.app" \
    "${USER_HOME}/Library/Input Methods/${APP_NAME}.app" \
    "/Library/Input Methods/${APP_NAME}.app"
  do
    if [[ -d "$candidate" ]]; then
      mkdir -p "${USER_HOME}/Library/Input Methods"
      DEST_DIR="${USER_HOME}/Library/Input Methods"
      DEST="${DEST_DIR}/${APP_NAME}.app"
      rm -rf "$DEST"
      ditto "$candidate" "$DEST"
      break
    fi
  done
fi

if [[ ! -d "$DEST" ]]; then
  echo "postinstall: ${APP_NAME}.app not found after package extract" >&2
  exit 1
fi

# Stop any running instance (best-effort)
if [[ "$(id -u)" -eq 0 && -n "${CONSOLE_USER:-}" && "$CONSOLE_USER" != "root" ]]; then
  sudo -u "$CONSOLE_USER" pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
  chown -R "${CONSOLE_USER}:staff" "$DEST" 2>/dev/null || true
else
  pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
fi
sleep 0.3

codesign --force --deep --sign - "$DEST" 2>/dev/null || true
touch "$DEST_DIR"

# Launch once so IMK can register (best-effort)
if [[ "$(id -u)" -eq 0 && -n "${CONSOLE_USER:-}" && "$CONSOLE_USER" != "root" ]]; then
  sudo -u "$CONSOLE_USER" open "$DEST" 2>/dev/null || true
else
  open "$DEST" 2>/dev/null || true
fi

# Friendly completion dialog only for GUI Installer.app (not CLI installer)
if [[ -z "${COMMAND_LINE_INSTALL:-}" ]]; then
  DIALOG_SCRIPT='display dialog "Ckcsys 已安裝到：
~/Library/Input Methods/Ckcsys.app

請完成啟用（只需一次）：
1. 系統設定 → 鍵盤 → 輸入法
2. 按「編輯…」或「+」，搜尋並加入「縱橫」
3. 若提示「輸入監控」，請允許 Ckcsys
4. 測試：在文字編輯輸入 0307，按空白鍵 → 應出現「我」" buttons {"好"} default button 1 with title "Ckcsys 安裝完成"'
  if [[ "$(id -u)" -eq 0 && -n "${CONSOLE_USER:-}" && "$CONSOLE_USER" != "root" ]]; then
    sudo -u "$CONSOLE_USER" osascript -e "$DIALOG_SCRIPT" 2>/dev/null || true
  else
    osascript -e "$DIALOG_SCRIPT" 2>/dev/null || true
  fi
fi

echo "postinstall OK: $DEST"
exit 0
POST
chmod +x "$SCRIPTS/postinstall"

# Clean xattrs before first pkgbuild
xattr -cr "$PAYLOAD" "$SCRIPTS" 2>/dev/null || true
find "$SCRIPTS" -name '._*' -delete 2>/dev/null || true

COMPONENT_PKG="$WORKDIR/${PKG_ID}.pkg"
echo "==> pkgbuild component package"
pkgbuild \
  --root "$PAYLOAD" \
  --scripts "$SCRIPTS" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location "Library/Input Methods" \
  --ownership recommended \
  "$COMPONENT_PKG"

# Welcome / conclusion for Installer.app UI
cat > "$RES_DIR/welcome.txt" << EOF
Ckcsys 縱橫輸入法 ${VERSION}

這個安裝程式會把輸入法安裝到目前使用者目錄：

  ~/Library/Input Methods/${APP_NAME}.app

不需要系統管理員權限，也不會寫入受 SIP 保護的路徑。

安裝後請在「系統設定 → 鍵盤 → 輸入法」手動加入「縱橫」。
EOF

cat > "$RES_DIR/conclusion.txt" << EOF
安裝完成。

啟用步驟：
1. 系統設定 → 鍵盤 → 輸入法 → +（或「編輯…」）
2. 搜尋並加入「縱橫」
3. 若提示「輸入監控」，請允許
4. 測試：0307 → 空白鍵 →「我」

詳細說明見桌面上的 ${APP_NAME}-Installer-README.txt
EOF

DIST="$WORKDIR/Distribution.xml"
cat > "$DIST" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Ckcsys 縱橫輸入法</title>
    <organization>com.andrewlam</organization>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
    <welcome file="welcome.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.txt" mime-type="text/plain"/>
    <choices-outline>
        <line choice="default">
            <line choice="${PKG_ID}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${PKG_ID}" visible="false">
        <pkg-ref id="${PKG_ID}"/>
    </choice>
    <pkg-ref id="${PKG_ID}" version="${VERSION}" auth="None">${PKG_ID}.pkg</pkg-ref>
</installer-gui-script>
EOF

# Strip AppleDouble / xattrs that can confuse Installer scripts
echo "==> Stripping xattrs from staged files"
xattr -cr "$PAYLOAD" "$SCRIPTS" "$RES_DIR" 2>/dev/null || true
find "$SCRIPTS" -name '._*' -delete 2>/dev/null || true

# Rebuild component after xattr strip (payload already staged; re-pkg if needed)
# Ensure component PackageInfo uses auth="none" so Installer does not demand admin
echo "==> Rewriting component PackageInfo auth=none"
EXPAND_COMP="$WORKDIR/comp-expand"
rm -rf "$EXPAND_COMP"
pkgutil --expand "$COMPONENT_PKG" "$EXPAND_COMP"
# PackageInfo is at root of expanded component
PI="$EXPAND_COMP/PackageInfo"
if [[ -f "$PI" ]]; then
  /usr/bin/sed -i '' 's/auth="root"/auth="none"/g' "$PI"
fi
# Remove AppleDouble next to postinstall if present
find "$EXPAND_COMP" -name '._*' -delete 2>/dev/null || true
xattr -cr "$EXPAND_COMP" 2>/dev/null || true
rm -f "$COMPONENT_PKG"
pkgutil --flatten "$EXPAND_COMP" "$COMPONENT_PKG"

echo "==> productbuild distribution package → $OUT_PKG"
rm -f "$OUT_PKG"
productbuild \
  --distribution "$DIST" \
  --resources "$RES_DIR" \
  --package-path "$WORKDIR" \
  "$OUT_PKG"

# Final pass: expand product, ensure nested PackageInfo auth=none, flatten
FINAL_EXPAND="$WORKDIR/final-expand"
rm -rf "$FINAL_EXPAND"
pkgutil --expand "$OUT_PKG" "$FINAL_EXPAND"
find "$FINAL_EXPAND" -name PackageInfo -print0 | while IFS= read -r -d '' pi; do
  /usr/bin/sed -i '' 's/auth="root"/auth="none"/g' "$pi"
done
find "$FINAL_EXPAND" -name '._*' -delete 2>/dev/null || true
xattr -cr "$FINAL_EXPAND" 2>/dev/null || true
rm -f "$OUT_PKG"
pkgutil --flatten "$FINAL_EXPAND" "$OUT_PKG"

# Desktop README (English + 中文 brief)
cat > "$OUT_README" << EOF
Ckcsys 縱橫輸入法 — Installer README
================================
Installer: ${APP_NAME}-Installer.pkg
Version:   ${VERSION}
Installs:  ~/Library/Input Methods/${APP_NAME}.app
           (user domain only — no SIP paths, no admin required when possible)

How to install
--------------
1. Double-click ${APP_NAME}-Installer.pkg
2. Follow the prompts (choose “Install for me only” / home if asked)
3. When finished, enable the input source (next section)

If macOS blocks the unsigned local package:
  Right-click the .pkg → Open → Open

Enable 縱橫 (one-time)
----------------------
1. System Settings → Keyboard → Input Sources
2. Click Edit… or +
3. Search for 縱橫 (also try Chinese, Traditional / Others)
4. Select 縱橫 → Add
5. Switch via the menu bar input menu

If prompted, allow Input Monitoring for Ckcsys.

Smoke test
----------
1. Open TextEdit, switch to 縱橫
2. Type 0307, press Space → expect 我
3. Type 289449, press Space → expect 縱橫

Rebuild later
-------------
cd ~/Projects/ckcsys-mac
./scripts/make-installer.sh          # use existing build/
./scripts/make-installer.sh --rebuild  # rebuild app then package

Bundle ID: ${BUNDLE_ID}
EOF

echo ""
echo "INSTALLER OK"
ls -lh "$OUT_PKG" "$OUT_README"
pkgutil --check-signature "$OUT_PKG" 2>&1 || true
echo "PKG: $OUT_PKG"
