"""
HTML Visual Editor — FastAPI Backend v3
本地 HTML 文件可视化编辑器后端
Features: Finder文件选择、脚本标签无损保存、原生macOS集成、
          多文件项目支持（分体式HTML: html+css+js分离编辑）
"""
import os
import re
import asyncio
import subprocess
from pathlib import Path
from fastapi import FastAPI, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, FileResponse
from pydantic import BaseModel
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request as StarletteRequest


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: StarletteRequest, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "SAMEORIGIN"
        response.headers["Referrer-Policy"] = "no-referrer"
        # P2-4: 端点已设置的 CSP 优先（live/preview 下发收紧版），中间件仅兜底
        if "Content-Security-Policy" not in response.headers:
            if request.url.path.startswith("/api/live/") or request.url.path.startswith("/api/preview/"):
                response.headers["Content-Security-Policy"] = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: blob: https:; font-src 'self' data: https:; connect-src 'self'; frame-ancestors 'self'"
            else:
                response.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data: blob: https:; style-src 'self' 'unsafe-inline' https:; script-src 'self' 'unsafe-inline'; font-src 'self' data: https:; connect-src 'self'"
        return response


class CSRFMiddleware(BaseHTTPMiddleware):
    """本地 CSRF 防护：mutation 请求必须来自同源（127.0.0.1:9100）"""
    SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}
    # P2-3: 从实际监听端口派生白名单（支持 launcher.py [port]）
    import os as _os2
    _port = _os2.environ.get("EDITOR_PORT", "9100")
    # P4-5: 仅允许带端口的精确 host（防 127.0.0.1:80 上的本地服务绕过）
    ALLOWED_HOSTS = {f"127.0.0.1:{_port}", f"localhost:{_port}", f"[::1]:{_port}"}
    async def dispatch(self, request: StarletteRequest, call_next):
        if request.method not in self.SAFE_METHODS:
            host = request.headers.get("host", "")
            origin = request.headers.get("origin", "")
            referer = request.headers.get("referer", "")
            # Host 头必须精确匹配白名单（空 Host 也拒绝）
            if not host or host not in self.ALLOWED_HOSTS:
                from fastapi.responses import JSONResponse
                return JSONResponse({"detail": "CSRF: Host 不在白名单"}, status_code=403)
            # Origin 存在时必须匹配
            if origin:
                from urllib.parse import urlparse
                o = urlparse(origin)
                o_host = o.netloc or o.path
                if o_host not in self.ALLOWED_HOSTS:
                    from fastapi.responses import JSONResponse
                    return JSONResponse({"detail": "CSRF: Origin 不匹配"}, status_code=403)
            # Referer 存在时必须匹配
            if referer:
                from urllib.parse import urlparse
                r = urlparse(referer)
                r_host = r.netloc or r.path
                if r_host not in self.ALLOWED_HOSTS:
                    from fastapi.responses import JSONResponse
                    return JSONResponse({"detail": "CSRF: Referer 不匹配"}, status_code=403)
            # 既无 Origin 也无 Referer 时，要求自定义头（防跨站表单提交）
            if not origin and not referer:
                if not request.headers.get("x-requested-with"):
                    from fastapi.responses import JSONResponse
                    return JSONResponse({"detail": "CSRF: 缺少 X-Requested-With 头"}, status_code=403)
        return await call_next(request)

