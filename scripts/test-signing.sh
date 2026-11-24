#!/bin/bash
# Static validation of code signing scripts
# Tests argument parsing, environment handling, and script logic
# DOES NOT test actual codesign operations (requires macOS)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0

echo "==> Static Validation of Signing Scripts"
echo "    (Does not run codesign - requires macOS for actual signing tests)"
echo ""

# Test helper
test_check() {
  local name="$1"
  local condition="$2"
  
  echo -n "CHECK: $name ... "
  if eval "$condition"; then
    echo "✓"
  else
    echo "✗ FAIL"
    ((FAILURES++))
  fi
}

# File existence checks
test_check "codesign-helper.sh exists and is executable" \
  "[[ -x '$ROOT/scripts/codesign-helper.sh' ]]"

test_check "build.sh exists" \
  "[[ -f '$ROOT/scripts/build.sh' ]]"

test_check "make-installer.sh exists" \
  "[[ -f '$ROOT/scripts/make-installer.sh' ]]"

test_check "install.sh exists" \
  "[[ -f '$ROOT/scripts/install.sh' ]]"

# Logic checks - codesign-helper.sh
echo ""
echo "==> Validating codesign-helper.sh logic"

test_check "Checks for DEVELOPER_ID_APPLICATION in production" \
  "grep -q 'DEVELOPER_ID_APPLICATION.*required' '$ROOT/scripts/codesign-helper.sh'"

test_check "Uses hardened runtime in production" \
  "grep -q 'options runtime' '$ROOT/scripts/codesign-helper.sh'"

test_check "Uses timestamp in production" \
  "grep -q 'timestamp' '$ROOT/scripts/codesign-helper.sh'"

test_check "Production SIGN_ARGS has no --deep" \
  "! (grep 'SIGN_ARGS=' -A 10 '$ROOT/scripts/codesign-helper.sh' | grep -q '\-\-deep')"

test_check "Development signing has no --deep" \
  "! (grep 'codesign.*sign.*APP_BUNDLE' '$ROOT/scripts/codesign-helper.sh' | grep -v verify | grep -q '\-\-deep')"

# Logic checks - build.sh
echo ""
echo "==> Validating build.sh logic"

test_check "Calls codesign-helper.sh" \
  "grep -q 'codesign-helper.sh' '$ROOT/scripts/build.sh'"

test_check "Respects PRODUCTION_SIGNING env" \
  "grep -q 'PRODUCTION_SIGNING' '$ROOT/scripts/build.sh'"

# Logic checks - make-installer.sh
echo ""
echo "==> Validating make-installer.sh logic"

test_check "Checks DEVELOPER_ID_INSTALLER" \
  "grep -q 'DEVELOPER_ID_INSTALLER' '$ROOT/scripts/make-installer.sh'"

test_check "Uses productsign for package" \
  "grep -q 'productsign' '$ROOT/scripts/make-installer.sh'"

test_check "Fails if PRODUCTION_SIGNING=1 but no DEVELOPER_ID_INSTALLER" \
  "grep -q 'ERROR.*DEVELOPER_ID_INSTALLER not set' '$ROOT/scripts/make-installer.sh'"

test_check "postinstall fails on invalid production signature" \
  "grep -q 'ERROR.*Production.*signature invalid' '$ROOT/scripts/make-installer.sh'"

# Logic checks - install.sh
echo ""
echo "==> Validating install.sh logic"

test_check "Checks PRODUCTION_SIGNING env" \
  "grep -q 'PRODUCTION_SIGNING' '$ROOT/scripts/install.sh'"

test_check "Fails on invalid production signature" \
  "grep -q 'ERROR.*Production install requires valid' '$ROOT/scripts/install.sh'"

test_check "Preserves existing signatures" \
  "grep -q 'Preserving existing code signature' '$ROOT/scripts/install.sh'"

# Entitlements check
echo ""
echo "==> Validating entitlements"

test_check "No unnecessary entitlements file" \
  "! [[ -f '$ROOT/scripts/entitlements.plist' ]]"

# Documentation check
echo ""
echo "==> Validating documentation"

test_check "SIGNING.md exists" \
  "[[ -f '$ROOT/docs/SIGNING.md' ]]"

test_check "No command-line passwords in docs" \
  "! grep -i 'password.*xxxx' '$ROOT/docs/SIGNING.md'"

# Summary
echo ""
echo "======================================"
if [[ $FAILURES -eq 0 ]]; then
  echo "✓ ALL STATIC CHECKS PASSED"
  echo ""
  echo "IMPORTANT: These are static checks only."
  echo "Actual codesign testing requires macOS with:"
  echo "  - Xcode command-line tools"
  echo "  - Developer ID certificates"
  echo "  - Test app bundle"
  echo "======================================"
  exit 0
else
  echo "✗ $FAILURES CHECK(S) FAILED"
  echo "======================================"
  exit 1
fi
