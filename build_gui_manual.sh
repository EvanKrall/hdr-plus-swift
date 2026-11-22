#!/bin/bash
# Manual build of the burstphoto GUI app (workaround: xcodebuild is broken on this machine).
# Requires ./build_cli_manual.sh to have been run once (reuses its compiled C/C++ objects).
# Note: the asset catalog cannot be compiled (actool is broken too), so the drop icon is
# rasterized from its SVG via qlmanage and placed as a loose resource; the custom SF Symbols
# in the Preferences tabs are not available in this build (cosmetic only).
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build_manual
APP="$BUILD/burstphoto.app"
OBJ="$BUILD/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -f "$OBJ/cxx-dng_negative.cpp.o" ]; then
  echo "C/C++ objects missing - run ./build_cli_manual.sh first"
  exit 1
fi

ARCH=arm64
MIND=11.0
INC="-Idng_sdk/dng_sdk -Idng_sdk/libjpeg -Idng_sdk/xmp_headers -Iburstphoto/io_dng"

echo "== compiling Swift (gui) =="
SWIFT_SRCS="
burstphoto/App.swift
burstphoto/ContentView.swift
burstphoto/inspect/AlignmentInspectorView.swift
burstphoto/denoise.swift
burstphoto/align/align.swift
burstphoto/burst/autoburst.swift
burstphoto/burst/stack_record.swift
burstphoto/merge/spatial.swift
burstphoto/merge/frequency.swift
burstphoto/texture/texture.swift
burstphoto/exposure/exposure.swift
burstphoto/io_dng/io_dng_sdk.swift
burstphoto/misc/helpers.swift
burstphoto/viz/visualize.swift
burstphoto/inspect/inspect.swift
"
swiftc -O -swift-version 5 -target $ARCH-apple-macos$MIND \
  -import-objc-header burstphoto/io_dng/bridging_header.h $INC \
  $SWIFT_SRCS \
  "$OBJ"/*.o \
  -o "$APP/Contents/MacOS/burstphoto" \
  -Ldng_sdk/xmp_lib -lXMPFilesStaticRelease -lXMPCoreStaticRelease -lc++

echo "== bundling =="
cp burstphoto/align/align.metal burstphoto/texture/texture.metal burstphoto/exposure/exposure.metal \
   burstphoto/merge/spatial.metal burstphoto/merge/frequency.metal burstphoto/viz/visualize.metal \
   burstphoto/misc/constants.h "$APP/Contents/Resources/"

# rasterize the drop icon (NSImage(named:) falls back to loose bundle resources)
if command -v qlmanage >/dev/null; then
  qlmanage -t -s 512 -o "$BUILD" burstphoto/Assets.xcassets/drop_icon.imageset/drop_icon.svg >/dev/null 2>&1 || true
  if [ -f "$BUILD/drop_icon.svg.png" ]; then
    cp "$BUILD/drop_icon.svg.png" "$APP/Contents/Resources/drop_icon.png"
  fi
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>burstphoto</string>
    <key>CFBundleIdentifier</key><string>photo.burst.burstphoto</string>
    <key>CFBundleName</key><string>Burst Photo</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign -s - --force "$APP" 2>/dev/null || true

echo "done: $APP — launch with: open $APP"