app = FastAPI(title="HTML Visual Editor", docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(CSRFMiddleware)
app.add_middleware(SecurityHeadersMiddleware)

# favicon（防空 404 控制台报错）
@app.get("/favicon.ico")
async def favicon():
    from fastapi.responses import Response
    return Response(content=b"", media_type="image/x-icon")

# Serve static files
static_dir = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

# Allowed extensions for project files
PROJECT_EXTS = {".html", ".htm", ".css", ".js", ".json", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".woff", ".woff2", ".ttf"}
EDITABLE_EXTS = {".html", ".htm", ".css", ".js", ".json", ".svg"}

# Bug5: 实景渲染根目录（当前打开的项目/文件所在目录），由 /api/project/open 或 /api/open 设置
_live_root = None
_live_token = None  # 项目会话 token，防多标签页覆盖


def _safe_path(raw: str) -> Path:
    """将用户输入路径转为安全的 Path，拒绝 null byte 等非法字符"""
    if '\x00' in raw:
        raise HTTPException(400, "路径包含非法字符")
    try:
        return Path(raw).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        raise HTTPException(400, "路径解析失败")


class OpenRequest(BaseModel):
    path: str


class SaveRawRequest(BaseModel):
    path: str
    content: str
    mtime: float = 0  # 加载时的 mtime，用于冲突检测

# 并发保存锁（per-path）
_save_locks: dict[str, asyncio.Lock] = {}


class BrowseRequest(BaseModel):
    dir: str = ""
    path: str = ""  # P4: 兼容误用 path 字段的调用方
    extensions: list[str] = [".html", ".htm"]

    @property
    def effective_dir(self) -> str:
        return self.dir or self.path


class ProjectOpenRequest(BaseModel):
    dir: str
    file: str = ""  # 单文件模式：指定具体 HTML 文件（允许其位于 home 根目录，项目仅含该文件）


@app.get("/", response_class=HTMLResponse)
async def index():
    return FileResponse(str(static_dir / "index.html"))


# ==================== PROJECT API (multi-file) ====================

@app.post("/api/project/open")
async def project_open(req: ProjectOpenRequest):
    """Open a directory as a project: scan for HTML/CSS/JS files.
    单文件模式：传 file（具体 HTML 文件路径）时，项目根自动取该文件所在目录，
    且允许文件位于 home 根目录（项目仅含该文件）。兼容 Windows 反斜杠路径。"""
    global _live_root
    import unicodedata
    _single_file_mode = bool(req.file)
    if _single_file_mode:
        # 单文件模式：项目根 = 文件所在目录（由后端推导，前端无需处理路径分隔符）
        raw = unicodedata.normalize('NFC', req.file)
        d = Path(raw).expanduser()
        if not d.is_absolute():
            d = Path(__file__).parent / d
        try:
            d = d.resolve()
        except (OSError, RuntimeError, ValueError):
            raise HTTPException(400, f"路径解析失败（可能存在循环符号链接或非法字符）: {req.file}")
        d = d.parent
    else:
        raw = unicodedata.normalize('NFC', req.dir)
        d = Path(raw).expanduser()
        if not d.is_absolute():
            d = Path(__file__).parent / d
        try:
            d = d.resolve()
        except (OSError, RuntimeError, ValueError):
            raise HTTPException(400, f"路径解析失败（可能存在循环符号链接或非法字符）: {req.dir}")
    # 安全：限制项目根目录在用户主目录下
    home = Path.home().resolve()
    if not d.is_relative_to(home):
        raise HTTPException(403, f"项目目录必须在用户主目录内: {d}")
    # P1: 拒绝项目根 == home（relative parts 为空 → 黑名单永不命中 → 整个 home 可读写）
    # 例外：单文件模式允许文件位于 home 根目录——此时项目仅含该文件，不做全目录扫描
    _rel_parts = d.relative_to(home).parts
    if not _rel_parts and not _single_file_mode:
        raise HTTPException(403, "不允许以用户主目录作为项目根（安全风险）")
    # 安全：禁止敏感目录作为项目根（大小写不敏感 + 检查相对 home 的所有路径段）
    _OPEN_BLOCKED = {'.ssh', '.aws', '.gnupg', '.kube', '.config', '.npm', '.cache', '.zsh_history', '.bash_history', '.netrc', '.pgpass', 'keychains', 'cookies', '.docker', 'node_modules', '.venv', 'venv', '__pycache__', '.tox', '.mypy_cache', 'library', '.local', '.trash', '.vscode', 'preferences'}
    _rel_parts_lower = {part.lower() for part in _rel_parts}
    if _OPEN_BLOCKED & _rel_parts_lower or d.name.lower().startswith('.env'):
        raise HTTPException(403, f"不允许打开敏感目录: {d.name}")
    # P2-1: 目录存在性检查必须在 _live_root/token 变更之前（防静默吊销所有会话）
    if not d.exists() or not d.is_dir():
        raise HTTPException(404, f"目录不存在: {d}")
    global _live_token
    import uuid
    _prev_root = _live_root
    _live_root = d  # Bug5: 记录实景渲染根目录
    # P3-4: 同项目刷新不轮换 token（防其他标签页 403）；新项目或首次打开才生成
    if str(_prev_root) != str(d) or not _live_token:
        _live_token = str(uuid.uuid4())
    files = []
    SKIP_DIRS = {'.git', 'node_modules', '__pycache__', '.venv', 'venv', '.tox', '.mypy_cache'}
    file_count = 0
    if _single_file_mode:
        # 单文件模式：仅纳入指定的这一个文件（不扫描整个目录，避免 home 根目录被全量遍历）
        fp = Path(unicodedata.normalize('NFC', req.file)).expanduser().resolve()
        if not fp.is_relative_to(d):
            raise HTTPException(403, "文件必须位于所选目录内")
        if fp.suffix.lower() not in ('.html', '.htm'):
            raise HTTPException(400, f"仅支持打开 HTML 文件: {fp.name}")
        if not fp.exists() or not fp.is_file():
            raise HTTPException(404, f"文件不存在: {fp}")
        st = fp.stat()
        files.append({
            "name": fp.name,
            "rel": str(fp.relative_to(d)),
            "path": str(fp),
            "ext": fp.suffix.lower(),
            "size": st.st_size,
            "mtime": st.st_mtime,
            "editable": fp.suffix.lower() in EDITABLE_EXTS,
        })
    else:
        for dirpath, dirnames, filenames in os.walk(d):
            # 原地剪枝：跳过隐藏目录和大型依赖目录
            dirnames[:] = [dn for dn in dirnames if not dn.startswith('.') and dn not in SKIP_DIRS]
            rel_dir = Path(dirpath).relative_to(d)
            if len(rel_dir.parts) > 3:
                dirnames.clear()
                continue
            for fn in sorted(filenames):
                if fn.startswith('.'):
                    continue
                ext = Path(fn).suffix.lower()
                if ext not in PROJECT_EXTS:
                    continue
                item = Path(dirpath) / fn
                rel = item.relative_to(d)
                try:
                    st = item.stat()
                except OSError:
                    continue  # P3-5: 坏符号链接等跳过
                files.append({
                    "name": fn,
                    "rel": str(rel),
                    "path": str(item),
                    "ext": ext,
                    "size": st.st_size,
                    "mtime": st.st_mtime,
                    "editable": ext in EDITABLE_EXTS,
                })
                file_count += 1
                if file_count >= 2000:
                    break
            if file_count >= 2000:
                break

    # Identify entry pages (html files)
    html_files = [f for f in files if f["ext"] in (".html", ".htm")]
    css_files = [f for f in files if f["ext"] == ".css"]
    js_files = [f for f in files if f["ext"] == ".js"]

    from fastapi.responses import JSONResponse as _JR
    _resp = _JR(content={
        "ok": True,
        "dir": str(d),
        "name": d.name,
        "token": _live_token,
        "files": files,
        "pages": html_files,
        "css": css_files,
        "js": js_files,
        "is_split": len(html_files) > 0 and (len(css_files) > 0 or len(js_files) > 0),
        "is_multipage": len(html_files) > 1,
    })
    _resp.set_cookie("project_token", _live_token, path="/", httponly=True, samesite="lax", max_age=86400)
    return _resp


@app.post("/api/project/read")
async def project_read(req: OpenRequest, request: Request):
    """Read a single file's raw content (for CSS/JS editing)"""
    p = _safe_path(req.path)
    # P2-1: 项目会话 token 校验
    if _live_token:
        tok = request.headers.get("X-Project-Token") or request.cookies.get("project_token")
        if tok != _live_token:
            raise HTTPException(403, "项目会话已过期，请重新打开项目")
    # 安全：限制在当前项目根目录内（_live_root），无项目时直接拒绝
    if not _live_root:
        raise HTTPException(403, "请先打开项目后再读取文件")
    root = Path(_live_root).resolve()
    if not p.is_relative_to(root):
        raise HTTPException(403, "文件必须在当前项目目录内")
    # P2: 敏感路径/文件名黑名单（与 save-raw 一致）
    _read_blocked_dirs = {'.git', '.hg', '.svn', '.bzr', 'node_modules', '.ssh', '.aws', '.gnupg', '.kube', '.config', '__pycache__', '.venv', 'venv', '.tox', '.mypy_cache'}
    try:
        _read_rel_parts = p.relative_to(root).parts
    except ValueError:
        _read_rel_parts = p.parts
    if _read_blocked_dirs & {part.lower() for part in _read_rel_parts}:
        raise HTTPException(403, "禁止读取受保护目录")
    _read_sensitive = {'.env', '.gitignore', '.npmrc', '.ds_store', 'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa', '.zsh_history', '.bash_history', '.envrc', '.netrc', '.zshrc', '.bashrc', '.bash_profile', '.zprofile', '.gitconfig', '.git-credentials', '.profile'}
    _rname_lower = p.name.lower()
    if _rname_lower in _read_sensitive or _rname_lower.startswith('.env.') or _rname_lower.endswith('.env') or _rname_lower.startswith('id_rsa.') or '.bak.' in _rname_lower:
        raise HTTPException(403, "禁止读取敏感文件")
    if not p.exists() or not p.is_file():
        raise HTTPException(404, f"文件不存在: {p}")
    if p.suffix.lower() not in EDITABLE_EXTS:
        raise HTTPException(400, f"不支持编辑的文件类型: {p.suffix}")
    st = p.stat()
    if st.st_size > 10 * 1024 * 1024:
        raise HTTPException(413, f"文件过大（{st.st_size/1024/1024:.1f}MB），超过 10MB 读取上限")
    # 严格 UTF-8 解码：非 UTF-8 文件拒绝编辑（防 errors="replace" 后保存永久损坏）
    try:
        content = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise HTTPException(422, "文件不是有效的 UTF-8 编码，无法编辑。请先用文本编辑器转换编码。")
    return {
        "ok": True,
        "path": str(p),
        "name": p.name,
        "ext": p.suffix.lower(),
        "content": content,
        "size": st.st_size,
        "mtime": st.st_mtime,
    }


@app.post("/api/project/save-raw")
async def project_save_raw(req: SaveRawRequest, request: Request):
    """Save raw text content to a file (CSS/JS/HTML source mode)"""
    # P2-1: 项目会话 token 校验
    if _live_token:
        tok = request.headers.get("X-Project-Token") or request.cookies.get("project_token")
        if tok != _live_token:
            raise HTTPException(403, "项目会话已过期，请重新打开项目")
    import unicodedata
    # 统一路径安全校验（null-byte / expanduser / resolve）
    p = _safe_path(unicodedata.normalize('NFC', req.path))
    # 文件名校验：禁止 URL 破坏字符（# & ; 空格等），保留中文和常规字符
    import re as _re
    if not _re.match(r'^[\w\-\.\u4e00-\u9fa5()]+$', p.name):
        raise HTTPException(400, f"文件名含非法字符: {p.name}")
    # 路径沙箱：必须在当前项目根目录内
    if not _live_root:
        raise HTTPException(403, "请先打开一个项目再保存")
    root_resolved = _live_root.resolve()
    if not p.is_relative_to(root_resolved):
        raise HTTPException(403, "保存路径不在项目目录内")
    # 隐藏目录/敏感目录黑名单（对齐 live_render）
    _save_blocked_dirs = {'.git', 'node_modules', '.ssh', '.aws', '.gnupg', '.kube', '.config', '__pycache__', '.venv', 'venv', '.tox', '.mypy_cache'}
    # P1-2: 大小写不敏感比较（APFS 默认不区分大小写）
    if _save_blocked_dirs & {part.lower() for part in p.relative_to(root_resolved).parts}:
        raise HTTPException(403, "禁止写入受保护目录")
    # P3-1: 敏感文件名拦截先于扩展名检查（防 .ENV 返回 400 而非 403 的语义不一致）
    _save_sensitive = {'.env', '.gitignore', '.npmrc', '.ds_store', 'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa', '.zsh_history', '.bash_history', '.envrc', '.netrc', '.zshrc', '.bashrc', '.bash_profile', '.zprofile', '.gitconfig', '.git-credentials', '.profile'}
    _pname_lower = p.name.lower()
    if _pname_lower in _save_sensitive or _pname_lower.startswith('.env.') or _pname_lower.endswith('.env') or _pname_lower.startswith('id_rsa.') or _pname_lower.endswith('.bak'):
        raise HTTPException(403, "禁止写入敏感文件")
    # P4: .bak. 子串拦截改为更精确的后缀匹配（防误伤合法文件名）
    if '.bak.' in _pname_lower:
        raise HTTPException(403, "禁止写入备份文件")
    if p.suffix.lower() not in EDITABLE_EXTS:
        raise HTTPException(400, f"不支持保存的文件类型: {p.suffix}")
    # P4-5: 内容大小限制（10MB，按 UTF-8 字节计）
    _content_bytes = len(req.content.encode('utf-8'))
    if _content_bytes > 10 * 1024 * 1024:
        raise HTTPException(413, f"内容超过 10MB 限制（{_content_bytes/1024/1024:.1f}MB）")
    # surrogate/非法字符预校验（防 write_text 500）
    try:
        req.content.encode('utf-8', errors='strict')
    except (UnicodeEncodeError, UnicodeDecodeError):
        raise HTTPException(422, "内容包含非法 Unicode 字符（如 lone surrogate），无法保存")
    # 编码检测：非 UTF-8 文件拒绝保存（全文件校验，先检查大小防 OOM）
    if p.exists():
        if p.stat().st_size > 10 * 1024 * 1024:
            raise HTTPException(413, "文件过大，无法校验编码")
        try:
            p.read_bytes().decode('utf-8')
        except UnicodeDecodeError:
            raise HTTPException(422, f"文件 {p.name} 不是 UTF-8 编码，保存会损坏内容。请先转换编码。")
    # 并发保存锁
    key = str(p)
    if key not in _save_locks:
        _save_locks[key] = asyncio.Lock()
    async with _save_locks[key]:
        # mtime 冲突检测（mtime=0 也检测，防新建/空文件被静默覆盖）
        if p.exists():
            cur_mtime = p.stat().st_mtime
            if abs(cur_mtime - req.mtime) > 1.0:  # P3-3: mtime=0 也检测（防静默覆盖）
                raise HTTPException(409, f"文件已被外部修改（加载时 {req.mtime:.0f}，当前 {cur_mtime:.0f}），请刷新后重试")
        # P4-1: 路径指向已存在目录时拒绝（防 rename 500）
        if p.exists() and not p.is_file():
            raise HTTPException(400, f"保存路径不是文件: {p.name}")
        p.parent.mkdir(parents=True, exist_ok=True)
        # 自动备份（时间戳轮转，保留最近 5 份）
        if p.exists():
            import shutil, time as _t, glob as _gl
            import random as _rnd
            bak = p.with_suffix(p.suffix + f".bak.{int(_t.time())}_{_rnd.randint(1000,9999)}")
            shutil.copyfile(p, bak)
            # 清理旧备份：同前缀的 .bak.* 按时间排序，只保留最近 5 份
            old_baks = sorted(_gl.glob(str(p) + ".bak.*"), key=lambda f: Path(f).stat().st_mtime)
            for ob in old_baks[:-5]:
                Path(ob).unlink(missing_ok=True)
        # 原子写：先写临时文件再 rename，防止写入中途崩溃损坏
        import tempfile as _tf
        fd, tmp_path = _tf.mkstemp(dir=str(p.parent), suffix=".tmp")
        tmp = Path(tmp_path)
        try:
            tmp.write_text(req.content, encoding="utf-8")
            if p.exists():
                import shutil as _sh
                _sh.copymode(p, tmp)
            tmp.rename(p)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise
        finally:
            import os as _os
            try: _os.close(fd)
            except OSError: pass
    # P3-8/P4-5: 锁池上限收紧到 100，超出时清除所有未持有的锁（仅 pop 未锁定项，无竞态）
    if len(_save_locks) > 100:
        for k in [k for k, v in _save_locks.items() if not v.locked()]:
            _save_locks.pop(k, None)
    return {"ok": True, "path": str(p), "size": len(req.content.encode('utf-8')), "mtime": p.stat().st_mtime}


@app.post("/api/project/resolve-assets")
async def project_resolve_assets(req: OpenRequest, request: Request):
    """Given an HTML file, resolve its external CSS/JS references to absolute paths"""
    # P3-2: 项目会话 token 校验
    if _live_token:
        tok = request.headers.get("X-Project-Token") or request.cookies.get("project_token")
        if tok != _live_token:
            raise HTTPException(403, "项目会话已过期，请重新打开项目")
    p = _safe_path(req.path)
    # P3-1: 沙箱检查先于存在性检查（防存在性 oracle）+ home 限制
    if not _live_root:
        raise HTTPException(403, "请先打开项目后再解析资源")
    root = Path(_live_root).resolve()
    home = Path.home().resolve()
    if not p.is_relative_to(home):
        raise HTTPException(403, "文件必须在用户主目录内")
    if not p.is_relative_to(root):
        raise HTTPException(403, "文件必须在当前项目目录内")
    if not p.exists():
        raise HTTPException(404, f"文件不存在: {p}")

    try:
        content = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise HTTPException(422, "文件不是有效的 UTF-8 编码，无法解析资源引用")
    base = p.parent

    css_refs = []
    for m in re.finditer(r'<link\b[^>]*href=["\']([^"\']+)["\'][^>]*>', content, re.IGNORECASE):
        href = m.group(1)
        if href.startswith(("http://", "https://", "//", "data:")):
            css_refs.append({"href": href, "resolved": None, "external": True})
        else:
            resolved = (base / href).resolve()
            # 安全：resolved 必须在项目根内，否则置 null（防路径探测）
            in_root = resolved.is_relative_to(root)
            css_refs.append({
                "href": href,
                "resolved": str(resolved) if in_root and resolved.exists() else None,
                "external": False,
                "exists": in_root and resolved.exists(),
            })

    js_refs = []
    for m in re.finditer(r'<script\b[^>]*src=["\']([^"\']+)["\'][^>]*>', content, re.IGNORECASE):
        src = m.group(1)
        if src.startswith(("http://", "https://", "//")):
            js_refs.append({"src": src, "resolved": None, "external": True})
        else:
            resolved = (base / src).resolve()
            in_root = resolved.is_relative_to(root)
            js_refs.append({
                "src": src,
                "resolved": str(resolved) if in_root and resolved.exists() else None,
                "external": False,
                "exists": in_root and resolved.exists(),
            })

    return {"ok": True, "path": str(p), "css": css_refs, "js": js_refs}


# ==================== FINDER API ====================
# 跨平台原生文件对话框：macOS 用 osascript，Windows 用 PowerShell。
# 注意：/api/finder 与 /api/finder-dir 是"打开入口"——用户正是靠它们来打开第一个项目，
# 此时尚不存在项目会话 token，因此这两个端点【不能】要求 token（否则首次使用必然 403）。
# 它们的安全性由"路径必须落在用户主目录内 + 敏感目录黑名单"保证（在 open 阶段校验）。
# /api/finder-save 是打开项目之后的动作，保留 token 校验。

import sys as _sys
_IS_WINDOWS = _sys.platform.startswith("win")


def _pick_file_macos() -> str:
    script = '''
    set chosenFile to choose file with prompt "选择 HTML 文件" ¬
        of type {"public.html", "com.microsoft.htm"} ¬
        default location (path to documents folder) ¬
        with invisibles
    return POSIX path of chosenFile
    '''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        err = r.stderr.strip()
        if "User canceled" in err or "(-128)" in err:
            return ""
        raise RuntimeError(err or "选择器出错")
    return r.stdout.strip()


def _pick_folder_macos() -> str:
    script = '''
    set chosenFolder to choose folder with prompt "选择项目文件夹" ¬
        default location (path to documents folder) ¬
        with invisibles
    return POSIX path of chosenFolder
    '''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        err = r.stderr.strip()
        if "User canceled" in err or "(-128)" in err:
            return ""
        raise RuntimeError(err or "选择器出错")
    return r.stdout.strip()


def _pick_file_windows() -> str:
    ps = (
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$d=New-Object System.Windows.Forms.OpenFileDialog;"
        "$d.Title='选择 HTML 文件';"
        "$d.Filter='HTML 文件 (*.html;*.htm)|*.html;*.htm|所有文件 (*.*)|*.*';"
        "$d.InitialDirectory=[Environment]::GetFolderPath('MyDocuments');"
        "if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ Write-Output $d.FileName }"
    )
    r = subprocess.run(["powershell", "-NoProfile", "-STA", "-Command", ps],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "选择器出错")
    return r.stdout.strip()


def _pick_folder_windows() -> str:
    ps = (
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$d=New-Object System.Windows.Forms.FolderBrowserDialog;"
        "$d.Description='选择项目文件夹';"
        "$d.ShowNewFolderButton=$true;"
        "$d.SelectedPath=[Environment]::GetFolderPath('MyDocuments');"
        "if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ Write-Output $d.SelectedPath }"
    )
    r = subprocess.run(["powershell", "-NoProfile", "-STA", "-Command", ps],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "选择器出错")
    return r.stdout.strip()


# ---------- 统一选择器：文件 或 文件夹（单一入口） ----------

def _pick_any_macos() -> str:
    """macOS：统一选择器（文件+文件夹二选一）。
    通过 `open -W HtmlEditorPicker.app` 启动独立 App 进程：
    - LaunchServices 负责正确激活前台，对话框能成为 key window（侧边栏可导航）；
    - 裸 subprocess 二进制无法可靠激活 AppKit（对话框隐藏或不可交互，表现为"卡住"）。
    结果经临时文件传递（选中=绝对路径，取消=空字符串）。
    兜底：.app 不存在时回退裸二进制，再回退 osascript。"""
    app_bundle = Path(__file__).parent / "native" / "HtmlEditorPicker.app"
    if app_bundle.exists():
        import tempfile
        fd, result_file = tempfile.mkstemp(prefix="htmleditor_pick_", suffix=".txt")
        os.close(fd)
        try:
            subprocess.run(["open", "-W", str(app_bundle), "--args", result_file],
                           capture_output=True, text=True, timeout=300)
            result = Path(result_file).read_text(encoding="utf-8", errors="replace").strip()
            return result
        finally:
            try: os.unlink(result_file)
            except OSError: pass
    # 兜底 1：裸二进制
    picker_bin = Path(__file__).parent / "native" / "picker"
    if picker_bin.exists():
        import tempfile
        fd, result_file = tempfile.mkstemp(prefix="htmleditor_pick_", suffix=".txt")
        os.close(fd)
        try:
            subprocess.run([str(picker_bin), result_file], capture_output=True, text=True, timeout=300)
            return Path(result_file).read_text(encoding="utf-8", errors="replace").strip()
        finally:
            try: os.unlink(result_file)
            except OSError: pass
    # 兜底 2：osascript（可能不弹前台，仅作最后兜底）
    script = '''
    use framework "AppKit"
    set app to current application's NSApplication's sharedApplication()
    app's activateIgnoringOtherApps:true
    set panel to current application's NSOpenPanel's openPanel()
    panel's setCanChooseFiles:true
    panel's setCanChooseDirectories:true
    panel's setAllowsMultipleSelection:false
    panel's setCanCreateDirectories:false
    panel's setTitle:"打开网页文件或文件夹"
    panel's setMessage:"选择网页文件（.html），或选择整个网页文件夹"
    panel's setPrompt:"打开"
    if (panel's runModal()) is equal to (current application's NSModalResponseOK) then
        set theURL to (panel's URLs())'s firstObject()
        return (theURL's |path|()) as text
    else
        return ""
    end if
    '''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        err = r.stderr.strip()
        if "User canceled" in err or "(-128)" in err:
            return ""
        raise RuntimeError(err or "选择器出错")
    return r.stdout.strip()


def _pick_any_windows() -> str:
    """Windows：OpenFileDialog 兼容技巧——选真实文件则返回文件；
    在文件夹内不选文件直接点"打开"则返回 (目录\\占位名)，由后端识别为文件夹。"""
    ps = (
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$d=New-Object System.Windows.Forms.OpenFileDialog;"
        "$d.Title='选择网页文件，或进入文件夹后直接点打开';"
        "$d.Filter='网页文件 (*.html;*.htm)|*.html;*.htm|所有文件 (*.*)|*.*';"
        "$d.InitialDirectory=[Environment]::GetFolderPath('MyDocuments');"
        "$d.CheckFileExists=$false;"
        "$d.FileName='【选择当前文件夹】';"
        "if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ Write-Output $d.FileName }"
    )
    r = subprocess.run(["powershell", "-NoProfile", "-STA", "-Command", ps],
                       capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "选择器出错")
    return r.stdout.strip()


# ---------- 拖拽导入工作区 ----------
# 浏览器拖入的文件拿不到原始绝对路径，只能上传为工作副本。
# 导入目录放在用户主目录下，走与 project/open 相同的安全校验。
_IMPORT_BASE = Path.home() / ".html-editor-imports"


@app.get("/api/info")
async def app_info():
    """前端据此切换平台文案（macOS / Windows）"""
    return {
        "platform": "windows" if _IS_WINDOWS else "macos",
        "native_picker": True,
    }


@app.post("/api/pick")
async def pick_any():
    """统一系统选择器：返回选中的文件或文件夹（打开入口，无需 token）"""
    try:
        loop = asyncio.get_event_loop()
        picker = _pick_any_windows if _IS_WINDOWS else _pick_any_macos
        result = await loop.run_in_executor(None, picker)
        if not result:
            return {"ok": False, "error": "cancelled"}
        # Windows 文件夹占位技巧：返回的是 (目录\占位名)，占位文件不存在 → 取目录
        p = Path(result).expanduser()
        try:
            p = p.resolve()
        except (OSError, RuntimeError, ValueError):
            return {"ok": False, "error": "路径解析失败"}
        if p.is_dir():
            return {"ok": True, "kind": "dir", "path": str(p)}
        if p.is_file():
            if p.suffix.lower() not in ('.html', '.htm'):
                return {"ok": False, "error": "请选择 HTML 网页文件（.html / .htm）"}
            return {"ok": True, "kind": "file", "path": str(p), "name": p.name}
        # 文件不存在但父目录存在 → Windows 文件夹占位情形
        if p.parent.is_dir() and not p.exists():
            return {"ok": True, "kind": "dir", "path": str(p.parent)}
        return {"ok": False, "error": f"路径不存在: {p}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/analyze")
async def analyze_path(req: OpenRequest):
    """分析一个文件或文件夹：判定是"单文件网页"还是"多文件网站"，并给出打开方式。
    核心区分：文件夹下多个 html 是属于同一网站（互相链接/共享 css·js/有 index 入口），
    还是只是互不相关的独立 html 文件。"""
    p = _safe_path(req.path)
    home = Path.home().resolve()
    if not p.is_relative_to(home):
        raise HTTPException(403, "路径必须在用户主目录内")
    if not p.exists():
        raise HTTPException(404, f"路径不存在: {p}")

    def _read_head(fp: Path, limit: int = 200_000) -> str:
        try:
            return fp.read_text(encoding="utf-8", errors="ignore")[:limit]
        except OSError:
            return ""

    def _refs_local_assets(content: str) -> bool:
        # 引用了本地 css/js（非 http/data 协议）→ 分体式网站特征
        if re.search(r'<link[^>]+href=["\'](?!(?:https?:)?//|data:)[^"\']+\.css', content, re.I):
            return True
        if re.search(r'<script[^>]+src=["\'](?!(?:https?:)?//|data:)[^"\']+\.js', content, re.I):
            return True
        return False

    def _links_local_html(content: str) -> bool:
        return bool(re.search(r'href=["\'](?!(?:https?:)?//|#|mailto:|javascript:|data:)[^"\']*\.html?', content, re.I))

    if p.is_file():
        parent = p.parent
        content = _read_head(p)
        html_siblings = [f for f in parent.iterdir()
                         if f.suffix.lower() in ('.html', '.htm') and f != p and f.is_file()]
        index_file = next((f for f in (parent / 'index.html', parent / 'index.htm') if f.exists()), None)
        has_assets_dir = any(d.is_dir() and d.name.lower() in ('assets', 'css', 'js', 'img', 'images', 'static', 'vendor')
                             for d in parent.iterdir() if d.is_dir())
        site_signals = 0
        reasons = []
        if _refs_local_assets(content):
            site_signals += 2; reasons.append("引用了本地 CSS/JS 资源")
        if index_file and index_file != p:
            site_signals += 1; reasons.append("存在 index 入口页")
        if _links_local_html(content):
            site_signals += 1; reasons.append("链接到其他本地页面")
        if has_assets_dir:
            site_signals += 1; reasons.append("包含资源文件夹")
        is_site = site_signals >= 2 or (_refs_local_assets(content) and (html_siblings or has_assets_dir))
        if is_site:
            entry = str(index_file) if index_file else str(p)
            return {"ok": True, "mode": "site", "dir": str(parent), "entry": entry,
                    "file": str(p), "html_count": len(html_siblings) + 1,
                    "reason": "；".join(reasons) or "检测到多文件结构"}
        return {"ok": True, "mode": "single", "file": str(p), "dir": str(parent),
                "html_count": 1, "reason": "独立的单文件网页"}

    # 文件夹
    html_files = []
    for dirpath, dirnames, filenames in os.walk(p):
        dirnames[:] = [dn for dn in dirnames if not dn.startswith('.') and dn not in ('node_modules', '__pycache__')]
        rel = Path(dirpath).relative_to(p)
        if len(rel.parts) > 3:
            dirnames.clear(); continue
        for fn in filenames:
            if Path(fn).suffix.lower() in ('.html', '.htm'):
                html_files.append(Path(dirpath) / fn)
        if len(html_files) > 500:
            break
    if not html_files:
        return {"ok": False, "error": "该文件夹中没有 HTML 网页文件"}
    index_file = next((f for f in (p / 'index.html', p / 'index.htm') if f.exists()), None)
    css_js = [f for f in p.rglob('*') if f.suffix.lower() in ('.css', '.js') and f.is_file()]
    # 判定：有 index 入口，或 html 间互相链接，或共享 css/js → 同一网站
    linked = False
    sample = html_files[:5]
    for f in sample:
        c = _read_head(f, 60_000)
        if _links_local_html(c) or _refs_local_assets(c):
            linked = True; break
    is_site = (index_file is not None) or (len(html_files) > 1 and (linked or css_js))
    entry = str(index_file) if index_file else str(html_files[0])
    if is_site:
        return {"ok": True, "mode": "site", "dir": str(p), "entry": entry,
                "html_count": len(html_files), "reason": "多文件网站（含入口页/共享资源）"}
    return {"ok": True, "mode": "collection", "dir": str(p), "entry": entry,
            "html_count": len(html_files), "reason": "多个相互独立的网页文件"}


@app.post("/api/import")
async def import_files(request: Request):
    """接收拖拽上传的文件（multipart），存入导入工作区，返回工作区目录。
    字段：session（本次导入会话名）、paths（与 files 一一对应的相对路径）。"""
    from fastapi import UploadFile
    form = await request.form()
    session = str(form.get("session") or "").strip()
    paths = form.getlist("paths")
    files = form.getlist("files")
    if not session or not re.match(r'^[\w\u4e00-\u9fa5\- ]{1,64}$', session):
        raise HTTPException(400, "非法的会话名")
    if not files:
        raise HTTPException(400, "未收到文件")
    if len(files) != len(paths):
        raise HTTPException(400, "文件与路径数量不一致")
    if len(files) > 300:
        raise HTTPException(413, "单次导入文件过多（>300）")
    dest_root = (_IMPORT_BASE / session).resolve()
    if not dest_root.is_relative_to(_IMPORT_BASE.resolve()):
        raise HTTPException(400, "非法路径")
    dest_root.mkdir(parents=True, exist_ok=True)
    total = 0
    saved = 0
    for up, rel in zip(files, paths):
        rel = str(rel).replace('\\', '/').lstrip('/')
        if '\x00' in rel or rel.startswith('..') or '..' in Path(rel).parts:
            continue
        name = Path(rel).name
        if name.startswith('.') or Path(rel).suffix.lower() not in PROJECT_EXTS:
            continue
        target = (dest_root / rel).resolve()
        if not target.is_relative_to(dest_root):
            continue
        data = await up.read()
        total += len(data)
        if total > 60 * 1024 * 1024:
            raise HTTPException(413, "导入内容超过 60MB 限制")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        saved += 1
    if saved == 0:
        raise HTTPException(400, "没有可导入的有效网页文件")
    return {"ok": True, "dir": str(dest_root), "saved": saved}



@app.post("/api/finder")
async def finder_open():
    """调用系统原生文件选择对话框，返回选中的 HTML 文件路径（打开入口，无需 token）"""
    try:
        loop = asyncio.get_event_loop()
        picker = _pick_file_windows if _IS_WINDOWS else _pick_file_macos
        filepath = await loop.run_in_executor(None, picker)
        if not filepath:
            return {"ok": False, "error": "cancelled"}

        p = Path(filepath).resolve()
        if not p.exists():
            return {"ok": False, "error": f"文件不存在: {p}"}
        return {"ok": True, "path": str(p), "name": p.name, "size": p.stat().st_size}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout (120s)"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/finder-dir")
