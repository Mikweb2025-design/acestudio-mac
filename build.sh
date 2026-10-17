#!/bin/zsh
# Builds "ACE Studio.app" (ad-hoc signed) into ./dist
set -e
cd "$(dirname "$0")"
swift build -c release
[ -f AppIcon.icns ] || swift tools/make_icon.swift
APP="dist/ACE Studio.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ACEStudio "$APP/Contents/MacOS/ACEStudio"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ace_writer.py "$APP/Contents/Resources/ace_writer.py"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ACE Studio</string>
<key>CFBundleDisplayName</key><string>ACE Studio</string>
<key>CFBundleIdentifier</key><string>eu.communicamp.acestudio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>ACEStudio</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict></plist>
PL
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "OK $APP"
