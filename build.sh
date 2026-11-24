#!/bin/bash
# Builds Claude Pet into ~/.claude/pet/ClaudePet.app and restarts it. Run install.sh once first to hook up Claude.
set -e
cd "$(dirname "$0")"
APP=~/.claude/pet/ClaudePet.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library ClaudePet.swift -o "$APP/Contents/MacOS/ClaudePet"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.claudepet.app</string>
<key>CFBundleName</key><string>Claude Pet</string>
<key>CFBundleExecutable</key><string>ClaudePet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$APP" >/dev/null 2>&1
cp hook.py pet.html install.sh ~/.claude/pet/
# the login item runs ~/.claude/pet/ClaudePet; exec into the bundle so macOS sees a real app (needed for notifications)
printf '#!/bin/sh\nexec "$HOME/.claude/pet/ClaudePet.app/Contents/MacOS/ClaudePet"\n' > ~/.claude/pet/ClaudePet
chmod +x ~/.claude/pet/ClaudePet
launchctl kickstart -k "gui/$(id -u)/com.claudepet" 2>/dev/null || true
echo "Claude Pet built and restarted."
