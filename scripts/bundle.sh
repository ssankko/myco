#!/bin/bash
#  Builds the package and assembles dist/Myco.driver and dist/Myco.app.
#  APP_VERSION is the version the app bundle reports. Both bundles get an ad hoc signature.
set -euo pipefail

APP_VERSION="${APP_VERSION:-0.1.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/release"
DIST="$ROOT/dist"
DRIVER="$DIST/Myco.driver"
APP="$DIST/Myco.app"

#  The driver reports its version from the C source and the app reads the bundled plist, so the
#  two must agree or an install would look up to date when it is not.
SOURCE_VERSION="$(sed -n 's/.*#define kDriverVersion  *CFSTR("\(.*\)").*/\1/p' "$ROOT/Sources/MycoDriver/Myco.c")"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Sources/MycoDriver/Info.plist")"
if [ "$SOURCE_VERSION" != "$PLIST_VERSION" ]; then
	echo "driver version mismatch: Myco.c says $SOURCE_VERSION, Info.plist says $PLIST_VERSION" >&2
	exit 1
fi

swift build -c release --package-path "$ROOT"

rm -rf "$DRIVER" "$APP"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"
cp "$BUILD/libMycoDriver.dylib" "$DRIVER/Contents/MacOS/MycoDriver"
cp "$ROOT/Sources/MycoDriver/Info.plist" "$DRIVER/Contents/Info.plist"
install_name_tool -id "@loader_path/MycoDriver" "$DRIVER/Contents/MacOS/MycoDriver"

#  The app icon is the glyph from Myco.svg in the brand mint on a deep forest tile (the colours
#  Theme.swift carries), rendered by Quick Look.
ICONSET="$(mktemp -d)/Myco.iconset"
mkdir -p "$ICONSET"
{
	echo '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 128 128">'
	echo '<rect x="13" y="13" width="102" height="102" rx="24" fill="#173B30"/>'
	echo '<g transform="translate(20.8 20.8) scale(0.9)" fill="#C5F4D4">'
	sed -e '/<svg/d' -e '/<title>/d' -e '/<\/svg>/d' "$ROOT/Sources/Myco/Myco.svg"
	echo '</g></svg>'
} > "$ICONSET/../Myco.svg"
qlmanage -t -s 1024 -o "$ICONSET/.." "$ICONSET/../Myco.svg" > /dev/null 2>&1
for SIZE in 16 32 128 256 512; do
	sips -z "$SIZE" "$SIZE" "$ICONSET/../Myco.svg.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
	sips -z "$((SIZE * 2))" "$((SIZE * 2))" "$ICONSET/../Myco.svg.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$DRIVER/Contents/Resources/Myco.icns"
codesign --force --sign - "$DRIVER"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Myco" "$APP/Contents/MacOS/Myco"
cp -R "$BUILD/Myco_Myco.bundle" "$APP/Contents/Resources/"
cp "$DRIVER/Contents/Resources/Myco.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Myco</string>
	<key>CFBundleIconFile</key>
	<string>Myco</string>
	<key>CFBundleIdentifier</key>
	<string>com.ssankko.myco</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Myco</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Myco reads your microphones so it can mix them into one input device.</string>
</dict>
</plist>
PLIST
cp -R "$DRIVER" "$APP/Contents/Resources/Myco.driver"
codesign --force --sign - "$APP"

echo "built $DRIVER and $APP"
