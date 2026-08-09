#!/bin/bash
# 把 SPM 編出來的執行檔包成真的 .app（Dock icon、原生視窗、Info.plist 給麥克風權限）。
# ponytail: 沒用 Xcode project，一支 shell script 組 bundle 就夠——不需要為了
# 「以後也許要上架」的東西付 Xcode project 的複雜度。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=OpenRoom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OpenRoomApp "$APP/Contents/MacOS/OpenRoom"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenRoom</string>
  <key>CFBundleDisplayName</key><string>OpenRoom</string>
  <key>CFBundleIdentifier</key><string>ai.openroom.app</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>OpenRoom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSMicrophoneUsageDescription</key><string>麥克風來源要收音才轉逐字稿。</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
echo "packaged: $(pwd)/$APP"
