#!/bin/bash
# DockTube 빌드 스크립트 — 사용법: bash build.sh       (앱만)
#                                   bash build.sh dmg   (배포용 DockTube.dmg까지)
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
# 애플 실리콘 + 인텔 맥 둘 다 돌아가게 합쳐서 빌드
TMP="$(mktemp -d)"
swiftc -O -target arm64-apple-macos12  DockTube.swift -o "$TMP/arm64"
swiftc -O -target x86_64-apple-macos12 DockTube.swift -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/DockTube"
rm -rf "$TMP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

touch "$APP"
echo "완료! 실행하려면:  open DockTube.app"

# 배포용 DMG: 열면 DockTube와 응용 프로그램 폴더가 보여서 끌어다 놓으면 설치돼요
if [ "$1" = "dmg" ]; then
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f DockTube.dmg
  hdiutil create -volname DockTube -srcfolder "$STAGE" -ov -format UDZO DockTube.dmg >/dev/null
  rm -rf "$STAGE"
  echo "배포 파일:  DockTube.dmg"
fi
