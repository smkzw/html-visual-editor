import Foundation
import Network

/// Minimal localhost HTTP server (stdlib-equivalent) for project open/read/save + live render.
/// Avoids spawning Python as a GUI child (POST body stall on this machine).
final class LocalHTTPServer {
    private var listener: NWListener?
    private(set) var port: UInt16 = 9100
    private let queue = DispatchQueue(label: "jiba.http")

    private var root: URL?
    private var token: String?
    private var previews: [String: (html: String, ts: TimeInterval)] = [:]
    private let stateLock = NSLock()

    private var staticDir: URL {
        Bundle.main.resourceURL?.appendingPathComponent("app/static")
            ?? URL(fileURLWithPath: "src/app/static")
    }
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    func start(preferred: UInt16 = 9100) throws {
        for p in preferred..<(preferred + 40) {
            let params = NWParameters.tcp
            // NO allowLocalEndpointReuse: with it, a second app instance can bind
            // the same port while an old instance still listens, and requests get
            // split between two servers with different project roots → phantom 404s.
            // If the port is truly taken (or in TIME_WAIT), fall through to p+1.
            // Loopback ONLY — the engine serves local files and must never be
            // reachable from the network.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1" as NWEndpoint.Host, port: NWEndpoint.Port(rawValue: p)!)
            guard let nwPort = NWEndpoint.Port(rawValue: p) else { continue }
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    self.port = p
                }
            }
            listener.start(queue: queue)
            // brief settle
            Thread.sleep(forTimeInterval: 0.15)
            if case .ready = listener.state {
                self.listener = listener
                self.port = p
                return
            }
            listener.cancel()
        }
        throw NSError(domain: "HTTP", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法绑定端口"])
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    // MARK: - Connection

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn: conn, buffer: Data())
    }

    private func receive(conn: NWConnection, buffer: Data) {
        // Hard cap: header + body must stay well under this (page saves are
        // at most a few MB). Prevents unbounded memory growth.
        let maxRequest: Int = 64 * 1024 * 1024
        if buffer.count > maxRequest {
            Self.send(conn: conn, status: 413, body: #"{"detail":"请求过大"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: buf.startIndex..<range.lowerBound)
                let bodyStart = buf[range.upperBound...]
                if let req = Self.parseRequest(head: head) {
                    let need = req.contentLength
                    guard need >= 0, buf.count - (bodyStart.startIndex - buf.startIndex) <= maxRequest else {
                        Self.send(conn: conn, status: 400, body: #"{"detail":"bad request length"}"#, contentType: "application/json; charset=utf-8")
                        return
                    }
                    if bodyStart.count >= need {
                        let body = Data(bodyStart.prefix(need))
                        self.respond(conn: conn, req: req, body: body)
                        return
                    }
                    self.receive(conn: conn, buffer: buf)
                    return
                }
                Self.send(conn: conn, status: 400, body: #"{"detail":"bad request"}"#, contentType: "application/json; charset=utf-8")
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn: conn, buffer: buf)
        }
    }

    struct Req {
        var method: String
        var path: String
        var headers: [String: String]
        var contentLength: Int { Int(headers["content-length"] ?? "0") ?? 0 }
    }

    private static func parseRequest(head: Data) -> Req? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        return Req(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }

    private static func send(conn: NWConnection, status: Int, body: String, contentType: String = "text/plain; charset=utf-8", extra: [String: String] = [:]) {
        let data = Data(body.utf8)
        var h = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "ERR")\r\n"
        h += "Content-Type: \(contentType)\r\n"
        h += "Content-Length: \(data.count)\r\n"
        h += "X-Content-Type-Options: nosniff\r\n"
        h += "Connection: close\r\n"
        for (k, v) in extra { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in
            // contentProcessed = kernel accepted the bytes; an immediate cancel
            // RSTs large responses mid-flight (WebKit drops the css/js). Drain first.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { conn.cancel() }
        })
    }

    private static func sendFile(conn: NWConnection, url: URL, mime: String) {
        guard let data = try? Data(contentsOf: url) else {
            send(conn: conn, status: 404, body: #"{"detail":"not found"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        var h = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var out = Data(h.utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in
            // contentProcessed = kernel accepted the bytes; an immediate cancel
            // RSTs large responses mid-flight (WebKit drops the css/js). Drain first.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { conn.cancel() }
        })
    }

    private func jsonOK(_ obj: [String: Any], extra: [String: String] = [:]) -> (Int, String) {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
        return (200, String(data: data, encoding: .utf8) ?? "{}")
    }

    private func respond(conn: NWConnection, req: Req, body: Data) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        FileHandle.standardError.write(Data("[req] \(req.method) \(path.prefix(100))\n".utf8))
        let isSafe = req.method == "GET" || req.method == "HEAD"

        if !isSafe {
            let host = req.headers["host"] ?? ""
            let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
            let xrw = req.headers["x-requested-with"] ?? ""
            if !allowed.contains(host) || xrw.isEmpty {
                Self.send(conn: conn, status: 403, body: #"{"detail":"CSRF"}"#, contentType: "application/json; charset=utf-8")
                return
            }
        }

        switch true {
        case path == "/api/info":
            let (c, s) = jsonOK(["platform": "macos", "native_picker": true])
            Self.send(conn: conn, status: c, body: s, contentType: "application/json; charset=utf-8")
        case path == "/" || path == "/index.html":
            // The bundled legacy web editor is not served at "/" — it was kept for
            // reference but its session protocol diverged from this engine and it
            // dead-ends with confusing errors. Point people to the app instead.
            Self.send(conn: conn, status: 200, body: Self.errorPage(
                title: "HTML辑霸 引擎运行中",
                detail: "本引擎只服务于 HTML辑霸 App（127.0.0.1:\(port)）。\n请打开 App 进行编辑；本页面不是编辑器界面。"),
                contentType: "text/html; charset=utf-8")
        case path.hasPrefix("/static/"):
            let rel = String(path.dropFirst("/static/".count))
            let fp = staticDir.appendingPathComponent(rel).standardizedFileURL
            guard fp.path.hasPrefix(staticDir.path + "/") else {
                Self.send(conn: conn, status: 403, body: #"{"detail":"forbidden"}"#, contentType: "application/json; charset=utf-8")
                return
            }
            Self.sendFile(conn: conn, url: fp, mime: "application/octet-stream")
        case path.hasPrefix("/api/live/"):
            // URL-carried session: /api/live/<token>/<rel>. Sub-resource requests
            // (css/js/img) do not reliably carry cookies in WKWebView (observed:
            // zero Cookie header after a session switch), so the token must ride
            // in the path — the injected <base> makes every relative reference
            // include it automatically.
            let rest = path.dropFirst("/api/live/".count)
            let seg = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let pathToken = seg.first.map(String.init) ?? ""
            stateLock.lock(); let expected = token; stateLock.unlock()
            guard !pathToken.isEmpty, pathToken == expected, seg.count == 2 else {
                Self.send(conn: conn, status: 403, body: #"{"detail":"项目会话已过期，请重新打开文件"}"#, contentType: "application/json; charset=utf-8")
                return
            }
            live(conn: conn, req: req, sessionToken: pathToken, rel: String(seg[1]))
        case path.hasPrefix("/api/preview/") && req.method == "GET":
            let tok = path.components(separatedBy: "/").last?.replacingOccurrences(of: ".html", with: "") ?? ""
            stateLock.lock(); let entry = previews[tok]; stateLock.unlock()
            if let entry {
                Self.send(conn: conn, status: 200, body: entry.html, contentType: "text/html; charset=utf-8")
            } else {
                Self.send(conn: conn, status: 403, body: #"{"detail":"预览无效"}"#, contentType: "application/json; charset=utf-8")
            }
        case path == "/api/project/open" && req.method == "POST":
            projectOpen(conn: conn, body: body)
        case path == "/api/project/read" && req.method == "POST":
            projectRead(conn: conn, req: req, body: body)
        case path == "/api/project/save-raw" && req.method == "POST":
            projectSave(conn: conn, req: req, body: body)
        case path == "/api/preview" && req.method == "POST":
            previewCreate(conn: conn, body: body)
        case path == "/api/analyze" && req.method == "POST":
            analyze(conn: conn, body: body)
        case path.hasPrefix("/api/") || path.hasPrefix("/api"):
            Self.send(conn: conn, status: 404, body: #"{"detail":"not found"}"#, contentType: "application/json; charset=utf-8")
        default:
            // Root-relative resources (/style.css, /about, /favicon.ico): when a
            // project is open, resolve them against the project root so real
            // site projects render with their absolute-path assets.
            if req.method == "GET", tokenOK(req), !path.contains("..") {
                stateLock.lock(); let r = root; stateLock.unlock()
                if let r {
                    let raw = String(path.dropFirst())
                    let rel = raw.removingPercentEncoding ?? raw
                    var target = r.appendingPathComponent(rel).standardizedFileURL
                    guard target.path.hasPrefix(r.path + "/") else {
                        Self.send(conn: conn, status: 403, body: #"{"detail":"路径越界"}"#, contentType: "application/json; charset=utf-8")
                        return
                    }
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
                        target = target.appendingPathComponent("index.html")
                    }
                    if FileManager.default.fileExists(atPath: target.path) {
                        let ext = target.pathExtension.lowercased()
                        let mime: String
                        switch ext {
                        case "html", "htm": mime = "text/html; charset=utf-8"
                        case "css": mime = "text/css; charset=utf-8"
                        case "js", "mjs": mime = "application/javascript; charset=utf-8"
                        case "json": mime = "application/json; charset=utf-8"
                        case "svg": mime = "image/svg+xml"
                        case "png": mime = "image/png"
                        case "jpg", "jpeg": mime = "image/jpeg"
                        case "gif": mime = "image/gif"
                        case "webp": mime = "image/webp"
                        case "ico": mime = "image/x-icon"
                        case "woff": mime = "font/woff"
                        case "woff2": mime = "font/woff2"
                        case "ttf": mime = "font/ttf"
                        default: mime = "application/octet-stream"
                        }
                        Self.sendFile(conn: conn, url: target, mime: mime)
                        return
                    }
                }
            }
            Self.send(conn: conn, status: 404, body: #"{"detail":"not found"}"#, contentType: "application/json; charset=utf-8")
        }
    }

    private func tokenOK(_ req: Req) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let token else { return true }
        let got = req.headers["x-project-token"]
            ?? req.headers["cookie"]?.components(separatedBy: "project_token=").last?.components(separatedBy: ";").first
        return got == token
    }

    private func projectOpen(conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let file = obj["file"] as? String ?? ""
        let dir = obj["dir"] as? String ?? ""
        let raw = file.isEmpty ? dir : file
        let p = URL(fileURLWithPath: raw).standardizedFileURL
        let d = file.isEmpty ? p : p.deletingLastPathComponent()
        guard d.path.hasPrefix(home.path + "/") || d.path == home.path else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"项目必须在用户主目录内"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        // Existence check — a missing path must not yield a fake empty project
        // (and must not rotate the session token of the project being edited).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) else {
            let (_, body) = jsonOK(["detail": "文件或目录不存在：\(raw)"])
            Self.send(conn: conn, status: 404, body: body, contentType: "application/json; charset=utf-8")
            return
        }
        if file.isEmpty && !isDir.boolValue {
            Self.send(conn: conn, status: 400, body: #"{"detail":"所选路径不是文件夹"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        if !file.isEmpty && isDir.boolValue {
            Self.send(conn: conn, status: 400, body: #"{"detail":"所选路径是文件夹，请用打开文件夹"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        var files: [[String: Any]] = []
        let fm = FileManager.default
        if !file.isEmpty {
            files.append([
                "name": p.lastPathComponent, "rel": p.lastPathComponent, "path": p.path,
                "ext": p.pathExtension.lowercased(), "size": (try? fm.attributesOfItem(atPath: p.path)[.size] as? Int) ?? 0,
                "mtime": ((try? fm.attributesOfItem(atPath: p.path)[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970,
                "editable": true,
            ])
        } else if let en = fm.enumerator(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var count = 0
            let skipDirs: Set<String> = ["node_modules", "__pycache__", "DerivedData", "venv", ".venv"]
            outer: for case let u as URL in en {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    if skipDirs.contains(u.lastPathComponent) { en.skipDescendants() }
                    continue
                }
                let ext = u.pathExtension.lowercased()
                guard ["html", "htm", "css", "js", "json", "svg", "png", "jpg", "jpeg", "gif", "webp", "ico"].contains(ext) else { continue }
                let st = (try? fm.attributesOfItem(atPath: u.path)) ?? [:]
                let rel = u.path.hasPrefix(d.path) ? String(u.path.dropFirst(d.path.count).drop(while: { $0 == "/" })) : u.lastPathComponent
                files.append([
                    "name": u.lastPathComponent, "rel": rel, "path": u.path, "ext": ext,
                    "size": (st[.size] as? Int) ?? 0,
                    "mtime": (st[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                    "editable": ["html", "htm", "css", "js", "json", "svg"].contains(ext),
                ])
                count += 1
                if count >= 2000 { break outer }
            }
        }
        let pages = files.filter { ($0["ext"] as? String) == "html" || ($0["ext"] as? String) == "htm" }
        let css = files.filter { ($0["ext"] as? String) == "css" }
        let js = files.filter { ($0["ext"] as? String) == "js" }
        let tok = UUID().uuidString
        stateLock.lock()
        root = d
        token = tok
        stateLock.unlock()
        let payload: [String: Any] = [
            "ok": true, "dir": d.path, "name": d.lastPathComponent, "token": tok,
            "files": files, "pages": pages, "css": css, "js": js,
            "is_split": !pages.isEmpty && (!css.isEmpty || !js.isEmpty),
            "is_multipage": pages.count > 1,
        ]
        let (_, s) = jsonOK(payload)
        // Session cookie for web-origin requests (the native app sends the header;
        // browser-loaded pages can only authenticate via cookie).
        let cookie = "project_token=\(tok); Path=/; HttpOnly; SameSite=Lax"
        Self.send(conn: conn, status: 200, body: s, contentType: "application/json; charset=utf-8",
                  extra: ["Set-Cookie": cookie])
    }

    private func projectRead(conn: NWConnection, req: Req, body: Data) {
        guard tokenOK(req) else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"项目会话已过期"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let path = obj["path"] as? String ?? ""
        stateLock.lock(); let r = root; stateLock.unlock()
        guard let r else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"请先打开项目"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let p = URL(fileURLWithPath: path).standardizedFileURL
        guard p.path.hasPrefix(r.path + "/") else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"文件必须在项目内"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        guard let content = try? String(contentsOf: p, encoding: .utf8) else {
            Self.send(conn: conn, status: 404, body: #"{"detail":"无法读取"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let st = (try? FileManager.default.attributesOfItem(atPath: p.path)) ?? [:]
        let payload: [String: Any] = [
            "ok": true, "path": p.path, "name": p.lastPathComponent,
            "ext": p.pathExtension.lowercased(), "content": content,
            "size": (st[.size] as? Int) ?? 0,
            "mtime": (st[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
        ]
        let (c, s) = jsonOK(payload)
        Self.send(conn: conn, status: c, body: s, contentType: "application/json; charset=utf-8")
    }

    private func projectSave(conn: NWConnection, req: Req, body: Data) {
        guard tokenOK(req) else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"项目会话已过期"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let path = obj["path"] as? String ?? ""
        let content = obj["content"] as? String ?? ""
        let mtime = obj["mtime"] as? Double ?? 0
        stateLock.lock(); let r = root; stateLock.unlock()
        guard let r else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"请先打开项目"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let p = URL(fileURLWithPath: path).standardizedFileURL
        guard p.path.hasPrefix(r.path + "/") else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"不在项目内"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir), !isDir.boolValue else {
            Self.send(conn: conn, status: 400, body: #"{"detail":"保存目标不是文件"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: p.path) {
            let st = (try? fm.attributesOfItem(atPath: p.path)) ?? [:]
            let cur = (st[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if abs(cur - mtime) > 1.0 {
                Self.send(conn: conn, status: 409, body: #"{"detail":"文件已被外部修改"}"#, contentType: "application/json; charset=utf-8")
                return
            }
            // Millisecond stamp + rotation: same-second saves must not clobber
            // the previous backup, and .bak files must not pile up forever.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
            let bak = p.path + ".bak." + fmt.string(from: Date())
            do {
                try fm.copyItem(atPath: p.path, toPath: bak)
                // Rotation only trims old .bak files — run it OFF the serial HTTP
                // queue: a transient filesystem stall in directory enumeration
                // deadlocked the whole engine (observed), so it must never run
                // inline here.
                let target = p
                DispatchQueue.global(qos: .utility).async {
                    Self.rotateBackups(of: target, keep: 20)
                }
            } catch {
                Self.send(conn: conn, status: 500, body: "{\"detail\":\"备份失败，未写入: \(error.localizedDescription)\"}", contentType: "application/json; charset=utf-8")
                return
            }
        }
        do {
            try content.write(to: p, atomically: true, encoding: .utf8)
        } catch {
            Self.send(conn: conn, status: 500, body: "{\"detail\":\"写入失败: \(error.localizedDescription)\"}", contentType: "application/json; charset=utf-8")
            return
        }
        let st = (try? fm.attributesOfItem(atPath: p.path)) ?? [:]
        let (c, s) = jsonOK([
            "ok": true, "path": p.path, "size": content.utf8.count,
            "mtime": (st[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
        ])
        Self.send(conn: conn, status: c, body: s, contentType: "application/json; charset=utf-8")
    }

    /// Keep the `keep` most recently MODIFIED .bak files next to `p`.
    /// Runs off the HTTP queue. mtime order (not lexical): foreign tools that
    /// also write `*.bak.<hash>` must not crowd out real timestamped backups.
    static func rotateBackups(of p: URL, keep: Int) {
        let fm = FileManager.default
        let dir = p.deletingLastPathComponent()
        let stem = p.lastPathComponent + ".bak."
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let dated = items.filter { $0.hasPrefix(stem) }.map { name -> (String, Date) in
            let url = dir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (name, (attrs?[.modificationDate] as? Date) ?? .distantPast)
        }
        for (i, entry) in dated.sorted(by: { $0.1 > $1.1 }).enumerated() where i >= keep {
            try? fm.removeItem(atPath: dir.appendingPathComponent(entry.0).path)
        }
    }

    private func previewCreate(conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let html = obj["html"] as? String ?? ""
        stateLock.lock()
        let now = Date().timeIntervalSince1970
        for k in previews.keys where now - previews[k]!.ts > 300 {
            previews.removeValue(forKey: k)
        }
        let tok = UUID().uuidString.prefix(16).description
        previews[tok] = (html, now)
        stateLock.unlock()
        let (c, s) = jsonOK(["ok": true, "url": "/api/preview/\(tok).html"])
        Self.send(conn: conn, status: c, body: s, contentType: "application/json; charset=utf-8")
    }

    private func analyze(conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let path = obj["path"] as? String ?? ""
        let p = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) else {
            Self.send(conn: conn, status: 404, body: #"{"detail":"不存在"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let mode = isDir.boolValue ? "site" : "single"
        let (c, s) = jsonOK([
            "ok": true, "mode": mode, "dir": p.deletingLastPathComponent().path,
            "file": p.path, "entry": p.path, "html_count": 1, "reason": "本地文件",
        ])
        Self.send(conn: conn, status: c, body: s, contentType: "application/json; charset=utf-8")
    }

    private func live(conn: NWConnection, req: Req, sessionToken: String, rel: String) {
        FileHandle.standardError.write(Data("[live] rel=\(rel.prefix(80))\n".utf8))
        stateLock.lock(); let r = root; stateLock.unlock()
        guard let r else {
            Self.send(conn: conn, status: 400, body: #"{"detail":"尚未打开项目"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        let decoded = rel.removingPercentEncoding ?? rel
        var target = r.appendingPathComponent(decoded).standardizedFileURL
        if !target.path.hasPrefix(r.path + "/") {
            Self.send(conn: conn, status: 403, body: #"{"detail":"路径越界"}"#, contentType: "application/json; charset=utf-8")
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            target = target.appendingPathComponent("index.html")
        }
        let ext = target.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "html", "htm": mime = "text/html; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        case "js", "mjs": mime = "application/javascript; charset=utf-8"
        case "json": mime = "application/json; charset=utf-8"
        case "svg": mime = "image/svg+xml"
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "ico": mime = "image/x-icon"
        case "woff": mime = "font/woff"
        case "woff2": mime = "font/woff2"
        case "ttf": mime = "font/ttf"
        default: mime = "application/octet-stream"
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            FileHandle.standardError.write(Data("[live] MISS target=\(target.path)\n".utf8))
            // Friendly light-styled page — a bare JSON 404 renders as an
            // unreadable black screen in the webview (dark default text).
            Self.send(conn: conn, status: 404, body: Self.errorPage(
                title: "页面不存在",
                detail: "在项目目录中找不到 \(decoded)。\n可能文件已被移动、重命名，或会话已切换到其他项目。请重新打开文件。"),
                contentType: "text/html; charset=utf-8")
            return
        }
        // Inject <base> so root-relative assets (/style.css) resolve under /api/live/
        if ext == "html" || ext == "htm" {
            guard var html = try? String(contentsOf: target, encoding: .utf8) else {
                Self.sendFile(conn: conn, url: target, mime: mime)
                return
            }
            // Directory of this file relative to live root → base path.
            // HTML-attribute-escaped: the path segments come from the request URL
            // and a hostile directory name must not break out of the attribute.
            let dirRel = String(decoded).components(separatedBy: "/").dropLast().joined(separator: "/")
            let esc: (String) -> String = { s in
                s.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            let baseHref = dirRel.isEmpty
                ? "/api/live/\(sessionToken)/"
                : "/api/live/\(sessionToken)/" + esc(dirRel) + "/"
            let baseTag = "<base href=\"\(baseHref)\">"
            if let r = html.range(of: "<head[^>]*>", options: .regularExpression) {
                html.insert(contentsOf: baseTag, at: r.upperBound)
            } else if let r = html.range(of: "<html[^>]*>", options: .regularExpression) {
                html.insert(contentsOf: "<head>\(baseTag)</head>", at: r.upperBound)
            } else {
                html = baseTag + html
            }
            let data = Data(html.utf8)
            // Re-issue the session cookie on every main-document response: after
            // a session switch the webview's sub-resource requests carry only
            // the cookie (no header), and a stale one kills every CSS/JS file
            // (page renders as bare text).
            let cookie = "project_token=\(stateLock.withLock { token ?? "" }); Path=/; HttpOnly; SameSite=Lax"
            var h = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nSet-Cookie: \(cookie)\r\n\r\n"
            var out = Data(h.utf8); out.append(data)
            conn.send(content: out, completion: .contentProcessed { _ in
            // contentProcessed = kernel accepted the bytes; an immediate cancel
            // RSTs large responses mid-flight (WebKit drops the css/js). Drain first.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { conn.cancel() }
        })
            return
        }
        Self.sendFile(conn: conn, url: target, mime: mime)
    }

    /// Light-only inline error page for live render failures.
    static func errorPage(title: String, detail: String) -> String {
        let esc = detail
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><title>\(title)</title>
        <style>body{margin:0;font-family:PingFang SC,sans-serif;background:#f5f6f8;color:#0f1115;
        display:flex;align-items:center;justify-content:center;min-height:100vh}
        .card{background:#fff;border-radius:16px;padding:40px 48px;max-width:460px;
        box-shadow:0 8px 32px rgba(0,0,0,.08);border-top:4px solid #ff9900}
        h1{font-size:20px;margin:0 0 12px}p{font-size:14px;line-height:1.8;color:#525a66;white-space:pre-wrap;margin:0}</style>
        </head><body><div class="card"><h1>⚠️ \(title)</h1><p>\(esc)</p></div></body></html>
        """
    }
}
