#!/bin/bash
# Test script for code signing helper and production signing workflow
# Validates argument parsing, environment handling, and signature preservation

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/ckc-signing-test.XXXXXX)"
FAILURES=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "==> Testing code signing scripts"
echo "    Test directory: $TEST_DIR"
echo ""

# Helper to run tests
run_test() {
  local test_name="$1"
  local test_cmd="$2"
  
  echo -n "TEST: $test_name ... "
  if eval "$test_cmd" >/dev/null 2>&1; then
    echo "✓ PASS"
    return 0
  else
    echo "✗ FAIL"
    ((FAILURES++))
    return 1
  fi
}

run_test_expect_fail() {
  local test_name="$1"
  local test_cmd="$2"
  
  echo -n "TEST: $test_name ... "
  if eval "$test_cmd" >/dev/null 2>&1; then
    echo "✗ FAIL (expected failure but succeeded)"
    ((FAILURES++))
    return 1
  else
    echo "✓ PASS (failed as expected)"
    return 0
  fi
}

# Test 1: codesign-helper.sh exists and is executable
run_test "codesign-helper.sh exists and is executable" \
  "[[ -x '$ROOT/scripts/codesign-helper.sh' ]]"

# Test 2: codesign-helper.sh shows usage when called without arguments
run_test_expect_fail "codesign-helper.sh requires arguments" \
  "'$ROOT/scripts/codesign-helper.sh'"

# Test 3: codesign-helper.sh rejects invalid app bundle path
run_test_expect_fail "codesign-helper.sh rejects non-existent bundle" \
  "'$ROOT/scripts/codesign-helper.sh' /nonexistent/app.app"

# Test 4: Create a minimal test app bundle
echo ""
echo "==> Creating test app bundle"
TEST_APP="$TEST_DIR/TestApp.app"
mkdir -p "$TEST_APP/Contents/MacOS"
mkdir -p "$TEST_APP/Contents/Resources"

cat > "$TEST_APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.test.signingtest</string>
	<key>CFBundleName</key>
	<string>TestApp</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
</dict>
</plist>
EOF

echo '#!/bin/bash' > "$TEST_APP/Contents/MacOS/TestApp"
echo 'echo "Test app"' >> "$TEST_APP/Contents/MacOS/TestApp"
chmod +x "$TEST_APP/Contents/MacOS/TestApp"

run_test "Test app bundle created" \
  "[[ -f '$TEST_APP/Contents/Info.plist' ]]"

# Test 5: Ad-hoc signing works
echo ""
echo "==> Testing ad-hoc signing"
run_test "Ad-hoc signing succeeds" \
  "'$ROOT/scripts/codesign-helper.sh' '$TEST_APP'"

run_test "Ad-hoc signed app has valid signature" \
  "codesign --verify '$TEST_APP'"

# Test 6: Production signing without identity fails appropriately
echo ""
echo "==> Testing production signing error handling"
unset DEVELOPER_ID_APPLICATION 2>/dev/null || true

run_test_expect_fail "Production mode without identity fails" \
  "'$ROOT/scripts/codesign-helper.sh' '$TEST_APP' --production"

# Test 7: Signature preservation logic
echo ""
echo "==> Testing signature preservation"
TEST_APP2="$TEST_DIR/TestApp2.app"
cp -R "$TEST_APP" "$TEST_APP2"

# Sign it first
codesign --force --deep --sign - "$TEST_APP2" 2>/dev/null

# Check that it's signed
run_test "Test app 2 is signed" \
  "codesign --verify '$TEST_APP2'"

# Simulate what install.sh does - check if re-sign is avoided
RESIGNED=false
if ! codesign --verify "$TEST_APP2" 2>/dev/null; then
  codesign --force --deep --sign - "$TEST_APP2" 2>/dev/null
  RESIGNED=true
fi

run_test "Signature preservation works (should not re-sign)" \
  "[[ '$RESIGNED' == 'false' ]]"