async def finder_dir():
    """调用系统原生文件夹选择对话框，返回选中的目录路径（打开入口，无需 token）"""
    try:
        loop = asyncio.get_event_loop()
        picker = _pick_folder_windows if _IS_WINDOWS else _pick_folder_macos
        dirpath = await loop.run_in_executor(None, picker)
        if not dirpath:
            return {"ok": False, "error": "cancelled"}
        return {"ok": True, "path": dirpath}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout (120s)"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/finder-save")
async def finder_save(request: Request):
    # P3-2: 项目会话 token 校验（保存是打开项目之后的动作，需要 token）
    if _live_token:
        tok = request.headers.get("X-Project-Token") or request.cookies.get("project_token")
        if tok != _live_token:
            raise HTTPException(403, "项目会话已过期，请重新打开项目")
    """调用系统原生另存为对话框，返回保存路径"""
    if _IS_WINDOWS:
        ps = (
            "Add-Type -AssemblyName System.Windows.Forms;"
            "$d=New-Object System.Windows.Forms.SaveFileDialog;"
            "$d.Title='另存为';$d.FileName='untitled.html';"
            "$d.Filter='HTML 文件 (*.html)|*.html';"
            "$d.InitialDirectory=[Environment]::GetFolderPath('MyDocuments');"
            "if($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ Write-Output $d.FileName }"
        )
        cmd = ["powershell", "-NoProfile", "-STA", "-Command", ps]
    else:
        script = '''
        set savePath to choose file name ¬
            default name "untitled.html" ¬
            default location (path to documents folder)
        return POSIX path of savePath
        '''
        cmd = ["osascript", "-e", script]
    try:
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(None, lambda: subprocess.run(
            cmd, capture_output=True, text=True, timeout=120
        ))
        if result.returncode != 0:
            err = result.stderr.strip()
            if "User canceled" in err or "(-128)" in err:
                return {"ok": False, "error": "cancelled"}
            return {"ok": False, "error": err}

        filepath = result.stdout.strip()
        if not filepath:
            return {"ok": False, "error": "no path selected"}

        p = Path(filepath)
        if p.suffix.lower() not in ('.html', '.htm'):
            p = p.with_suffix('.html')

        return {"ok": True, "path": str(p.resolve())}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ==================== SINGLE-FILE API (v2 compat) ====================

