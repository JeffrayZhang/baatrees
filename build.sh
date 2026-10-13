#!/bin/zsh
# builds Baa.app into ~/Applications and restarts it
set -e
cd "${0:A:h}"
APP=build/Baa.app
INSTALLED=$HOME/Applications/Baa.app
BINARY=$INSTALLED/Contents/MacOS/Baa
AGENT=$HOME/Library/LaunchAgents/com.selvi.baa.plist
SERVICE=gui/$(id -u)/com.selvi.baa
rm -rf $APP && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" -o $APP/Contents/MacOS/Baa Sources/main.swift
cp Info.plist $APP/Contents/
mkdir -p $APP/Contents/Resources && cp icon/AppIcon.icns sounds/baa.wav $APP/Contents/Resources/
codesign --force -s - $APP

# Stop the login service before replacing its executable, then stop any copy
# launched directly. Otherwise the old process can keep a second menu item.
managed=0
if launchctl print "$SERVICE" >/dev/null 2>&1; then
  managed=1
  launchctl bootout "$SERVICE"
fi
was_running=0
if /usr/bin/pgrep -u "$(id -u)" -f -x "$BINARY" >/dev/null; then
  was_running=1
  /usr/bin/pkill -TERM -u "$(id -u)" -f -x "$BINARY" || true
  for attempt in {1..20}; do
    /usr/bin/pgrep -u "$(id -u)" -f -x "$BINARY" >/dev/null || break
    sleep 0.1
  done
  if /usr/bin/pgrep -u "$(id -u)" -f -x "$BINARY" >/dev/null; then
    if (( managed )); then
      launchctl bootstrap "gui/$(id -u)" "$AGENT"
      launchctl kickstart -k "$SERVICE"
    fi
    echo "could not stop the old Baa process" >&2
    exit 1
  fi
fi

mkdir -p ~/Applications && rm -rf "$INSTALLED" && cp -R "$APP" ~/Applications/
if (( managed )); then
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
  launchctl kickstart -k "$SERVICE"
elif (( was_running )); then
  open -a "$INSTALLED"
fi
echo "built $INSTALLED"
