# Distribution Guide

This guide explains how to build, sign, and distribute VibeCheck as a macOS .app bundle and DMG.

## Prerequisites

- macOS 13+ (Ventura or later)
- Xcode 15+ with Command Line Tools
- Swift 5.9+
- (Optional) Apple Developer ID certificate for distribution
- (Optional) `create-dmg` tool: `brew install create-dmg`

## Building a Release

### 1. Build the .app Bundle

Run the build script:

```bash
./Scripts/build-release.sh
```

This will:
1. Build the release binary with `swift build -c release`
2. Create `.app` bundle structure in `dist/VibeCheck.app`
3. Copy binary, Info.plist, and skills
4. Code sign the bundle (ad-hoc signature or Developer ID if available)
5. Verify the signature

**Output:** `dist/VibeCheck.app`

### 2. Create DMG Installer

Run the DMG creation script:

```bash
./Scripts/create-dmg.sh
```

This creates a distributable DMG with drag-to-Applications setup.

**Output:** `dist/VibeCheck-2.0.0.dmg`

## Code Signing

### Development (Ad-hoc Signature)

By default, the build script uses an ad-hoc signature (`--sign -`) which works for local testing but **cannot be distributed**.

### Distribution (Developer ID)

For public distribution, you need an Apple Developer ID certificate:

1. **Get a Developer ID certificate** from [Apple Developer](https://developer.apple.com)
2. **Import** the certificate into your Keychain
3. **Run build script** - it will automatically detect and use your Developer ID

The script looks for certificates matching "Developer ID Application".

### Verification

Check the code signature:

```bash
codesign --verify --deep --strict --verbose=2 dist/VibeCheck.app
```

Display signature details:

```bash
codesign -dv --verbose=4 dist/VibeCheck.app
```

## Notarization (Required for Gatekeeper)

For distribution outside the Mac App Store, you must notarize the DMG:

### 1. Create App-Specific Password

1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign in and generate an app-specific password
3. Store credentials in Keychain:

```bash
xcrun notarytool store-credentials "vibecheck-notary" \
  --apple-id "your@email.com" \
  --team-id "TEAM_ID"
```

### 2. Submit for Notarization

```bash
xcrun notarytool submit dist/VibeCheck-2.0.0.dmg \
  --keychain-profile "vibecheck-notary" \
  --wait
```

This uploads the DMG to Apple's notarization service and waits for approval (~5 minutes).

### 3. Staple the Ticket

Once notarization succeeds, staple the ticket to the DMG:

```bash
xcrun stapler staple dist/VibeCheck-2.0.0.dmg
```

### 4. Verify Notarization

```bash
xcrun stapler validate dist/VibeCheck-2.0.0.dmg
spctl -a -t open --context context:primary-signature -v dist/VibeCheck-2.0.0.dmg
```

## Distribution Checklist

Before releasing a new version:

- [ ] Update version in `Info.plist` (CFBundleVersion and CFBundleShortVersionString)
- [ ] Update version in DMG filename in `Scripts/create-dmg.sh`
- [ ] Build: `./Scripts/build-release.sh`
- [ ] Test the .app bundle locally
- [ ] Create DMG: `./Scripts/create-dmg.sh`
- [ ] Test the DMG installation
- [ ] (If distributing) Sign with Developer ID
- [ ] (If distributing) Notarize the DMG
- [ ] (If distributing) Staple notarization ticket
- [ ] Upload to GitHub Releases
- [ ] Update release notes
- [ ] Test download and installation from public link

## GitHub Release

1. **Tag the release:**
   ```bash
   git tag -a v2.0.0 -m "Release 2.0.0"
   git push origin v2.0.0
   ```

2. **Create GitHub Release:**
   - Go to https://github.com/wanderingstan/vibe-check/releases/new
   - Select tag v2.0.0
   - Set title: "VibeCheck 2.0.0"
   - Add release notes
   - Upload `dist/VibeCheck-2.0.0.dmg`
   - Publish release

3. **Update README.md** with new download link

## Troubleshooting

### "App is damaged" error

This means Gatekeeper blocked the app. Either:
- Notarize the DMG (for distribution)
- Remove quarantine flag (for testing):
  ```bash
  xattr -dr com.apple.quarantine dist/VibeCheck.app
  ```

### Code signing fails

- Ensure Developer ID certificate is in Keychain
- Check certificate validity: `security find-identity -v -p codesigning`
- Verify entitlements file exists: `cat VibeCheck.entitlements`

### DMG creation fails

- Install `create-dmg`: `brew install create-dmg`
- Or use basic hdiutil method (automatically used as fallback)

### Notarization fails

- Check error log: `xcrun notarytool log <submission-id> --keychain-profile "vibecheck-notary"`
- Common issues:
  - Missing hardened runtime (added via `--options runtime`)
  - Invalid entitlements
  - Unsigned embedded frameworks

## File Locations

After installation, VibeCheck stores data in standard macOS locations:

- **App:** `/Applications/VibeCheck.app`
- **Database:** `~/Library/Application Support/VibeCheck/vibe_check.db`
- **Settings:** `~/Library/Preferences/com.wanderingstan.vibe-check.plist`
- **Skills:** `~/.claude/skills/vibe-check-*/`
- **MCP Config:** `~/.claude/mcp_servers.json`

## Build Output

The build creates:

```
dist/
├── VibeCheck.app/
│   └── Contents/
│       ├── MacOS/
│       │   └── VibeCheck          # Binary
│       ├── Resources/
│       │   └── skills/            # Bundled skills
│       ├── Info.plist
│       └── _CodeSignature/        # Code signature
└── VibeCheck-2.0.0.dmg            # Distributable DMG
```

## Performance Metrics

Expected performance improvements over Python version:

- **Startup time:** <500ms (vs 2-3s Python)
- **Memory usage:** ~15-30 MB (vs 50-80 MB Python)
- **File processing:** Similar latency (<100ms per event)
- **Database queries:** Equal or better (GRDB vs Python sqlite3)

## Resources

- [Apple Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
- [Notarization Documentation](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [create-dmg Tool](https://github.com/create-dmg/create-dmg)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
