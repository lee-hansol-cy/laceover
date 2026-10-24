#!/bin/zsh
# Release build → dist/LaceOver <version>.dmg (drag the app onto Applications to install).
# usage: tools/dmg/make_dmg.sh /path/to/python-with-dmgbuild
set -e
cd "$(dirname "$0")/../.."
PY=${1:-python3}
xcodegen generate -q
xcodebuild -project OSGLaceClock.xcodeproj -scheme OSGLaceClock -configuration Release -derivedDataPath build/DD build -quiet
APP="build/DD/Build/Products/Release/LaceOver.app"
codesign -f -s "OSG Lace Clock Dev" "$APP/Contents/Resources/LaceOver.saver"
codesign -f -s "OSG Lace Clock Dev" "$APP"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist build/dmg
cp tools/dmg/background.png tools/dmg/background@2x.png build/dmg/   # real Liquid Glass, captured by GlassArrow.swift
OUT="dist/LaceOver $VER.dmg"
rm -f "$OUT"
"$PY" -m dmgbuild -s tools/dmg/settings.py -D app="$APP" -D bg=build/dmg "LaceOver" "$OUT"
echo "$OUT"
