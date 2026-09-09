#!/bin/bash
# 安装 HTML 可视化编辑器 为 macOS App（~/Applications）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HTML可视化编辑器"
DEST="$HOME/Applications/$APP_NAME.app"
RES="$DEST/Contents/Resources"
MACOS="$DEST/Contents/MacOS"

echo ""
echo "  安装 $APP_NAME → $DEST"
echo ""

rm -rf "$DEST"
mkdir -p "$RES" "$MACOS"

cp -R "$ROOT/src/app" "$RES/app"
cp "$ROOT/requirements.txt" "$RES/"
rm -rf "$RES/app/__pycache__" "$RES/app/.venv" 2>/dev/null || true

cat > "$MACOS/launcher" << 'LAUNCH'
#!/bin/bash
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
APP="$RES/app"
PORT="${EDITOR_PORT:-9100}"

PY=""
for cand in python3.13 python3.12 python3.11 python3.10 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info[:2]>=(3,10) else 1)' 2>/dev/null; then
      PY="$cand"; break
    fi
  fi
done
if [ -z "$PY" ]; then
  osascript -e 'display dialog "未找到 Python 3.10+，请先安装 Python。" buttons {"好"} default button 1 with icon stop' 2>/dev/null || true
  exit 1
fi

VENV="$APP/.venv"
if [ ! -x "$VENV/bin/python3" ]; then
  "$PY" -m venv "$VENV" || exit 1
fi
VPY="$VENV/bin/python3"
if ! "$VPY" -c "import fastapi, uvicorn, multipart" >/dev/null 2>&1; then
  "$VPY" -m pip install -q -r "$RES/requirements.txt" || exit 1
fi

lsof -ti:"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 0.3

cd "$APP"
if [ -x "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" ] || [ -x "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" ]; then
  osascript <<EOF
tell application "Terminal"
  activate
  do script "cd '$APP' && EDITOR_PORT=$PORT '$VPY' -m uvicorn server:app --host 127.0.0.1 --port $PORT --no-server-header"
end tell
EOF
else
  EDITOR_PORT="$PORT" "$VPY" -m uvicorn server:app --host 127.0.0.1 --port "$PORT" --no-server-header &
fi

for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    open "http://127.0.0.1:$PORT"
    exit 0
  fi
  sleep 0.4
done
open "http://127.0.0.1:$PORT"
LAUNCH
chmod +x "$MACOS/launcher"

cat > "$DEST/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>local.htmleditor.v4</string>
  <key>CFBundleVersion</key>
  <string>4.1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>4.1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>launcher</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSUIElement</key>
  <false/>
</dict>
</plist>
PLIST

LOGO="$ROOT/src/app/static/assets/logo.png"
if [ -f "$LOGO" ]; then
  cp "$LOGO" "$RES/AppIcon.png" 2>/dev/null || true
fi

xattr -cr "$DEST" 2>/dev/null || true

echo "  OK installed: $DEST"
echo ""
echo "  启动方式：双击「$APP_NAME」，或在启动台搜索。"
echo "  首次启动会安装依赖（约 20 秒），之后秒开。"
echo ""
