#!/bin/bash
# HTML 可视化编辑器 — 双击启动（等价于 scripts/start.sh）
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/start.sh" "$@"
