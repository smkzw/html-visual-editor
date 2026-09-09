#!/usr/bin/env python3
"""HTML辑霸 stdlib backend — no FastAPI/BaseHTTPMiddleware.

Avoids a stall where POST bodies hang when the server is launched from a GUI app.
Stdlib only: http.server + json + pathlib.
"""
from __future__ import annotations

import json
import mimetypes
import os
import re
import socket
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

PORT = int(os.environ.get("EDITOR_PORT", "9100"))
HOME = Path.home().resolve()

PROJECT_EXTS = {".html", ".htm", ".css", ".js", ".json", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".woff", ".woff2", ".ttf"}
EDITABLE_EXTS = {".html", ".htm", ".css", ".js", ".json", ".svg"}
BLOCKED_DIRS = {".ssh", ".aws", ".gnupg", ".kube", ".config", ".npm", ".cache", "__pycache__", "node_modules", ".git", "venv", ".venv", ".tox", ".mypy_cache", "library", ".local", ".trash"}
SENSITIVE = {".env", ".gitignore", ".npmrc", ".ds_store", "id_rsa", "id_ed25519", ".zsh_history", ".bash_history", ".netrc", ".gitconfig", ".git-credentials", ".profile"}

_state = {"root": None, "token": None}
_lock = threading.Lock()
_preview: dict[str, tuple[str, float]] = {}
_save_locks: dict[str, threading.Lock] = {}

STATIC_DIR = Path(__file__).resolve().parent / "static"


def _json(h: "Handler", code: int, obj, extra_headers=None):
    data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    h.send_response(code)
    h.send_header("Content-Type", "application/json; charset=utf-8")
    h.send_header("Content-Length", str(len(data)))
    h.send_header("X-Content-Type-Options", "nosniff")
    h.send_header("Cache-Control", "no-store")
    if extra_headers:
        for k, v in extra_headers.items():
            h.send_header(k, v)
    h.end_headers()
    h.wfile.write(data)


def _read_body(h: "Handler"):
    n = int(h.headers.get("Content-Length") or 0)
    if n <= 0:
        return {}
    if n > 20 * 1024 * 1024:
        raise ValueError("body too large")
    raw = h.rfile.read(n)
    return json.loads(raw.decode("utf-8") or "{}")


def _csrf_ok(h: "Handler") -> bool:
    if h.command in ("GET", "HEAD", "OPTIONS"):
        return True
    host = h.headers.get("Host") or ""
    allowed = {f"127.0.0.1:{PORT}", f"localhost:{PORT}", f"[::1]:{PORT}"}
    if host not in allowed:
        return False
    xrw = h.headers.get("X-Requested-With") or ""
    origin = h.headers.get("Origin") or ""
    referer = h.headers.get("Referer") or ""
    if origin or referer:
        return True
    return bool(xrw)


def _safe_resolve(raw: str) -> Path:
    if "\x00" in raw:
        raise ValueError("bad path")
    p = Path(raw).expanduser()
    if not p.is_absolute():
        p = Path(__file__).resolve().parent / p
    return p.resolve()


def _in_home(p: Path) -> bool:
    try:
        return p.resolve().is_relative_to(HOME)
    except Exception:
        return False


