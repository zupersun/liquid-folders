#!/bin/zsh
# Build "Liquid Folder.app" in .build/.
# Usage: ./build.sh   then open ".build/Liquid Folder.app" (or drag it to /Applications first).
set -e
cd "${0:A:h}"
swift build -c release
app=".build/Liquid Folder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/liquidfolder "$app/Contents/MacOS/"
mkdir -p "$app/Contents/Resources"
.build/release/liquidfolder icon .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.zupersun.liquidfolder</string>
  <key>CFBundleName</key><string>Liquid Folder</string>
  <key>CFBundleExecutable</key><string>liquidfolder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# SIGN="Apple Development" keeps macOS permissions across rebuilds (ad hoc, each build is a new app to them); a download
# for others needs a Developer ID signature and notarization.
codesign --force --sign "${SIGN:--}" "$app"
echo "$app"
