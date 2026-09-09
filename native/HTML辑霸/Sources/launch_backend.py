#!/usr/bin/env python3
"""Start the stdlib backend detached from the GUI app via launchd."""
import os
import sys
import subprocess
import time

LABEL = "local.htmleditor.backend"

def main():
    if len(sys.argv) < 4:
        sys.exit(2)
    app_root = sys.argv[1]
    python = sys.argv[2]
    port = sys.argv[3]
    log_path = sys.argv[4] if len(sys.argv) > 4 else os.path.join(app_root, "backend.log")
    pid_path = sys.argv[5] if len(sys.argv) > 5 else os.path.join(app_root, "backend.pid")

    server = os.path.join(app_root, "server_lite.py")
    if not os.path.exists(server):
        server = os.path.join(os.path.dirname(app_root), "server_lite.py")

    if os.path.exists(server):
        cmd = [python, "-u", server]
    else:
        cmd = [python, "-m", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", str(port), "--no-server-header"]

    # Remove any previous job
    subprocess.call(["launchctl", "remove", LABEL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.2)

    env = os.environ.copy()
    env["EDITOR_PORT"] = str(port)
    # launchctl submit runs the command as its own job (not a GUI child)
    submit = [
        "launchctl", "submit",
        "-l", LABEL,
        "-o", log_path,
        "-e", log_path,
        "--",
    ] + cmd
    r = subprocess.call(submit, cwd=app_root, env=env)
    if r != 0:
        # fallback: double fork
        if os.fork() > 0:
            return
        os.setsid()
        if os.fork() > 0:
            os._exit(0)
        os.chdir(app_root)
        log = open(log_path, "a")
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, cwd=app_root,
                                start_new_session=True, env=env)
        with open(pid_path, "w") as f:
            f.write(str(proc.pid))
        os._exit(0)

    # record label; stop() will launchctl remove
    with open(pid_path, "w") as f:
        f.write("launchd:" + LABEL)

if __name__ == "__main__":
    main()
