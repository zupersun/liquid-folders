#!/bin/zsh
# Build "Liquid Folder.app" in .build/: the agent, a menu bar switch and right-click actions, started at login.
# Usage: ./build.sh   then open ".build/Liquid Folder.app" (or drag it to /Applications first).
set -e
cd "${0:A:h}"
swift build -c release
app=".build/Liquid Folder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/liquidfolder "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.liquidfolder.app</string>
  <key>CFBundleName</key><string>Liquid Folder</string>
  <key>CFBundleExecutable</key><string>liquidfolder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# "Liquify" and "Unliquify" in Finder's right-click menu, under Quick Actions (one folder or many): Quick Actions the app installs in
# ~/Library/Services. (A Finder extension's items never show for files in iCloud Drive, a Desktop there included.)
mkdir -p "$app/Contents/Resources"
cp -R QuickActions/Liquify.workflow QuickActions/Unliquify.workflow "$app/Contents/Resources/"
# SIGN="Apple Development" keeps macOS permissions across rebuilds (ad hoc, each build is a new app to them); a download
# for others needs a Developer ID signature and notarization.
codesign --force --sign "${SIGN:--}" "$app"
echo "$app"