@app.post("/api/open")
async def open_file(req: OpenRequest):
    """打开本地 HTML 文件，提取 body/style/scripts"""
    global _live_root
    p = _safe_path(req.path)
    # 安全：限制在主目录内（先于存在性检查，避免文件存在性 oracle）
    home = Path.home().resolve()
    if not p.is_relative_to(home):
        raise HTTPException(403, f"文件必须在用户主目录内: {p}")
    # 安全：敏感目录/文件黑名单（防恶意 HTML 通过 /api/open 读取私钥等）
    _blocked_dirs = {'.ssh', '.aws', '.gnupg', '.kube', '.config', '.npm', '.cache', '__pycache__', 'node_modules', '.git', 'venv', '.venv'}
    _blocked_files = {'.env', '.env.local', '.env.production', '.npmrc', '.netrc', '.gitconfig', 'id_rsa', 'id_ed25519', 'known_hosts', 'credentials', '.docker/config.json', '.zshrc', '.bashrc', '.bash_profile', '.zprofile', '.git-credentials', '.profile'}
    rel_parts = p.relative_to(home).parts
    # P1-2: 大小写不敏感比较
    if _blocked_dirs & {part.lower() for part in rel_parts}:
        raise HTTPException(403, "敏感目录禁止访问")
    _pname_lower = p.name.lower()
    if _pname_lower in _blocked_files or _pname_lower.startswith('.env'):
        raise HTTPException(403, "敏感文件禁止访问")
    # 安全：.bak 文件 + 扩展名白名单（仅允许打开 HTML 文件）
    if p.name.endswith('.bak') or '.bak.' in p.name:
        raise HTTPException(403, "备份文件（.bak）禁止直接打开")
    _OPEN_EXTS = {'.html', '.htm'}
    if p.suffix.lower() not in _OPEN_EXTS:
        raise HTTPException(400, f"仅支持打开 HTML 文件（.html/.htm），不支持: {p.name}")
    if not p.exists():
        raise HTTPException(404, f"文件不存在: {p}")
    if not p.is_file():
        raise HTTPException(400, f"不是文件: {p}")
    # P2-2: 单文件打开也轮换 token（防 token=None 时 live HTML 入口无鉴权）
    global _live_token
    import uuid as _uuid2
    _live_root = p.parent  # Bug5: 记录实景渲染根目录（文件所在目录）
    _live_token = str(_uuid2.uuid4())

    st = p.stat()
    if st.st_size > 10 * 1024 * 1024:
        raise HTTPException(413, f"文件过大（{st.st_size/1024/1024:.1f}MB），超过 10MB 打开上限")
    try:
        content = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise HTTPException(422, "文件不是有效的 UTF-8 编码，无法打开")
    from fastapi.responses import JSONResponse as _JR2
    _resp2 = _JR2(content={
        "ok": True,
        "path": str(p),
        "name": p.name,
        "content": content,
        "size": p.stat().st_size,
        "token": _live_token,
    })
    _resp2.set_cookie("project_token", _live_token, path="/", httponly=True, samesite="lax", max_age=86400)
    return _resp2


