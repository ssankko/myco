#!/bin/bash
#  Builds the package and assembles dist/Mixanimo.driver and dist/Mixanimo.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/release"
DIST="$ROOT/dist"
DRIVER="$DIST/Mixanimo.driver"
APP="$DIST/Mixanimo.app"

#  The driver reports its version from the C source and the app reads the bundled plist, so the
#  two must agree or an install would look up to date when it is not.
SOURCE_VERSION="$(sed -n 's/.*#define kDriverVersion  *CFSTR("\(.*\)").*/\1/p' "$ROOT/Sources/MixanimoDriver/Mixanimo.c")"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Sources/MixanimoDriver/Info.plist")"
if [ "$SOURCE_VERSION" != "$PLIST_VERSION" ]; then
	echo "driver version mismatch: Mixanimo.c says $SOURCE_VERSION, Info.plist says $PLIST_VERSION" >&2
	exit 1
fi

swift build -c release --package-path "$ROOT"

rm -rf "$DRIVER" "$APP"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"
cp "$BUILD/libMixanimoDriver.dylib" "$DRIVER/Contents/MacOS/MixanimoDriver"
cp "$ROOT/Sources/MixanimoDriver/Info.plist" "$DRIVER/Contents/Info.plist"
install_name_tool -id "@loader_path/MixanimoDriver" "$DRIVER/Contents/MacOS/MixanimoDriver"
codesign --force --sign - "$DRIVER"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Mixanimo" "$APP/Contents/MacOS/Mixanimo"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Mixanimo</string>
	<key>CFBundleIdentifier</key>
	<string>com.mixanimo.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Mixanimo</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Mixanimo reads your microphones so it can mix them into one input device.</string>
</dict>
</plist>
PLIST
cp -R "$DRIVER" "$APP/Contents/Resources/Mixanimo.driver"
codesign --force --sign - "$APP"

echo "built $DRIVER and $APP"
