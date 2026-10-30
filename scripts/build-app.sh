#!/bin/zsh
# Builds "Monitor Volume.app" into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Monitor Volume.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MonitorVolume"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MonitorVolume"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
    rm -rf build/AppIcon.iconset
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity if one exists, so the Accessibility grant survives rebuilds.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MonitorVolume 2>/dev/null || true
    rm -rf "/Applications/Monitor Volume.app"
    cp -R "$APP" /Applications/
    open "/Applications/Monitor Volume.app"
    echo "Installed to /Applications"
fi
