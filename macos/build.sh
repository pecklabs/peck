#!/usr/bin/env bash
# Builds PR Agent and assembles a menu-bar .app bundle (with embedded Sparkle).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Peck"
BUNDLE_ID="ai.pragent.menubar"
BUILD_DIR=".build/${CONFIG}"
APP="build/${APP_NAME}.app"

# Overridable for releases / CI.
APP_VERSION="${APP_VERSION:-0.3.0}"
APP_BUILD="${APP_BUILD:-${APP_VERSION}}"
SU_FEED_URL="${SU_FEED_URL:-https://github.com/pecklabs/peck/releases/latest/download/appcast.xml}"
SU_PUBLIC_KEY="${SU_PUBLIC_KEY:-nPiJbULahvPzeQB+20YmZR1d1DkEvkHr1J7NZU5rSBg=}"

echo "▶ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

echo "▶ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"

# The SwiftPM target is named PRAgent, but the user-facing process should be
# "Peck" (Activity Monitor, Force Quit, notifications, crash reports). Rename the
# binary in the bundle; CFBundleExecutable below matches.
cp "${BUILD_DIR}/PRAgent" "${APP}/Contents/MacOS/Peck"

# App icon — compile the Icon Composer .icon with actool into Assets.car (Liquid
# Glass, macOS 26+) plus AppIcon.icns (raster fallback for older systems).
# Finder / DMG / Spotlight; a menu-bar app has no Dock icon.
if [ -d "AppIcon.icon" ]; then
  xcrun actool AppIcon.icon \
    --compile "${APP}/Contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --output-partial-info-plist "build/icon-info.plist" \
    --output-format human-readable-text >/dev/null || true
fi
# Older toolchains (Xcode < 26) don't understand Icon Composer .icon bundles —
# actool silently emits nothing and the app ships with a generic Finder icon.
# Fall back to the checked-in prebuilt .icns so the icon never goes missing.
if [ ! -f "${APP}/Contents/Resources/AppIcon.icns" ]; then
  if [ -f "AppIcon.icns" ]; then
    echo "⚠ actool produced no AppIcon.icns (old Xcode?) — using prebuilt AppIcon.icns"
    cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
  else
    echo "✗ no app icon produced and no prebuilt AppIcon.icns fallback" >&2
    exit 1
  fi
fi

# SwiftPM resource bundle (skills, assets) — Bundle.module resolves it from Resources/.
if [ -d "${BUILD_DIR}/PRAgent_PRAgent.bundle" ]; then
  RESBUNDLE="${APP}/Contents/Resources/PRAgent_PRAgent.bundle"
  cp -R "${BUILD_DIR}/PRAgent_PRAgent.bundle" "${APP}/Contents/Resources/"
  # SwiftPM emits a flat resource bundle with no Info.plist; codesign won't treat
  # it as a bundle (and notarization needs every nested bundle signed). Give it a
  # minimal Info.plist so `codesign` in release.sh can seal it.
  if [ ! -f "${RESBUNDLE}/Info.plist" ]; then
    cat > "${RESBUNDLE}/Info.plist" <<RESPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}.resources</string>
  <key>CFBundleName</key><string>PRAgent</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${APP_BUILD}</string>
</dict>
</plist>
RESPLIST
  fi
  # Drop the uncompiled asset catalog — superseded by PNG resources, dead weight.
  rm -rf "${RESBUNDLE}/Media.xcassets"
fi

# Embed Sparkle.framework (auto-update).
if [ -d "${BUILD_DIR}/Sparkle.framework" ]; then
  ditto "${BUILD_DIR}/Sparkle.framework" "${APP}/Contents/Frameworks/Sparkle.framework"
fi

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>Peck</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${APP_BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Soohyun Jung · pecklabs</string>
  <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST

# Ad-hoc sign so Keychain access and local notifications work in local runs.
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ built ${APP}  (v${APP_VERSION} build ${APP_BUILD})"
echo "  run:  open '${APP}'"
