#!/bin/bash
# HTML 可视化编辑器 · HTML Visual Editor — macOS 一键启动
chcp() { :; }
cd "$(dirname "$0")/app" || exit 1
PORT=9100

echo ""
echo "  =============================================="
echo "    HTML 可视化编辑器 · HTML Visual Editor"
echo "  =============================================="
echo ""

# 找 python3
PY=""
for cand in python3 /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
  echo "  [错误/Error] 未找到 Python 3。"
  echo "  请先安装 Python 3（终端运行：xcode-select --install，或安装 Homebrew 后 brew install python）"
  echo "  Python 3 not found. Please install Python 3 first."
  echo ""
  read -p "  按回车键退出 / Press Enter to exit... " _
  exit 1
fi

# 首次运行自动安装依赖 / auto-install deps on first run
if ! "$PY" -c "import fastapi, uvicorn, multipart" >/dev/null 2>&1; then
  echo "  [提示/Note] 首次运行，正在安装运行环境（约 20 秒）..."
  echo "  First run: installing runtime dependencies (~20s)..."
  "$PY" -m pip install --quiet --user fastapi uvicorn python-multipart 2>/dev/null || \
  "$PY" -m pip install --quiet --break-system-packages --user fastapi uvicorn python-multipart
fi

# 释放端口 / free port
lsof -ti:$PORT | xargs kill -9 2>/dev/null
sleep 0.5

echo "  [启动/Starting] 端口 port $PORT ..."
echo "  [提示/Note] 浏览器将自动打开。关闭本窗口即可停止。"
echo "  The browser will open automatically. Close this window to stop."
echo "  ------------------------------------------------"

# 3 秒后打开浏览器 / open browser after 3s
( sleep 3; open "http://127.0.0.1:$PORT" ) &

# 前台运行服务器 / run server in foreground
"$PY" -m uvicorn server:app --host 127.0.0.1 --port $PORT

echo ""
echo "  编辑器已停止。/ The editor has stopped."
read -p "  按回车键关闭窗口 / Press Enter to close... " _
