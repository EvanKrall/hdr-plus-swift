#!/bin/bash
# Manual build of the burstphoto CLI (workaround: xcodebuild is broken on this machine).
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build_manual
APP="$BUILD/cli.app"
OBJ="$BUILD/obj"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCH=arm64
MIND=11.0
DEFS="-DqDispatchQueueManager=0 -DqMacOS=1 -DqWinOS=0 -DqDNGUseStdInt=1 -DMacintosh=1 -DMAC_ENV=1 -DBIB_MULTI_THREAD=1 \
-DENABLE_CPP_DOM_MODEL=0 -DXML_STATIC=1 -DHAVE_EXPAT_CONFIG_H=1 -DXMP_StaticBuild=1 -DXMP_64=1 \
-DqDNGDebug=0 -DqDNGValidate=1 -DqDNGValidateTarget=1 -DqDNGUseLibJPEG=1"
INC="-Idng_sdk/dng_sdk -Idng_sdk/libjpeg -Idng_sdk/xmp_headers -Iburstphoto/io_dng"

echo "== compiling C++ (dng_sdk) =="
find dng_sdk/dng_sdk -name '*.cpp' -not -name 'dng_validate.cpp' > "$BUILD/cxx.list"
echo burstphoto/io_dng/dng_sdk_wrapper.cpp >> "$BUILD/cxx.list"
while read -r f; do
  ( clang++ -arch $ARCH -mmacosx-version-min=$MIND -std=c++0x -stdlib=libc++ -O1 $DEFS $INC -c "$f" -o "$OBJ/cxx-$(basename "$f").o" ) &
  while [ "$(jobs -rp | wc -l)" -ge 8 ]; do sleep 0.2; done
done < "$BUILD/cxx.list"
wait
echo "== compiling C (libjpeg) =="
for f in dng_sdk/libjpeg/*.c; do
  ( clang -arch $ARCH -mmacosx-version-min=$MIND -O1 $DEFS $INC -c "$f" -o "$OBJ/c-$(basename "$f").o" ) &
  while [ "$(jobs -rp | wc -l)" -ge 8 ]; do sleep 0.2; done
done
wait

echo "== compiling Swift =="
SWIFT_SRCS="
burstphoto/cli.swift
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
burstphoto/misc/selftest.swift
burstphoto/viz/visualize.swift
burstphoto/inspect/inspect.swift
"
swiftc -O -swift-version 5 -target $ARCH-apple-macos$MIND \
  -import-objc-header burstphoto/io_dng/bridging_header.h $INC \
  $SWIFT_SRCS \
  $OBJ/*.o \
  -o "$APP/Contents/MacOS/burstphoto-cli" \
  -Ldng_sdk/xmp_lib -lXMPFilesStaticRelease -lXMPCoreStaticRelease -lc++

echo "== bundling =="
cp burstphoto/align/align.metal burstphoto/texture/texture.metal burstphoto/exposure/exposure.metal \
   burstphoto/merge/spatial.metal burstphoto/merge/frequency.metal burstphoto/viz/visualize.metal \
   burstphoto/misc/constants.h "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>burstphoto-cli</string>
    <key>CFBundleIdentifier</key><string>photo.burst.cli</string>
    <key>CFBundleName</key><string>cli</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign -s - --force "$APP" 2>/dev/null || true

echo "done: $APP/Contents/MacOS/burstphoto-cli"
