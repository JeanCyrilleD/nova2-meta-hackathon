#!/bin/bash
# Installe le déclencheur de build de Nova (LaunchAgent). Désinstaller :
#   launchctl unload ~/Library/LaunchAgents/com.ahadi.nova.buildwatch.plist && rm ~/Library/LaunchAgents/com.ahadi.nova.buildwatch.plist
ROOT="$HOME/spark-local/Nova2"
chmod +x "$ROOT/tools/build_watch.sh"
PL="$HOME/Library/LaunchAgents/com.ahadi.nova.buildwatch.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ahadi.nova.buildwatch</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ROOT/tools/build_watch.sh</string></array>
  <key>WatchPaths</key><array><string>$ROOT/dormant/BUILD_REQUEST</string></array>
  <key>StandardOutPath</key><string>$ROOT/dormant/buildwatch.log</string>
  <key>StandardErrorPath</key><string>$ROOT/dormant/buildwatch.log</string>
</dict>
</plist>
PLIST
launchctl unload "$PL" 2>/dev/null
launchctl load "$PL" && echo "✅ Déclencheur installé : déposer dormant/BUILD_REQUEST lance le build de Nova." || echo "❌ launchctl load a échoué"
echo "$(date) installé" > "$ROOT/dormant/buildwatch_installed.txt"
