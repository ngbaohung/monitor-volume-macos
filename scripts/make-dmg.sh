#!/bin/zsh
# Packages the app into dist/MonitorVolume-<version>.dmg: a standalone installer to keep as a backup.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="dist/MonitorVolume-$VERSION.dmg"
STAGING="build/dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" dist
cp -R "build/Monitor Volume.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/How to Install.txt" <<'EOF'
Monitor Volume – install

1. Drag "Monitor Volume" onto the Applications folder.
2. Open it from Applications.
   If macOS says it can't be opened (the app isn't notarized by Apple):
   System Settings › Privacy & Security › scroll down › "Open Anyway".
   Or run in Terminal:  xattr -dr com.apple.quarantine "/Applications/Monitor Volume.app"
3. Click the speaker icon in the menu bar › "Open Accessibility Settings…"
   and turn on Monitor Volume so the volume keys work.
4. To use Mac mode (software volume), pick "Mac" in the panel and allow
   System Audio Recording when asked.

The app adds itself to Login Items on first launch.
EOF

hdiutil create -volname "Monitor Volume" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Created $DMG"
