#!/bin/bash
# Install LaunchAgent for HTML辑霸 backend (independent of GUI app attribution)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/HTML辑霸.app"
RES="$APP/Contents/Resources"
AGENT="$HOME/Library/LaunchAgents/local.htmleditor.jiba.plist"
LABEL="local.htmleditor.jiba"
PORT="${EDITOR_PORT:-9100}"

# find python
PY=""
for c in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -x "$c" ] && PY="$c" && break
done
[ -z "$PY" ] && { echo "no python"; exit 1; }

mkdir -p "$HOME/Library/Logs/HTML辑霸"

cat > "$AGENT" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PY}</string>
    <string>-u</string>
    <string>${RES}/app/server_lite.py</string>
  </array>
  <key>WorkingDirectory</key><string>${RES}/app</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>EDITOR_PORT</key><string>${PORT}</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/HTML辑霸/backend.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/HTML辑霸/backend.log</string>
</dict>
</plist>
PLIST

# reload
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl load "$AGENT" 2>/dev/null || true
echo "LaunchAgent installed: $AGENT"
