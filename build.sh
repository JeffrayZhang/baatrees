#!/bin/zsh
# builds Baa.app into ~/Applications and restarts it
set -e
cd "${0:A:h}"
APP=build/Baa.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" -o $APP/Contents/MacOS/Baa Sources/main.swift
cp Info.plist $APP/Contents/
mkdir -p $APP/Contents/Resources && cp icon/AppIcon.icns sounds/baa.wav $APP/Contents/Resources/
codesign --force -s - $APP
mkdir -p ~/Applications && rm -rf ~/Applications/Baa.app && cp -R $APP ~/Applications/
launchctl kickstart -k gui/$(id -u)/com.selvi.baa 2>/dev/null || true
echo "built ~/Applications/Baa.app"