# ==================== Bug5: 实景渲染 (Live Render) ====================
# 复杂多文件站点（外部 CSS/JS/图片 + JS 动态生成内容）无法通过 GrapesJS 组件模型
# 正确渲染。实景渲染模式直接以 iframe 加载真实文件（相对路径资源全部原生解析），
# 达到与浏览器直接打开完全一致的"实景"效果。
from fastapi.responses import Response

_LIVE_MIME = {
    ".html": "text/html", ".htm": "text/html", ".css": "text/css",
    ".js": "application/javascript", ".mjs": "application/javascript",
    ".json": "application/json", ".svg": "image/svg+xml",
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon",
    ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf",
    ".txt": "text/plain", ".md": "text/plain",
}


@app.get("/api/live/{rel_path:path}")
async def live_render(rel_path: str, request: Request):
    """在 _live_root 内按相对路径提供真实文件（含 index.html 入口）。
    安全：resolve 后必须仍在 _live_root 之内，防止路径穿越。"""
    if not _live_root:
        raise HTTPException(400, "尚未打开项目/文件，无法实景渲染")
    # 拒绝 NUL 字节等非法字符
    if '\x00' in rel_path or '%00' in rel_path:
        raise HTTPException(400, "路径包含非法字符")
    root = Path(_live_root).resolve()
    if not rel_path or rel_path in ("", "/"):
        rel_path = "index.html"
    target = (root / rel_path).resolve()
    # P1-1: 项目会话 token 校验（所有文件，含子资源；cookie 自动随同源请求发送）
    if _live_token:
        tok = request.headers.get("X-Project-Token") or request.query_params.get("token") or request.cookies.get("project_token")
        if tok != _live_token:
            raise HTTPException(403, "项目会话已过期，请重新打开项目")
    # 防穿越
    try:
        target.relative_to(root)
    except ValueError:
        raise HTTPException(403, "路径越界")
    if target.is_dir():
        target = target / "index.html"
    # 拦截敏感文件（必须在存在性检查之前，避免 404/403 差异泄露文件存在性）
    # P1-2: 大小写不敏感 + 扩展敏感文件列表
    _tname_lower = target.name.lower()
    sensitive = {'.env', '.git', '.gitignore', '.npmrc', '.ssh', '.aws', '.ds_store', 'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa', '.zsh_history', '.bash_history', '.envrc', '.netrc', 'known_hosts', 'authorized_keys', '.zshrc', '.bashrc', '.bash_profile', '.zprofile', '.gitconfig', '.git-credentials', '.profile'}
    if _tname_lower in sensitive or _tname_lower.startswith('.env.') or _tname_lower.endswith('.env') or _tname_lower.startswith('id_rsa.') or target.suffix.lower() in ('.pem', '.key', '.p12', '.pfx') or '.bak.' in _tname_lower:
        raise HTTPException(403, "敏感文件不可通过实景渲染访问")
    _blocked_dirs = {'.git', '.hg', '.svn', '.bzr', 'node_modules', '.ssh', '.aws', '.gnupg', '.kube', '.config', '__pycache__', '.venv', 'venv', '.tox', '.mypy_cache'}
    # P4-3: 用相对 root 的路径段（与 save-raw 一致），避免把项目根自身段误计入
    try:
        _rel_target_parts = target.relative_to(root).parts
    except ValueError:
        _rel_target_parts = target.parts
    if _blocked_dirs & {part.lower() for part in _rel_target_parts}:
        raise HTTPException(403, "禁止访问 .git / node_modules 目录")
    if not target.exists() or not target.is_file():
        raise HTTPException(404, f"文件不存在: {rel_path}")
    mime = _LIVE_MIME.get(target.suffix.lower(), "application/octet-stream")
    # P2-4: 限制 CSP（禁外传数据，仅允许同源+必要 CDN）
    _csp = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: blob: https:; font-src 'self' data: https:; connect-src 'self'; frame-ancestors 'self'"
    return FileResponse(str(target), media_type=mime, headers={"Cache-Control": "no-cache, must-revalidate", "Content-Security-Policy": _csp})


