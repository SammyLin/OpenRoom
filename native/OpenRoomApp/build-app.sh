#!/bin/bash
# 把 SPM 編出來的執行檔包成真的 .app（Dock icon、原生視窗、Info.plist 給麥克風權限）。
# ponytail: 沒用 Xcode project，一支 shell script 組 bundle 就夠——不需要為了
# 「以後也許要上架」的東西付 Xcode project 的複雜度。
#
# 三個環境變數讓 CI 能驅動同一支腳本，沒設就跟本機一模一樣：
#   VERSION                 寫進 Info.plist 的版本；預設 0.1.0
#   SIGN_IDENTITY           codesign 身分；預設 `-`（adhoc，只有本機能跑）
#   SPARKLE_PUBLIC_ED_KEY   Sparkle 驗簽章用的 EdDSA 公鑰；沒有預設值。
#                           沒設就不寫 SUPublicEDKey，這顆 app 不能自動更新。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# 刻意不給預設值。填一個看起來像金鑰的 placeholder 會讓壞掉的 build 看起來設定好了，
# 那正是這專案禁止的靜默降級——寧可整個 key 不存在，app 自己會說它不能更新。
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

swift build -c release

APP=OpenRoom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
cp .build/release/OpenRoomApp "$APP/Contents/MacOS/OpenRoom"
cp Resources/OpenRoom.icns "$APP/Contents/Resources/OpenRoom.icns"
# .lproj 要進 Contents/Resources：Localized.swift 就是先找 Bundle.main 的 en.lproj
# 才決定翻譯從哪裡拿。ditto 而不是 cp -R，framework 裡的 symlink 要原樣保留。
cp -R Sources/OpenRoomApp/Resources/*.lproj "$APP/Contents/Resources/"
# --noextattr/--noqtn：ditto 會連 com.apple.provenance 這種 xattr 一起搬過來，
# 之後 codesign 想改寫那個檔案就會拿到 Operation not permitted；公證也不收帶
# extended attribute 的 bundle。
ditto --noextattr --noqtn .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
# SPM 只給執行檔 @loader_path 一條 rpath，framework 在 Contents/Frameworks 找不到。
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/OpenRoom"

# Sparkle 的更新來源與公鑰。SUPublicEDKey 沒有就整個不寫——見上面的說明。
if [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
  ED_KEY_ENTRY="  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>"
  UPDATE_STATUS="enabled"
else
  ED_KEY_ENTRY=""
  UPDATE_STATUS="DISABLED (no SPARKLE_PUBLIC_ED_KEY)"
  echo "WARNING: SPARKLE_PUBLIC_ED_KEY is unset — writing NO SUPublicEDKey." >&2
  echo "WARNING: this build CANNOT auto-update. Sparkle has no key to verify a" >&2
  echo "WARNING: download with, so the app disables its update menu entirely." >&2
  echo "WARNING: generate one with Sparkle's generate_keys and export it." >&2
fi

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
  <key>SUFeedURL</key><string>https://sammylin.github.io/OpenRoom/appcast.xml</string>
${ED_KEY_ENTRY}
  <!-- SUEnableAutomaticChecks 刻意不寫。寫了會讓 Sparkle 跳過第一次啟動的詢問，
       等於這顆 app 沒問過使用者就開始連外找更新。預設仍然是「檢查」——只是那個
       同意由使用者自己按，不是由 Info.plist 代按。 -->
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
EOF

sign=(--force --sign "$SIGN_IDENTITY")
# hardened runtime 只在真的用 Developer ID 時加：公證要求它，但本機 adhoc 加了
# 只會擋掉 debugger attach，換不到任何東西。
[ "$SIGN_IDENTITY" = "-" ] || sign+=(--options runtime --timestamp)

# 由內往外簽。Sparkle 的 XPC services / Autoupdate / Updater.app 各自是獨立的
# 可執行檔，而 Apple 明講 --deep 不能拿來簽要送公證的東西（它會用同一組規則
# 蓋掉巢狀 bundle 自己的簽章設定）。
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for nested in "$FW/XPCServices/"*.xpc "$FW/Autoupdate" "$FW/Updater.app"; do
  if [ -e "$nested" ]; then codesign "${sign[@]}" "$nested"; fi
done
codesign "${sign[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
# entitlements 只給最外層。Sparkle 的巢狀元件不該拿到麥克風權限，而且
# hardened runtime 下少了 audio-input，使用者按了「允許」也只會收到靜音。
codesign "${sign[@]}" --entitlements OpenRoom.entitlements "$APP"
# 簽壞了要當場炸。包出一顆「看起來簽好了」但打不開的 app 是最糟的失敗方式。
codesign --verify --strict --verbose=2 "$APP"
# entitlement 掉了不會讓 codesign 失敗，只會讓麥克風在使用者手上安靜地不收音。
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | grep -q 'com.apple.security.device.audio-input' \
  || { echo "ERROR: audio-input entitlement missing from the signed bundle" >&2; exit 1; }

echo "packaged: $(pwd)/$APP (version $VERSION, identity ${SIGN_IDENTITY}, auto-update ${UPDATE_STATUS})"
