#!/bin/sh
# Builds build/Flipkey.app (Apple Silicon + Intel, macOS 13+) and build/Flipkey-<version>.zip.
set -e
VERSION=${1:-0.1}
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/iconset.iconset
APP=build/Flipkey.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources

swiftc -Onone -o build/selftest main.swift && build/selftest --selftest
for arch in arm64 x86_64; do swiftc -O -target $arch-apple-macos13 -o build/flipkey-$arch main.swift; done
lipo -create -output $APP/Contents/MacOS/Flipkey build/flipkey-arm64 build/flipkey-x86_64

swiftc -o build/render scripts/render.swift
for s in 16 32 128 256 512; do
  build/render logo.svg build/iconset.iconset/icon_${s}x${s}.png $s $s
  build/render logo.svg build/iconset.iconset/icon_${s}x${s}@2x.png $((s * 2)) $((s * 2))
done
iconutil -c icns -o $APP/Contents/Resources/AppIcon.icns build/iconset.iconset
build/render MenuBarIcon.svg $APP/Contents/Resources/MenuBarIcon.png 30 18
build/render MenuBarIcon.svg $APP/Contents/Resources/MenuBarIcon@2x.png 60 36

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Flipkey</string>
  <key>CFBundleIdentifier</key><string>com.puchkoff.flipkey</string>
  <key>CFBundleExecutable</key><string>Flipkey</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signatures change every build.
IDENTITY=$(security find-identity -p codesigning | grep -q '"Flipkey Dev"' && echo "Flipkey Dev" || echo -)
codesign --force --sign "$IDENTITY" $APP
ditto -c -k --keepParent $APP build/Flipkey-$VERSION.zip
echo "Built $APP and build/Flipkey-$VERSION.zip"
