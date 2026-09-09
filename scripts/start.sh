#!/bin/bash
# HTML 可视化编辑器 — 一键启动（macOS / Linux）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/src/app"
PORT="${1:-9100}"

echo ""
echo "  =============================================="
echo "    HTML 可视化编辑器 · HTML Visual Editor"
echo "  =============================================="
echo ""
echo "  端口 Port: $PORT"
echo ""

# 找 Python
PY=""
for cand in python3.13 python3.12 python3.11 python3.10 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info[:2]>=(3,10) else 1)' 2>/dev/null; then
      PY="$cand"; break
    fi
  fi
done
if [ -z "$PY" ]; then
  echo "  [错误] 未找到 Python 3.10+"
  echo "  请安装: https://www.python.org/downloads/ 或 brew install python"
  exit 1
fi
echo "  Python: $PY ($($PY -c 'import sys; print(".".join(map(str,sys.version_info[:3])))'))"

# venv
VENV="$APP/.venv"
if [ ! -x "$VENV/bin/python3" ]; then
  echo "  创建虚拟环境…"
  "$PY" -m venv "$VENV"
fi
VPY="$VENV/bin/python3"

# 依赖
if ! "$VPY" -c "import fastapi, uvicorn, multipart" >/dev/null 2>&1; then
  echo "  安装依赖…"
  "$VPY" -m pip install -q -r "$ROOT/requirements.txt"
fi

# 释放端口
if command -v lsof >/dev/null 2>&1; then
  lsof -ti:"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.3
fi

echo "  启动服务器…"
echo "  浏览器将自动打开。按 Ctrl+C 停止。"
echo "  ------------------------------------------------"

( sleep 2; open "http://127.0.0.1:$PORT" 2>/dev/null || xdg-open "http://127.0.0.1:$PORT" 2>/dev/null || true ) &

cd "$APP"
EDITOR_PORT="$PORT" exec "$VPY" -m uvicorn server:app --host 127.0.0.1 --port "$PORT" --no-server-header
