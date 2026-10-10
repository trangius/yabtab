#!/bin/sh
# Build YabTab.app into ~/Applications
set -e
cd "$(dirname "$0")"
app="$HOME/Applications/YabTab.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 5 -o "$app/Contents/MacOS/YabTab" main.swift
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.yabtab</string>
<key>CFBundleName</key><string>YabTab</string>
<key>CFBundleExecutable</key><string>YabTab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
# Stable self-signed identity so Screen Recording permission survives rebuilds
codesign --force --sign "WinPick Local Signing" "$app"
echo built "$app"

# Launch agent: start at login and keep running
agent="$HOME/Library/LaunchAgents/local.yabtab.plist"
cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.yabtab</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/YabTab</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl list local.yabtab >/dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$agent"
echo installed "$agent"