def _token_ok(h: "Handler") -> bool:
    tok = _state["token"]
    if not tok:
        return True
    got = h.headers.get("X-Project-Token") or ""
    cookie = h.headers.get("Cookie") or ""
    if not got and "project_token=" in cookie:
        m = re.search(r"project_token=([^;]+)", cookie)
        if m:
            got = m.group(1)
    return got == tok


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HTMLJiba/4.2"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _cors_no(self):
        pass

    def do_GET(self):
        try:
            self._get()
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                _json(self, 500, {"detail": str(e)})
            except Exception:
                pass

    def do_POST(self):
        try:
            if not _csrf_ok(self):
                _json(self, 403, {"detail": "CSRF"})
                return
            self._post()
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                _json(self, 500, {"detail": str(e)})
            except Exception:
                pass

    def _get(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            return self._file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
        if path == "/favicon.ico":
            return self._file(STATIC_DIR / "favicon.ico", "image/x-icon")
        if path == "/api/info":
            return _json(self, 200, {"platform": "windows" if os.name == "nt" else "macos", "native_picker": True})
        if path.startswith("/static/"):
            rel = path[len("/static/"):]
            fp = (STATIC_DIR / rel).resolve()
            if not str(fp).startswith(str(STATIC_DIR.resolve())):
                return _json(self, 403, {"detail": "forbidden"})
            mime = mimetypes.guess_type(str(fp))[0] or "application/octet-stream"
            return self._file(fp, mime)
        if path.startswith("/api/live/"):
            return self._live(path[len("/api/live/"):])
        if path.startswith("/api/preview/"):
            tok = path.split("/")[-1].replace(".html", "")
            entry = _preview.get(tok)
            if not entry:
                return _json(self, 403, {"detail": "预览无效或已过期"})
            data = entry[0].encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        _json(self, 404, {"detail": "not found"})

    def _post(self):
        path = urlparse(self.path).path
        body = _read_body(self)
        if path == "/api/project/open":
            return self._project_open(body)
        if path == "/api/project/read":
            return self._project_read(body)
        if path == "/api/project/save-raw":
            return self._project_save(body)
        if path == "/api/analyze":
            return self._analyze(body)
        if path == "/api/preview":
            return self._preview_create(body)
        if path == "/api/live/root":
            root = _state["root"]
            entry = (Path(root) / "index.html") if root else None
            return _json(self, 200, {
                "ok": True,
                "root": str(root) if root else "",
                "entry": str(entry) if entry else "",
                "has_entry": bool(entry and entry.exists()),
            })
        if path == "/api/pick":
            # Swift side handles native picker; fallback cancelled
            return _json(self, 200, {"ok": False, "error": "use native picker"})
        _json(self, 404, {"detail": "not found"})

    def _file(self, fp: Path, mime: str):
        if not fp.exists() or not fp.is_file():
            return _json(self, 404, {"detail": "not found"})
        data = fp.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _project_open(self, body):
        raw = body.get("file") or body.get("dir") or ""
        single = bool(body.get("file"))
        p = _safe_resolve(raw)
        if single:
            d = p.parent
        else:
            d = p
        if not _in_home(d):
            return _json(self, 403, {"detail": "项目必须在用户主目录内"})
        if not d.exists() or not d.is_dir():
            return _json(self, 404, {"detail": f"目录不存在: {d}"})
        rel_parts = {x.lower() for x in d.relative_to(HOME).parts} if d != HOME else set()
        if rel_parts & BLOCKED_DIRS:
            return _json(self, 403, {"detail": "不允许打开敏感目录"})
        with _lock:
            _state["root"] = d
            _state["token"] = str(uuid.uuid4())
            token = _state["token"]
        files = []
        if single:
            if p.suffix.lower() not in (".html", ".htm") or not p.exists():
                return _json(self, 400, {"detail": "仅支持 HTML 文件"})
            st = p.stat()
            files.append({
                "name": p.name, "rel": str(p.relative_to(d)), "path": str(p),
                "ext": p.suffix.lower(), "size": st.st_size, "mtime": st.st_mtime,
                "editable": True,
            })
        else:
            count = 0
            for dirpath, dirnames, filenames in os.walk(d):
                dirnames[:] = [x for x in dirnames if not x.startswith(".") and x not in ("node_modules", "__pycache__")]
                rel_dir = Path(dirpath).relative_to(d)
                if len(rel_dir.parts) > 3:
                    dirnames.clear()
                    continue
                for fn in sorted(filenames):
                    if fn.startswith("."):
                        continue
                    ext = Path(fn).suffix.lower()
                    if ext not in PROJECT_EXTS:
                        continue
                    item = Path(dirpath) / fn
                    try:
                        st = item.stat()
                    except OSError:
                        continue
                    files.append({
                        "name": fn, "rel": str(item.relative_to(d)), "path": str(item),
                        "ext": ext, "size": st.st_size, "mtime": st.st_mtime,
                        "editable": ext in EDITABLE_EXTS,
                    })
                    count += 1
                    if count >= 2000:
                        break
                if count >= 2000:
                    break
        pages = [f for f in files if f["ext"] in (".html", ".htm")]
        css = [f for f in files if f["ext"] == ".css"]
        js = [f for f in files if f["ext"] == ".js"]
        headers = {"Set-Cookie": f"project_token={token}; Path=/; HttpOnly; SameSite=Lax"}
        return _json(self, 200, {
            "ok": True, "dir": str(d), "name": d.name, "token": token,
            "files": files, "pages": pages, "css": css, "js": js,
            "is_split": bool(pages) and (bool(css) or bool(js)),
            "is_multipage": len(pages) > 1,
        }, headers)

    def _project_read(self, body):
        if not _token_ok(self):
            return _json(self, 403, {"detail": "项目会话已过期"})
        root = _state["root"]
        if not root:
            return _json(self, 403, {"detail": "请先打开项目"})
        p = _safe_resolve(body.get("path") or "")
        if not p.is_relative_to(Path(root).resolve()):
            return _json(self, 403, {"detail": "文件必须在项目内"})
        if p.name.lower() in SENSITIVE:
            return _json(self, 403, {"detail": "敏感文件"})
        if p.suffix.lower() not in EDITABLE_EXTS:
            return _json(self, 400, {"detail": "不支持的类型"})
        if not p.exists():
            return _json(self, 404, {"detail": "不存在"})
        try:
            content = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            return _json(self, 422, {"detail": "不是 UTF-8"})
        st = p.stat()
        return _json(self, 200, {
            "ok": True, "path": str(p), "name": p.name, "ext": p.suffix.lower(),
            "content": content, "size": st.st_size, "mtime": st.st_mtime,
        })

    def _project_save(self, body):
        if not _token_ok(self):
            return _json(self, 403, {"detail": "项目会话已过期"})
        root = _state["root"]
        if not root:
            return _json(self, 403, {"detail": "请先打开项目"})
        p = _safe_resolve(body.get("path") or "")
        content = body.get("content") or ""
        mtime = float(body.get("mtime") or 0)
        if not p.is_relative_to(Path(root).resolve()):
            return _json(self, 403, {"detail": "保存路径不在项目内"})
        if p.suffix.lower() not in EDITABLE_EXTS:
            return _json(self, 400, {"detail": "不支持的类型"})
        if p.name.lower() in SENSITIVE:
            return _json(self, 403, {"detail": "敏感文件"})
        key = str(p)
        lock = _save_locks.setdefault(key, threading.Lock())
        with lock:
            if p.exists() and abs(p.stat().st_mtime - mtime) > 1.0:
                return _json(self, 409, {"detail": "文件已被外部修改，请刷新后重试"})
            p.parent.mkdir(parents=True, exist_ok=True)
            if p.exists():
                bak = p.with_suffix(p.suffix + f".bak.{int(time.time())}")
                try:
                    bak.write_bytes(p.read_bytes())
                except OSError:
                    pass
            tmp = p.with_suffix(p.suffix + ".tmp")
            tmp.write_text(content, encoding="utf-8")
            tmp.replace(p)
        return _json(self, 200, {"ok": True, "path": str(p), "size": len(content.encode()), "mtime": p.stat().st_mtime})

    def _analyze(self, body):
        p = _safe_resolve(body.get("path") or "")
        if not _in_home(p):
            return _json(self, 403, {"detail": "路径必须在主目录内"})
        if not p.exists():
            return _json(self, 404, {"detail": "不存在"})
        if p.is_file():
            return _json(self, 200, {"ok": True, "mode": "single", "file": str(p), "dir": str(p.parent), "html_count": 1, "reason": "独立单文件"})
        htmls = list(p.rglob("*.html"))[:50]
        if not htmls:
            return _json(self, 200, {"ok": False, "error": "没有 HTML"})
        return _json(self, 200, {
            "ok": True, "mode": "site" if len(htmls) > 1 else "single",
            "dir": str(p), "entry": str(htmls[0]), "html_count": len(htmls),
            "reason": "多文件" if len(htmls) > 1 else "单页",
        })

    def _preview_create(self, body):
        if not _token_ok(self):
            return _json(self, 403, {"detail": "项目会话已过期"})
        html = body.get("html") or ""
        now = time.time()
        for k in [k for k, (_, ts) in _preview.items() if now - ts > 300]:
            _preview.pop(k, None)
        tok = uuid.uuid4().hex[:16]
        _preview[tok] = (html, now)
        return _json(self, 200, {"ok": True, "url": f"/api/preview/{tok}.html"})

    def _live(self, rel: str):
        if not _token_ok(self):
            return _json(self, 403, {"detail": "项目会话已过期"})
        root = _state["root"]
        if not root:
            return _json(self, 400, {"detail": "尚未打开项目"})
        rel = unquote(rel) or "index.html"
        if "\x00" in rel:
            return _json(self, 400, {"detail": "bad path"})
        target = (Path(root) / rel).resolve()
        try:
            target.relative_to(Path(root).resolve())
        except ValueError:
            return _json(self, 403, {"detail": "路径越界"})
        if target.is_dir():
            target = target / "index.html"
        name = target.name.lower()
        if name in SENSITIVE or target.suffix.lower() in (".pem", ".key"):
            return _json(self, 403, {"detail": "敏感文件"})
        if not target.exists() or not target.is_file():
            return _json(self, 404, {"detail": "not found"})
        mime = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if target.suffix.lower() in (".html", ".htm"):
            mime = "text/html; charset=utf-8"
        elif target.suffix.lower() == ".css":
            mime = "text/css; charset=utf-8"
        elif target.suffix.lower() in (".js", ".mjs"):
            mime = "application/javascript; charset=utf-8"
        return self._file(target, mime)


def main():
    # Prefer reusing address quickly after restart
    socketserver = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    socketserver.daemon_threads = True
    print(f"HTML辑霸 backend on http://127.0.0.1:{PORT}", flush=True)
    socketserver.serve_forever()


if __name__ == "__main__":
    main()
