#!/bin/zsh
# 编译薰子桌宠，装到 ~/Applications/薰子.app
set -e
cd "$(dirname "$0")"
APP=build/薰子.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/Kaoruko" -framework AppKit -framework ServiceManagement
cp -R Resources/frames "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
VERSION=$(cat VERSION)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>薰子</string>
  <key>CFBundleDisplayName</key><string>薰子</string>
  <key>CFBundleIdentifier</key><string>com.emma.kaoruko-pet</string>
  <key>CFBundleExecutable</key><string>Kaoruko</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>薰子要读 Documents/forai/额度记录.csv，额度变化时提醒你。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
if [ "$1" = "install" ]; then
  pkill -x Kaoruko 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/薰子.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/薰子.app
  echo "已安装并启动 ~/Applications/薰子.app（版本 $VERSION）"
else
  echo "已编译 $APP（版本 $VERSION）"
fi
