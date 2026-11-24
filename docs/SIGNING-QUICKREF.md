# Code Signing Quick Reference

## Development Builds (No Configuration)

```bash
./scripts/build.sh           # Ad-hoc signed app
./scripts/make-installer.sh  # Unsigned package
./scripts/install.sh         # Install locally
```

## Production Builds (Requires Certificates)

### 1. Set Environment

```bash
export PRODUCTION_SIGNING=1
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
```

### 2. Build & Sign

```bash
./scripts/build.sh           # → build/Ckcsys.app (Developer ID signed)
./scripts/make-installer.sh  # → ~/Desktop/Ckcsys-Installer.pkg (signed)
```

### 3. Verify Signatures

```bash
# App
codesign -dv --verbose=4 build/Ckcsys.app
# Look for: Authority=Developer ID Application

# Package
pkgutil --check-signature ~/Desktop/Ckcsys-Installer.pkg
# Look for: signed by a developer certificate
```

### 4. Notarize

```bash
# One-time setup
xcrun notarytool store-credentials "notary-profile" \
  --apple-id "your@email.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"

# Submit
xcrun notarytool submit ~/Desktop/Ckcsys-Installer.pkg \
  --keychain-profile "notary-profile" \
  --wait

# Staple
xcrun stapler staple ~/Desktop/Ckcsys-Installer.pkg

# Verify
xcrun stapler validate ~/Desktop/Ckcsys-Installer.pkg
spctl -a -v --type install ~/Desktop/Ckcsys-Installer.pkg
```

## Common Commands

```bash
# List signing identities
security find-identity -v -p codesigning

# Check if app is signed
codesign --verify build/Ckcsys.app && echo "Valid" || echo "Invalid"

# View signature details
codesign -dv --verbose=4 build/Ckcsys.app

# Check hardened runtime
codesign -d --entitlements - build/Ckcsys.app | grep runtime

# Test signing scripts
./scripts/test-signing.sh
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No identity found | Install certificates from Apple Developer portal |
| Signature invalid after install | Fixed in install.sh (preserves signatures) |
| Notarization rejected | Get log: `xcrun notarytool log SUBMISSION-ID --keychain-profile "notary-profile" notary-log.json` |
| Package damaged error | Verify notarization: `spctl -a -v --type install package.pkg` |

## Full Documentation

See `docs/SIGNING.md` for complete guide.
