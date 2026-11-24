#!/bin/bash
# Code signing helper for Ckcsys.app
# Supports both ad-hoc (development) and Developer ID (production) signing
# with proper nested signing order and hardened runtime.
#
# Usage:
#   codesign-helper.sh <app-bundle> [--production]
#
# Environment variables for production signing:
#   DEVELOPER_ID_APPLICATION  - Developer ID Application identity (required for --production)
#   CODESIGN_TIMESTAMP_URL    - Timestamp server (default: http://timestamp.apple.com/ts01)
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments or missing identity
#   2 - Signing failed

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: codesign-helper.sh <app-bundle> [--production]

Signs Ckcsys.app with either ad-hoc (dev) or Developer ID (production) signature.

Arguments:
  <app-bundle>    Path to Ckcsys.app
  --production    Use Developer ID Application signing (requires identity)

Environment for production:
  DEVELOPER_ID_APPLICATION    Developer ID Application identity name or hash
                              Example: "Developer ID Application: Your Name (TEAMID)"
  CODESIGN_TIMESTAMP_URL      Timestamp server URL (optional)
                              Default: http://timestamp.apple.com/ts01

Production signing includes:
  - Hardened runtime
  - Secure timestamp
  - Proper nested signing order (no --deep)
  - Minimal entitlements (only if needed)

Development (ad-hoc) signing:
  - Ad-hoc signature (-)
  - No timestamp required
  - Deep signing for simplicity

Examples:
  # Development build (ad-hoc)
  codesign-helper.sh build/Ckcsys.app

  # Production build (requires certificate)
  DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
    codesign-helper.sh build/Ckcsys.app --production
EOF
  exit 1
}

# Parse arguments
APP_BUNDLE="${1:-}"
PRODUCTION_MODE=false

if [[ $# -lt 1 ]]; then
  usage
fi

if [[ $# -ge 2 ]]; then
  case "$2" in
    --production)
      PRODUCTION_MODE=true
      ;;
    *)
      echo "ERROR: Unknown argument: $2" >&2
      usage
      ;;
  esac
fi

# Validate app bundle exists
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: App bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

if [[ ! -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
  echo "ERROR: Invalid app bundle (missing Info.plist): $APP_BUNDLE" >&2
  exit 1
fi

# Get bundle ID and validate
BUNDLE_ID=$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
if [[ -z "$BUNDLE_ID" ]]; then
  echo "ERROR: Cannot read CFBundleIdentifier from Info.plist" >&2
  exit 1
fi

echo "==> Signing $APP_BUNDLE"
echo "    Bundle ID: $BUNDLE_ID"
echo "    Mode: $(${PRODUCTION_MODE} && echo 'PRODUCTION (Developer ID)' || echo 'DEVELOPMENT (ad-hoc)')"

if $PRODUCTION_MODE; then
  # Production signing with Developer ID Application
  
  # Validate identity is set
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "ERROR: DEVELOPER_ID_APPLICATION environment variable required for production signing" >&2
    echo "       Set to your Developer ID Application identity name or hash" >&2
    echo "       Example: export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'" >&2
    exit 1
  fi
  
  IDENTITY="$DEVELOPER_ID_APPLICATION"
  TIMESTAMP_URL="${CODESIGN_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
  
  echo "    Identity: $IDENTITY"
  echo "    Timestamp: $TIMESTAMP_URL"
  
  # Verify identity exists and is valid
  if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "ERROR: Identity not found in keychain: $IDENTITY" >&2
    echo "       Available identities:" >&2
    security find-identity -v -p codesigning >&2
    exit 1
  fi
  
  # Check if entitlements are needed
  # For IMK apps, usually none are required unless using specific APIs
  ENTITLEMENTS_FILE=""
  if [[ -f "$(dirname "$0")/entitlements.plist" ]]; then
    ENTITLEMENTS_FILE="$(dirname "$0")/entitlements.plist"
    echo "    Entitlements: $ENTITLEMENTS_FILE"
  fi
  
  # Production signing uses proper nested order (no --deep shortcut)
  # Sign from innermost to outermost
  
  # 1. Sign any frameworks or nested bundles (none currently in Ckcsys)
  # 2. Sign main executable
  # 3. Sign app bundle
  
  echo "==> Signing with Developer ID Application (hardened runtime)"
  
  SIGN_ARGS=(
    --sign "$IDENTITY"
    --timestamp
    --options runtime
    --force
  )
  
  if [[ -n "$ENTITLEMENTS_FILE" ]]; then
    SIGN_ARGS+=(--entitlements "$ENTITLEMENTS_FILE")
  fi
  
  # Sign app bundle (includes executable)
  if ! codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE" 2>&1; then
    echo "ERROR: Signing failed" >&2
    exit 2
  fi
  
  # Verify signature
  echo "==> Verifying signature"
  if ! codesign --verify --verbose=2 --strict --deep "$APP_BUNDLE" 2>&1; then
    echo "ERROR: Signature verification failed" >&2
    exit 2
  fi
  
  # Check for hardened runtime
  if ! codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "runtime"; then
    echo "WARNING: Hardened runtime may not be enabled" >&2
  fi
  
  echo "==> Production signing complete"
  codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -E "Authority|Timestamp|Runtime" || true
  
else
  # Development signing with ad-hoc signature
  echo "==> Ad-hoc signing"
  
  if ! codesign --force --deep --sign - "$APP_BUNDLE" 2>&1; then
    echo "ERROR: Ad-hoc signing failed" >&2
    exit 2
  fi
  
  echo "==> Ad-hoc signing complete"
  codesign -dv "$APP_BUNDLE" 2>&1 | head -5
fi

echo "✓ Signing successful: $APP_BUNDLE"
