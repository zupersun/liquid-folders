#!/bin/zsh
# Install Liquid Folder from the latest release into Applications and open it: `npx liquid-folders` runs this every time
# (a reinstall too); `npm install` only the first time, as npm skips a package it already has.
set -e
[[ $npm_lifecycle_event == postinstall && $npm_command == exec ]] && exit 0  # npx: it runs this as the command next
[[ $(uname) == Darwin ]] || { echo "Liquid Folder is for macOS."; exit 0; }
tmp=$(mktemp -d)
curl -fsSL https://github.com/zupersun/liquid-folders/releases/latest/download/Liquid-Folder.zip -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp"
dest=${LIQUID_FOLDER_DEST:-/Applications}
[[ -w $dest ]] || dest=~/Applications
mkdir -p "$dest"
pkill -f "Liquid Folder.app/Contents/MacOS/liquidfolder" || true
rm -rf "$dest/Liquid Folder.app"
mv "$tmp/Liquid Folder.app" "$dest/"
rm -rf "$tmp"
echo "Liquid Folder is in $dest. Allow it in System Settings > Privacy & Security > Accessibility when asked."
[[ -n $LIQUID_FOLDER_DEST ]] && exit 0
# Opened through Finder, so macOS treats it as its own app (not part of this terminal).
osascript -e "tell application \"Finder\" to open (POSIX file \"$dest/Liquid Folder.app\" as alias)" >/dev/null
