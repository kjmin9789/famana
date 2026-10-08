#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Famana.app"
mkdir -p "$APP/Contents/MacOS"
FLAGS=()
SWIFT_INCLUDE="$(dirname "$(xcrun --find swiftc)")/../include/swift"
if [ -f "$SWIFT_INCLUDE/module.modulemap" ] && [ -f "$SWIFT_INCLUDE/bridging.modulemap" ] &&
   /usr/bin/grep -q '^module SwiftBridging {' "$SWIFT_INCLUDE/module.modulemap" &&
   /usr/bin/grep -q '^module SwiftBridging {' "$SWIFT_INCLUDE/bridging.modulemap"; then
    # Old CLT updates can leave two identical SwiftBridging definitions.
    # Hide the obsolete map for this build only; never change the system toolchain.
    SWIFT_INCLUDE="$(cd "$SWIFT_INCLUDE" && pwd)"
    touch build/empty.modulemap
    cat > build/swift-overlay.yaml <<EOF
{"version":0,"roots":[{"type":"file","name":"$SWIFT_INCLUDE/module.modulemap","external-contents":"$PWD/build/empty.modulemap"}]}
EOF
    FLAGS=(-vfsoverlay "$PWD/build/swift-overlay.yaml")
fi
xcrun swiftc ${FLAGS[@]+"${FLAGS[@]}"} Sources/*.swift -o "$APP/Contents/MacOS/Famana" -framework Cocoa -framework ApplicationServices -framework AVFoundation
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.min.PrefixTag</string>
<key>CFBundleName</key><string>Famana</string>
<key>CFBundleExecutable</key><string>Famana</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppleEventsUsageDescription</key><string>Finder의 선택 파일과 QuickTime Player의 영상 재생 위치를 확인해 이름 변경 및 장면 이미지 저장에 사용합니다.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/Famana" --self-test
printf 'Built: %s\n' "$APP"