@app.post("/api/live/root")
async def live_root_info(req: OpenRequest, request: Request):
    """返回实景渲染根目录 + 入口文件是否存在（供前端判断能否进入实景模式）"""
    # P3-2: token 校验
    if _live_token:
        tok = request.headers.get("X-Project-Token") or request.cookies.get("project_token")
        if tok != _live_token:
            raise HTTPException(403, "项目会话已过期，请重新打开项目")
    p = _safe_path(req.path)
    # 安全：限制在主目录内，不回显绝对路径给未授权请求
    home = Path.home().resolve()
    if not p.is_relative_to(home):
        raise HTTPException(403, "路径必须在用户主目录内")
    # P3-2: 敏感目录拦截
    _root_blocked = {'.ssh', '.aws', '.gnupg', '.kube', '.config', '.npm', '.cache', '__pycache__', 'node_modules', '.git', 'venv', '.venv'}
    _rel_parts = {part.lower() for part in p.relative_to(home).parts}
    if _root_blocked & _rel_parts:
        raise HTTPException(403, "敏感目录禁止访问")
    # P4-1: entry 基于实际 live 根（_live_root），而非 req.path 所在目录，避免脱节
    root = Path(_live_root).resolve() if _live_root else (p if p.is_dir() else p.parent)
    entry = root / "index.html"
    return {
        "ok": True,
        "root": str(root),
        "entry": str(entry),
        "has_entry": entry.exists(),
        "entry_url": "/api/live/index.html" if entry.exists() else None,
    }


