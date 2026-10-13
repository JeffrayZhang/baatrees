#!/bin/zsh
# builds Baa, starts it at login, and puts the `baa` command on your PATH
set -e
cd "${0:A:h}"
./build.sh

AGENT=~/Library/LaunchAgents/com.selvi.baa.plist
cat > $AGENT <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.selvi.baa</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/Baa.app/Contents/MacOS/Baa</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/tmp/baa.err</string>
</dict>
</plist>
PLIST
launchctl bootout gui/$(id -u)/com.selvi.baa 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $AGENT
launchctl kickstart -k gui/$(id -u)/com.selvi.baa

mkdir -p ~/.local/bin
printf '#!/bin/zsh\nexec ~/Applications/Baa.app/Contents/MacOS/Baa "${@:---now}"\n' > ~/.local/bin/baa
chmod +x ~/.local/bin/baa
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || echo "add ~/.local/bin to your PATH to use the baa command"
echo "🐏 baa is running in your menu bar"
