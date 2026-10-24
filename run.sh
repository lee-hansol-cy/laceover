#!/bin/zsh
# Build, sign, install to ~/Applications (+ the .saver to ~/Library/Screen Savers) and launch.
set -e
cd "$(dirname "$0")"
xcodegen generate -q
xcodebuild -project OSGLaceClock.xcodeproj -scheme OSGLaceClock -configuration Release -derivedDataPath build/DD build -quiet
APP="build/DD/Build/Products/Release/LaceOver.app"
ID="OSG Lace Clock Dev"   # self-signed, in the login keychain; a fixed identity keeps Screen Recording granted across builds
codesign -f -s "$ID" "$APP/Contents/Resources/LaceOver.saver"
codesign -f -s "$ID" "$APP"
pkill -f "OSG Lace Clock.app/Contents/MacOS" || true   # the old name
pkill -f "LaceOver.app/Contents/MacOS" || true
sleep 0.5
rm -rf ~/Applications/"OSG Lace Clock.app" ~/Applications/"LaceOver.app"
cp -R "$APP" ~/Applications/
rm -rf ~/Library/"Screen Savers/OSG Lace Clock.saver" ~/Library/"Screen Savers/LaceOver.saver"
cp -R ~/Applications/"LaceOver.app/Contents/Resources/LaceOver.saver" ~/Library/"Screen Savers/"
pkill -f legacyScreenSaver || true
open ~/Applications/"LaceOver.app"