@app.post("/api/browse")
async def browse_dir(req: BrowseRequest):
    """浏览目录，列出 HTML 文件"""
    eff = req.effective_dir
    d = _safe_path(eff) if eff else Path.home()
    home = Path.home().resolve()
    if not d.is_relative_to(home):
        raise HTTPException(403, "浏览目录必须在用户主目录内")
    # 安全：敏感目录黑名单（与 /api/open 一致）
    rel_parts = d.relative_to(home).parts
    _rel_parts_lower = [part.lower() for part in rel_parts]
    # P4-4: 敏感 dotfile/工具目录任意段拦截；macOS 顶层系统目录仅拦第一段（防误伤 ~/Documents/library/）
    _browse_blocked_any = {'.ssh', '.aws', '.gnupg', '.kube', '.config', '.npm', '.cache', '__pycache__', 'node_modules', '.git', 'venv', '.venv'}
    _browse_blocked_toplevel = {'library', '.trash', '.local'}
    if _browse_blocked_any & set(_rel_parts_lower):
        raise HTTPException(403, "敏感目录禁止浏览")
    if _rel_parts_lower and _rel_parts_lower[0] in _browse_blocked_toplevel:
        raise HTTPException(403, "系统目录禁止浏览")
    if not d.exists() or not d.is_dir():
        raise HTTPException(404, f"目录不存在: {d}")

    entries = []
    try:
        items = await asyncio.get_event_loop().run_in_executor(None, lambda: sorted(d.iterdir()))
        # P4: 先过滤隐藏文件再截断（防大目录下文件不可见）
        items = [i for i in items if not i.name.startswith(".")][:500]
        for item in items:
            if item.name.startswith("."):
                continue
            if item.is_dir():
                # P4-1: 跳过指向主目录外的符号链接
                if item.is_symlink():
                    try:
                        if not item.resolve().is_relative_to(home):
                            continue
                    except OSError:
                        continue
                entries.append({"name": item.name + "/", "path": str(item), "type": "dir"})
            elif item.suffix.lower() in req.extensions:
                # P4-4: 跳过指向 home 外的符号链接文件
                if item.is_symlink():
                    try:
                        if not item.resolve().is_relative_to(home):
                            continue
                    except OSError:
                        continue
                try:
                    sz = item.stat().st_size
                except OSError:
                    sz = 0
                entries.append({
                    "name": item.name,
                    "path": str(item),
                    "type": "file",
                    "size": sz,
                })
    except PermissionError:
        pass

    return {
        "ok": True,
        "cwd": str(d),
        "parent": str(d.parent) if d.parent != d else None,
        "entries": entries,
    }


