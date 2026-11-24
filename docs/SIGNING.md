# Code Signing and Notarization Guide

This document describes the Developer ID signing and notarization workflow for Ckcsys.app.

## Overview

Ckcsys supports two signing modes:

1. **Development (ad-hoc)**: Default mode for local development
2. **Production (Developer ID)**: For distribution outside the Mac App Store

## Requirements

### Development Signing (Ad-hoc)
- No special requirements
- Works on any Mac with Xcode command-line tools

### Production Signing (Developer ID)
- Apple Developer account ($99/year)
- Developer ID Application certificate
- Developer ID Installer certificate
- Keychain profile for notarytool (recommended)

## Certificates

### Obtaining Certificates

1. **Join Apple Developer Program**: https://developer.apple.com/programs/
2. **Create Certificates**:
   - Log in to https://developer.apple.com/account
   - Navigate to Certificates, Identifiers & Profiles
   - Create two certificates:
     - **Developer ID Application** - for signing the app
     - **Developer ID Installer** - for signing the installer package

3. **Download and Install**:
   - Download both certificates (.cer files)
   - Double-click to install in Keychain Access
   - Verify they appear in Keychain under "My Certificates"

### Verifying Certificates

```bash
# List all code signing identities
security find-identity -v -p codesigning

# Should show entries like:
# 1) HASH "Developer ID Application: Your Name (TEAMID)"
# 2) HASH "Developer ID Installer: Your Name (TEAMID)"
```

## Development Builds (Ad-hoc Signing)

Default mode - no configuration needed:

```bash
# Build with ad-hoc signature
./scripts/build.sh

# Create installer with ad-hoc signatures
./scripts/make-installer.sh

# Install locally
./scripts/install.sh
```

**Result**: 
- App: ad-hoc signed
- Package: unsigned

## Production Builds (Developer ID)

### Environment Variables

Set these in your shell or CI/CD environment:

```bash
# Required for production signing
export PRODUCTION_SIGNING=1
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"

# Optional - customize timestamp server
export CODESIGN_TIMESTAMP_URL="http://timestamp.apple.com/ts01"
```

### Building

```bash
# 1. Build and sign app with Developer ID Application
PRODUCTION_SIGNING=1 \
  DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build.sh

# 2. Create and sign installer with Developer ID Installer  
PRODUCTION_SIGNING=1 \
  DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
  DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
  ./scripts/make-installer.sh

# Output: ~/Desktop/Ckcsys-Installer.pkg (signed)
```

### Verifying Signatures

```bash
# Verify app signature
codesign -dv --verbose=4 build/Ckcsys.app
# Should show: Authority=Developer ID Application: Your Name (TEAMID)

# Verify hardened runtime
codesign -d --entitlements - build/Ckcsys.app | grep runtime

# Verify package signature
pkgutil --check-signature ~/Desktop/Ckcsys-Installer.pkg
# Should show: Status: signed by a developer certificate
```

## Notarization

Notarization is Apple's process for scanning your app for malicious content.

### Setup Notary Tool

1. **Create App-Specific Password**:
   - Go to https://appleid.apple.com
   - Sign in with your Apple ID
   - Navigate to Security → App-Specific Passwords
   - Generate a new password (save it securely)

2. **Store Credentials in Keychain**:
```bash
# Replace with your Apple ID and app-specific password
xcrun notarytool store-credentials "notary-profile" \
  --apple-id "your@email.com" \
  --team-id "TEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"

# This creates a keychain profile named "notary-profile"
# No secrets in repo or logs!
```

3. **Verify Profile**:
```bash
xcrun notarytool history --keychain-profile "notary-profile"
```

### Submitting for Notarization

```bash
# Submit signed package for notarization
xcrun notarytool submit ~/Desktop/Ckcsys-Installer.pkg \
  --keychain-profile "notary-profile" \
  --wait

# Output will show:
# - Submission ID (save this!)
# - Status: Accepted (success) or Rejected (failure)
```

### Checking Notarization Status

```bash
# Check specific submission
xcrun notarytool info SUBMISSION-ID \
  --keychain-profile "notary-profile"

# Download log if rejected
xcrun notarytool log SUBMISSION-ID \
  --keychain-profile "notary-profile" \
  notary-log.json

# View reasons for rejection
cat notary-log.json | jq '.issues'
```