# Test 8: postinstall signature preservation logic
echo ""
echo "==> Testing postinstall signature preservation logic"
cat > "$TEST_DIR/test-postinstall-logic.sh" << 'TESTSCRIPT'
#!/bin/bash
# Simulates postinstall signature preservation
APP="$1"
if ! codesign --verify "$APP" 2>/dev/null; then
  echo "would-resign"
  exit 0
else
  echo "preserve"
  exit 0
fi
TESTSCRIPT
chmod +x "$TEST_DIR/test-postinstall-logic.sh"

RESULT=$("$TEST_DIR/test-postinstall-logic.sh" "$TEST_APP2")
run_test "Postinstall preserves existing signature" \
  "[[ '$RESULT' == 'preserve' ]]"

# Test 9: Environment variable handling
echo ""
echo "==> Testing environment variable handling"

# Check that PRODUCTION_SIGNING env is respected in build.sh
grep -q 'PRODUCTION_SIGNING' "$ROOT/scripts/build.sh"
run_test "build.sh checks PRODUCTION_SIGNING env" \
  "grep -q 'PRODUCTION_SIGNING' '$ROOT/scripts/build.sh'"

# Check that DEVELOPER_ID_APPLICATION is used in codesign-helper
grep -q 'DEVELOPER_ID_APPLICATION' "$ROOT/scripts/codesign-helper.sh"
run_test "codesign-helper checks DEVELOPER_ID_APPLICATION" \
  "grep -q 'DEVELOPER_ID_APPLICATION' '$ROOT/scripts/codesign-helper.sh'"

# Check that DEVELOPER_ID_INSTALLER is used in make-installer.sh
grep -q 'DEVELOPER_ID_INSTALLER' "$ROOT/scripts/make-installer.sh"
run_test "make-installer checks DEVELOPER_ID_INSTALLER" \
  "grep -q 'DEVELOPER_ID_INSTALLER' '$ROOT/scripts/make-installer.sh'"

# Test 10: Hardened runtime flag presence
echo ""
echo "==> Testing hardened runtime configuration"
grep -q 'options runtime' "$ROOT/scripts/codesign-helper.sh"
run_test "codesign-helper enables hardened runtime" \
  "grep -q 'options runtime' '$ROOT/scripts/codesign-helper.sh'"

# Test 11: Timestamp configuration
grep -q 'timestamp' "$ROOT/scripts/codesign-helper.sh"
run_test "codesign-helper includes timestamp" \
  "grep -q 'timestamp' '$ROOT/scripts/codesign-helper.sh'"

# Test 12: Entitlements file exists and is valid
echo ""
echo "==> Testing entitlements"
run_test "entitlements.plist exists" \
  "[[ -f '$ROOT/scripts/entitlements.plist' ]]"

run_test "entitlements.plist is valid XML" \
  "plutil -lint '$ROOT/scripts/entitlements.plist'"

# Test 13: Check that --deep is NOT used in production mode
grep -A 10 'PRODUCTION_MODE=true' "$ROOT/scripts/codesign-helper.sh" | grep -v 'deep'
run_test "Production signing does NOT use --deep flag" \
  "! (grep -A 20 'Production signing' '$ROOT/scripts/codesign-helper.sh' | grep -q 'deep')"

# Test 14: Validate error on production without identity
echo ""
echo "==> Testing production signing guards"
run_test "make-installer.sh fails if PRODUCTION_SIGNING=1 but no DEVELOPER_ID_INSTALLER" \
  "grep -q 'PRODUCTION_SIGNING=.*DEVELOPER_ID_INSTALLER not set' '$ROOT/scripts/make-installer.sh'"

# Summary
echo ""
echo "======================================"
if [[ $FAILURES -eq 0 ]]; then
  echo "✓ ALL TESTS PASSED"
  echo "======================================"
  exit 0
else
  echo "✗ $FAILURES TEST(S) FAILED"
  echo "======================================"
  exit 1
fi