# ---------- 同源预览（解决 srcdoc 继承壳页 CSP + origin=null 问题） ----------
import uuid as _uuid
_preview_store: dict[str, tuple[str, float]] = {}  # token -> (html, created_ts)

class PreviewRequest(BaseModel):
    html: str

@app.post("/api/preview")
async def create_preview(req: PreviewRequest, request: Request):
    """接收编辑器序列化的 HTML，返回同源预览 URL（5分钟有效）"""
    # P3-2: 项目会话 token 校验
    if _live_token:
        tok = request.headers.get("X-Project-Token") or request.cookies.get("project_token")
        if tok != _live_token:
            raise HTTPException(403, "项目会话已过期，请重新打开项目")
    import time as _time
    now = _time.time()
    # 清理过期条目（>5分钟）
    for k in [k for k, (_, ts) in _preview_store.items() if now - ts > 300]:
        _preview_store.pop(k, None)
    # P3-3: 单条大小上限 5MB
    if len(req.html) > 5 * 1024 * 1024:
        raise HTTPException(413, "预览内容超过 5MB 限制")
    if len(_preview_store) > 50:  # 防内存膨胀：驱逐最旧条目而非全清
        oldest_key = min(_preview_store, key=lambda k: _preview_store[k][1])
        _preview_store.pop(oldest_key, None)
    token = _uuid.uuid4().hex[:16]
    _preview_store[token] = (req.html, now)
    return {"ok": True, "url": f"/api/preview/{token}.html"}

@app.get("/api/preview/{token}.html")
async def get_preview(token: str):
    """同源返回预览 HTML（宽松 CSP 由 SecurityHeadersMiddleware 下发）"""
    entry = _preview_store.get(token)
    if not entry:
        # P3: 预览 token 是 bearer 凭证，无效/过期属授权失败 → 403（与全站 token 模型一致）
        raise HTTPException(403, "预览链接无效或已过期")
    # P2-4: 限制预览 CSP
    _preview_csp = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: blob: https:; font-src 'self' data: https:; connect-src 'self'; frame-ancestors 'self'"
    return HTMLResponse(entry[0], headers={"Content-Security-Policy": _preview_csp})


if __name__ == "__main__":
    import uvicorn, os as _osm
    # P4-6: 监听端口与 CSRF 白名单同源（EDITOR_PORT），防直跑换端口时白名单≠监听端口
    uvicorn.run(app, host="127.0.0.1", port=int(_osm.environ.get("EDITOR_PORT", "9100")), server_header=False)
