#!/usr/bin/env bash
# Builds, Developer ID-signs, notarizes, and packages PR Agent into a DMG.
#
# ── One-time setup (you do this once) ───────────────────────────────────────
# 1) Apple Developer Program membership ($99/yr).
# 2) A "Developer ID Application" certificate installed in your login keychain
#    (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application).
#    Find its name:   security find-identity -v -p codesigning
# 3) An app-specific password (appleid.apple.com ▸ Sign-In & Security) and a
#    notarytool keychain profile:
#       xcrun notarytool store-credentials "PRAgentNotary" \
#         --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
#
# ── Each release ────────────────────────────────────────────────────────────
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="PRAgentNotary" \
#   ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${DEV_ID:?Set DEV_ID to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile}"

APP_NAME="Peck"
APP="build/${APP_NAME}.app"
DMG="build/Peck.dmg"   # no spaces → clean release-asset URLs

echo "▶ Assembling release bundle"
./build.sh release   # builds + assembles build/PR Agent.app (ad-hoc signed)

echo "▶ Signing with Developer ID + hardened runtime"
sign() { codesign --force --options runtime --timestamp --sign "${DEV_ID}" "$1"; }

# Sign Sparkle's nested helpers inside-out, then the framework.
FW="${APP}/Contents/Frameworks/Sparkle.framework"
if [ -d "${FW}" ]; then
  V="${FW}/Versions/B"
  for item in \
    "${V}/XPCServices/Downloader.xpc" \
    "${V}/XPCServices/Installer.xpc" \
    "${V}/Updater.app" \
    "${V}/Autoupdate"; do
    [ -e "${item}" ] && sign "${item}"
  done
  sign "${FW}"
fi

# Then the app's own inner items, then the wrapper.
[ -d "${APP}/Contents/Resources/PRAgent_PRAgent.bundle" ] && sign "${APP}/Contents/Resources/PRAgent_PRAgent.bundle"
sign "${APP}/Contents/MacOS/PRAgent"
sign "${APP}"

echo "▶ Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

echo "▶ Notarizing (zip → submit → wait)"
ZIP="build/${APP_NAME}.zip"
rm -f "${ZIP}"
/usr/bin/ditto -c -k --keepParent "${APP}" "${ZIP}"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
rm -f "${ZIP}"

echo "▶ Stapling ticket to the app"
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

echo "▶ Building DMG"
rm -f "${DMG}"
STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
rm -rf "${STAGE}"

echo "▶ Gatekeeper assessment"
spctl -a -vvv --type install "${DMG}" || true

echo "✓ Done: ${DMG}"
echo "  Share this DMG — it opens without Gatekeeper warnings."
