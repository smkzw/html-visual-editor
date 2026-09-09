#!/usr/bin/env python3
"""
HTML 可视化编辑器 V4 — 跨平台一键启动器
macOS / Windows / Linux 通用，双击或命令行运行均可。

用法:
    python launcher.py [port]     # 默认 9100
    双击 启动编辑器.command (macOS) 或 启动编辑器.bat (Windows)
"""
import os
import sys
import signal
import socket
import subprocess
import time
import webbrowser
from pathlib import Path

# ── 常量 ──────────────────────────────────────────────
APP_NAME = "HTML 可视化编辑器 V4"
DEFAULT_PORT = 9100
VENV_DIR = Path(__file__).parent / ".venv"
REQUIREMENTS = Path(__file__).parent / "requirements.txt"
SERVER_MODULE = "server:app"
HOST = "127.0.0.1"

# ── 工具函数 ──────────────────────────────────────────

def banner(msg: str):
    print(f"\n  {msg}\n")

def info(msg: str):
    print(f"  · {msg}")

def ok(msg: str):
    print(f"  ✓ {msg}")

def fail(msg: str):
    print(f"  ✗ {msg}")

def find_python() -> str:
    """找到可用的 Python 3.10+ 解释器"""
    candidates = []
    # 1. 已有 venv
    venv_py = VENV_DIR / ("Scripts/python.exe" if os.name == "nt" else "bin/python3")
    if venv_py.exists():
        return str(venv_py)
    # 2. 系统 Python
    for name in ["python3.13", "python3.12", "python3.11", "python3.10", "python3", "python"]:
        candidates.append(name)
    if os.name == "nt":
        candidates.append("py")  # Windows launcher
    for c in candidates:
        try:
            r = subprocess.run([c, "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                try:
                    parts = r.stdout.strip().split(".")
                    ver = (int(parts[0]), int(parts[1]))
                except (ValueError, IndexError):
                    continue
                if ver >= (3, 10):
                    return c
        except (FileNotFoundError, subprocess.TimeoutExpired, SyntaxError):
            continue
    return ""

def ensure_venv(py: str) -> str:
    """确保 venv 存在并返回 venv 内的 python 路径"""
    venv_py = VENV_DIR / ("Scripts/python.exe" if os.name == "nt" else "bin/python3")
    if venv_py.exists():
        return str(venv_py)
    info("首次运行，创建虚拟环境...")
    subprocess.run([py, "-m", "venv", str(VENV_DIR)], check=True)
    ok(f"虚拟环境已创建: {VENV_DIR}")
    return str(venv_py)

def ensure_deps(venv_py: str):
    """安装/更新依赖"""
    try:
        r = subprocess.run([venv_py, "-c", "import fastapi, uvicorn"],
                           capture_output=True, timeout=10)
        if r.returncode == 0:
            return  # 已安装
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    info("安装依赖 (fastapi, uvicorn)...")
    env = os.environ.copy()
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    subprocess.run([venv_py, "-m", "pip", "install", "-r", str(REQUIREMENTS), "-q"],
                   check=True, env=env)
    ok("依赖安装完成")

def port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind((HOST, port))
            return True
        except OSError:
            return False

def kill_port(port: int):
    """跨平台杀掉占用端口的进程"""
    if os.name == "nt":
        try:
            r = subprocess.run(["netstat", "-ano", "-p", "TCP"],
                               capture_output=True, text=True)
            for line in r.stdout.splitlines():
                if f":{port}" in line and "LISTENING" in line:
                    pid = line.strip().split()[-1]
                    subprocess.run(["taskkill", "/F", "/PID", pid],
                                   capture_output=True)
        except FileNotFoundError:
            pass
    else:
        try:
            r = subprocess.run(["lsof", "-ti", f":{port}"],
                               capture_output=True, text=True)
            for pid in r.stdout.strip().splitlines():
                os.kill(int(pid), signal.SIGKILL)
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass

def wait_ready(port: int, timeout: float = 15) -> bool:
    """等待服务器就绪"""
    import urllib.request
    url = f"http://{HOST}:{port}/"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=1)
            return True
        except Exception:
            time.sleep(0.3)
    return False

# ── 主流程 ────────────────────────────────────────────

def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass

    banner(f"🎨 {APP_NAME}")
    info(f"端口: {port}")
    info(f"目录: {Path(__file__).parent.resolve()}")
    print()

    # 1. 找 Python
    py = find_python()
    if not py:
        fail("未找到 Python 3.10+，请先安装: https://www.python.org/downloads/")
        input("\n  按回车键退出...")
        sys.exit(1)
    info(f"Python: {py}")

    # 2. venv + 依赖
    venv_py = ensure_venv(py)
    ensure_deps(venv_py)

    # 3. 端口冲突处理
    if not port_free(port):
        info(f"端口 {port} 被占用，正在释放...")
        kill_port(port)
        time.sleep(0.5)
        if not port_free(port):
            fail(f"端口 {port} 仍被占用，请手动关闭或指定其他端口: python launcher.py 9200")
            input("\n  按回车键退出...")
            sys.exit(1)

    # 4. 启动服务器（清除 PYTHONPATH 防止外部 venv 污染）
    info("启动服务器...")
    env = os.environ.copy()
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    env["EDITOR_PORT"] = str(port)  # P2-2: CSRF 白名单从 EDITOR_PORT 派生
    server = subprocess.Popen(
        [venv_py, "-m", "uvicorn", SERVER_MODULE, "--host", HOST, "--port", str(port), "--no-server-header"],
        cwd=str(Path(__file__).parent),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
    )

    # 5. 等待就绪
    if wait_ready(port):
        ok(f"服务器已就绪: http://{HOST}:{port}")
    else:
        fail("服务器启动超时，请检查日志")
        server.kill()
        input("\n  按回车键退出...")
        sys.exit(1)

    # 6. 打开浏览器
    webbrowser.open(f"http://{HOST}:{port}")
    ok("浏览器已打开")

    # 7. 优雅退出
    banner("按 Ctrl+C 停止服务器")
    try:
        server.wait()
    except KeyboardInterrupt:
        print()
        info("正在停止...")
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        ok("已停止，再见 👋")

if __name__ == "__main__":
    main()
