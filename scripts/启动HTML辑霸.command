#!/bin/bash
# HTML辑霸 — 双击启动（经 Terminal，绕过 LaunchServices 对 POST 的限制）
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/HTML辑霸.app"
BIN="$APP/Contents/MacOS/HTML辑霸"
if [ ! -x "$BIN" ]; then
  # fallback to dist
  BIN="$DIR/dist/HTML辑霸.app/Contents/MacOS/HTML辑霸"
fi
echo ""
echo "  启动 HTML辑霸 …"
echo "  本窗口是引擎控制台，关闭窗口 = 退出编辑器。"
echo ""
JIBA_REEXEC=1 exec "$BIN"
