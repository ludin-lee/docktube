#!/bin/bash
# DockTube 빌드 스크립트 — 사용법: bash build.sh
set -e
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "개발 도구가 없어요. 아래 명령을 먼저 실행해 설치한 뒤 다시 시도해 주세요:"
  echo "  xcode-select --install"
  exit 1
fi

APP="DockTube.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DockTube</string>
  <key>CFBundleDisplayName</key><string>DockTube</string>
  <key>CFBundleIdentifier</key><string>local.docktube</string>
  <key>CFBundleExecutable</key><string>DockTube</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

echo "빌드 중…"
swiftc -O DockTube.swift -o "$APP/Contents/MacOS/DockTube"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

touch "$APP"
echo "완료! 실행하려면:  open DockTube.app"