### Stapling the Ticket

After successful notarization, attach the ticket to the package:

```bash
# Staple notarization ticket to package
xcrun stapler staple ~/Desktop/Ckcsys-Installer.pkg

# Verify stapling
xcrun stapler validate ~/Desktop/Ckcsys-Installer.pkg
# Should show: The validate action worked!

# Also verify with spctl
spctl -a -v --type install ~/Desktop/Ckcsys-Installer.pkg
# Should show: source=Notarized Developer ID
```

### Complete Production Workflow

```bash
#!/bin/bash
# Production build, sign, notarize, and staple

set -euo pipefail

# 1. Set environment
export PRODUCTION_SIGNING=1
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"

# 2. Build with Developer ID signature
./scripts/build.sh

# 3. Create signed installer
./scripts/make-installer.sh

PKG=~/Desktop/Ckcsys-Installer.pkg

# 4. Submit for notarization
echo "Submitting for notarization..."
xcrun notarytool submit "$PKG" \
  --keychain-profile "notary-profile" \
  --wait

# 5. Staple ticket
echo "Stapling ticket..."
xcrun stapler staple "$PKG"

# 6. Verify
echo "Verifying..."
xcrun stapler validate "$PKG"
spctl -a -v --type install "$PKG"

echo "✓ Production package ready: $PKG"
```

## Signature Preservation

The build scripts automatically preserve existing signatures:

- `install.sh`: Only re-signs if no valid signature exists
- `postinstall`: Only re-signs if no valid signature exists
- Never destroys Developer ID signatures

This ensures that:
- Production builds remain properly signed after installation
- Notarization tickets are preserved
- Users don't see Gatekeeper warnings

## Troubleshooting

### "No identity found" Error

**Cause**: Developer ID certificate not installed

**Solution**:
1. Download certificate from Apple Developer portal
2. Install in Keychain Access
3. Verify: `security find-identity -v -p codesigning`

### "Hardened runtime" Warnings

**Cause**: Missing entitlements or incompatible APIs

**Solution**:
1. Check `scripts/entitlements.plist` for required permissions
2. Review codesign output for specific runtime violations
3. Add minimal entitlements only as needed

### Notarization Rejected

**Cause**: Various - check log for details

**Solution**:
```bash
# Get rejection reasons
xcrun notarytool log SUBMISSION-ID \
  --keychain-profile "notary-profile" \
  notary-log.json
cat notary-log.json | jq '.issues'

# Common issues:
# - Invalid signature: Re-sign with correct identity
# - Missing hardened runtime: Check codesign-helper.sh includes --options runtime
# - Invalid entitlements: Review entitlements.plist
```

### "Package is damaged" on User Mac

**Cause**: Missing notarization staple or signature

**Solution**:
1. Verify package is notarized: `spctl -a -v --type install package.pkg`
2. Ensure ticket is stapled: `xcrun stapler validate package.pkg`
3. If valid, user may need to approve in System Settings → Privacy & Security

## Security Best Practices

1. **Never commit secrets**: Use keychain profiles, not passwords in scripts
2. **Minimal entitlements**: Only grant permissions the app actually needs
3. **No library validation bypass**: Keep security features enabled
4. **Verify before distribution**: Always test signed packages on clean Mac
5. **Keep certificates secure**: Store in Keychain, not files

## Testing

Run automated tests to verify signing configuration:

```bash
./scripts/test-signing.sh
```

Tests verify:
- Script argument parsing
- Environment variable handling
- Signature preservation logic
- Production signing guards (fail if identity missing)
- Hardened runtime configuration
- Entitlements validity

## Limitations

- **No automatic certificate generation**: Certificates must be obtained from Apple
- **No automatic notarization**: Manual submission required
- **Testing requires macOS**: Signing tools only available on Mac
- **Keychain access required**: Certificates must be in macOS Keychain

## References

- Apple Developer Documentation: https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution
- Notarizing macOS Software: https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution
- Code Signing Guide: https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/
- Hardened Runtime: https://developer.apple.com/documentation/security/hardened_runtime

## Support

For issues with:
- **Certificates**: Contact Apple Developer Support
- **Notarization**: Check https://developer.apple.com/system-status/
- **Build scripts**: File an issue in this repository
