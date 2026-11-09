#!/bin/zsh
# Build a release .app, install it to ~/Applications and register a login item.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$HOME/Applications/Usage Bar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/usage-bar "$app/Contents/MacOS/usage-bar"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Usage Bar</string>
<key>CFBundleIdentifier</key><string>com.ballermatic.usage-bar</string>
<key>CFBundleExecutable</key><string>usage-bar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
pkill -x usage-bar 2>/dev/null || true
osascript -e 'tell application "System Events" to delete (every login item whose name is "Usage Bar")' 2>/dev/null || true
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$app\", hidden:true}"
open "$app"
echo "Installed $app"
