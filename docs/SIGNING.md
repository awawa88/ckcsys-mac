# Code Signing and Notarization

Developer ID signing and notarization support for Ckcsys.app.

## Modes

**Development (default)**: Ad-hoc signing, no certificates required
**Production**: Developer ID Application + Installer certificates required

## Requirements

### Development
- Xcode command-line tools

### Production
- Apple Developer account ($99/year)
- Developer ID Application certificate
- Developer ID Installer certificate  
- Notarytool keychain profile (for notarization)

## Certificates

### Obtaining

1. Join Apple Developer Program: https://developer.apple.com/programs/
2. Create certificates at https://developer.apple.com/account
   - Developer ID Application (for app)
   - Developer ID Installer (for package)
3. Download and install in Keychain Access
4. Verify: `security find-identity -v -p codesigning`

## Development Builds

No configuration needed:

```bash
./scripts/build.sh           # → build/Ckcsys.app (ad-hoc signed)
./scripts/make-installer.sh  # → ~/Desktop/Ckcsys-Installer.pkg (unsigned)
./scripts/install.sh         # Install locally
```

## Production Builds

### Environment

```bash
export PRODUCTION_SIGNING=1
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
```

### Build & Sign

```bash
./scripts/build.sh           # → Developer ID signed app
./scripts/make-installer.sh  # → Developer ID signed package
```

### Verify

```bash
# App signature
codesign -dv --verbose=4 build/Ckcsys.app
# Look for: Authority=Developer ID Application

# Hardened runtime
codesign -d --entitlements - build/Ckcsys.app | grep runtime

# Package signature  
pkgutil --check-signature ~/Desktop/Ckcsys-Installer.pkg
# Look for: signed by a developer certificate
```

## Notarization

### Setup (One-Time)

```bash
# Create keychain profile with interactive prompt (no password on command line)
xcrun notarytool store-credentials "notary-profile"
# Prompts for: Apple ID, Team ID, app-specific password

# Verify profile
xcrun notarytool history --keychain-profile "notary-profile"
```

**App-Specific Password**: Generate at https://appleid.apple.com → Security → App-Specific Passwords

### Submit

```bash
xcrun notarytool submit ~/Desktop/Ckcsys-Installer.pkg \
  --keychain-profile "notary-profile" \
  --wait
```

### Check Status

```bash
# View submission info
xcrun notarytool info SUBMISSION-ID --keychain-profile "notary-profile"

# Download log if rejected
xcrun notarytool log SUBMISSION-ID --keychain-profile "notary-profile" log.json
cat log.json | jq '.issues'
```

### Staple Ticket

```bash
# Attach notarization ticket to package
xcrun stapler staple ~/Desktop/Ckcsys-Installer.pkg

# Verify
xcrun stapler validate ~/Desktop/Ckcsys-Installer.pkg
spctl -a -v --type install ~/Desktop/Ckcsys-Installer.pkg
# Should show: source=Notarized Developer ID
```

## Signature Preservation

Production signatures are NEVER silently downgraded:

- **install.sh**: Fails if `PRODUCTION_SIGNING=1` and signature invalid
- **postinstall**: Fails if Developer ID signature becomes invalid
- **Development**: Re-signs with ad-hoc only if no production signature detected

This ensures production packages cannot be corrupted during installation.

## Implementation Details

### Scripts

**codesign-helper.sh**: Unified signing handler
- Production: Developer ID + hardened runtime + timestamp
- Development: Ad-hoc signature
- No `--deep` shortcuts (proper bundle signing)
- Fails fast if production identity missing

**build.sh**: Calls codesign-helper, respects `PRODUCTION_SIGNING`

**make-installer.sh**: Signs app + package, fails if production mode but identity missing

**install.sh**: Preserves signatures, fails closed in production mode

### No Entitlements

IMK apps require no entitlements unless using protected APIs. Ckcsys uses none, so no entitlements file exists. Hardened runtime works without exceptions.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No identity found" | Install certificates from Apple Developer portal |
| "Signature invalid after install" | Check `PRODUCTION_SIGNING` env matches build |
| Notarization rejected | Get log: `xcrun notarytool log ID --keychain-profile "notary-profile" log.json` |
| "Package damaged" on user Mac | Verify: `spctl -a -v --type install package.pkg` |

## Common Commands

```bash
# List identities
security find-identity -v -p codesigning

# Check signature
codesign --verify build/Ckcsys.app && echo "Valid" || echo "Invalid"

# View signature details
codesign -dv --verbose=4 build/Ckcsys.app

# Check hardened runtime
codesign -d --entitlements - build/Ckcsys.app | grep runtime
```

## Security

- Minimal entitlements (none currently needed)
- No library validation bypass
- No JIT compilation
- Hardened runtime enabled in production
- Keychain profiles for credentials (no passwords in scripts)
- Production signature verification prevents tampering

## Testing

**Static validation**: `./scripts/test-signing.sh`
- Checks script logic, argument parsing, environment handling
- Does NOT run codesign (requires macOS)
- Validates guards against missing identities

**Manual testing** (requires macOS + certificates):
1. Development build
2. Production build with identities
3. Package creation
4. Signature verification
5. Installation with signature preservation

## Limitations

- Certificates must be obtained from Apple (cannot generate)
- Signing requires macOS (codesign tools)
- Notarization requires manual submission
- Testing requires real Mac with certificates

## References

- Notarizing macOS Software: https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution
- Code Signing Guide: https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/
- Hardened Runtime: https://developer.apple.com/documentation/security/hardened_runtime
