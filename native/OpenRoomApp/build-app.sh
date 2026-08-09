#!/bin/bash
# 把 SPM 編出來的執行檔包成真的 .app（Dock icon、原生視窗、Info.plist 給麥克風權限）。
# ponytail: 沒用 Xcode project，一支 shell script 組 bundle 就夠——不需要為了
# 「以後也許要上架」的東西付 Xcode project 的複雜度。
#
# 兩個環境變數讓 CI 能驅動同一支腳本，沒設就跟本機一模一樣：
#   VERSION        寫進 Info.plist 的版本；預設 0.1.0
#   SIGN_IDENTITY  codesign 身分；預設 `-`（adhoc，只有本機能跑）
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release

APP=OpenRoom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/release/OpenRoomApp "$APP/Contents/MacOS/OpenRoom"
cp Resources/OpenRoom.icns "$APP/Contents/Resources/OpenRoom.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenRoom</string>
  <key>CFBundleDisplayName</key><string>OpenRoom</string>
  <key>CFBundleIdentifier</key><string>ai.openroom.app</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key><string>OpenRoom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>OpenRoom.icns</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSMicrophoneUsageDescription</key><string>麥克風來源要收音才轉逐字稿。</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

sign=(--force --deep --sign "$SIGN_IDENTITY")
# hardened runtime 只在真的用 Developer ID 時加：公證要求它，但本機 adhoc 加了
# 只會擋掉 debugger attach，換不到任何東西。
[ "$SIGN_IDENTITY" = "-" ] || sign+=(--options runtime --timestamp)
codesign "${sign[@]}" "$APP"
# 簽壞了要當場炸。包出一顆「看起來簽好了」但打不開的 app 是最糟的失敗方式。
codesign --verify --strict --verbose=2 "$APP"

echo "packaged: $(pwd)/$APP (version $VERSION, identity ${SIGN_IDENTITY})"
