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
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-${APP_VERSION}}"
SU_FEED_URL="${SU_FEED_URL:-https://github.com/OWNER/REPO/releases/latest/download/appcast.xml}"
SU_PUBLIC_KEY="${SU_PUBLIC_KEY:-REPLACE_WITH_SPARKLE_PUBLIC_KEY}"

echo "▶ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

echo "▶ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"

cp "${BUILD_DIR}/PRAgent" "${APP}/Contents/MacOS/PRAgent"

# SwiftPM resource bundle (skills, assets) — Bundle.module resolves it from Resources/.
if [ -d "${BUILD_DIR}/PRAgent_PRAgent.bundle" ]; then
  cp -R "${BUILD_DIR}/PRAgent_PRAgent.bundle" "${APP}/Contents/Resources/"
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
  <key>CFBundleExecutable</key><string>PRAgent</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${APP_BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>PR Agent</string>
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
