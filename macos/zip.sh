#!/usr/bin/env bash
# Quick share: builds the release app and zips it.
# The app is only ad-hoc signed, so on another Mac the recipient must right-click
# the app ▸ Open (once) — or run:  xattr -dr com.apple.quarantine "PR Agent.app"
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Peck"
APP="build/${APP_NAME}.app"
ZIP="build/Peck.zip"

./build.sh release
rm -f "${ZIP}"
/usr/bin/ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "✓ ${ZIP}"
echo "  Share it. Recipient: right-click the app ▸ Open the first time"
echo "  (or: xattr -dr com.apple.quarantine '${APP_NAME}.app')."
