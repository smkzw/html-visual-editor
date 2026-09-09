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
        for p in preferred..<(preferred + 20) {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: p) else { continue }
            let listener = try NWListener(using: params, on: nwPort)
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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: buf.startIndex..<range.lowerBound)
                let bodyStart = buf[range.upperBound...]
                if let req = Self.parseRequest(head: head) {
                    let need = req.contentLength
                    if bodyStart.count >= need {
                        let body = Data(bodyStart.prefix(need))
                        self.respond(conn: conn, req: req, body: body)
                        return
                    }
                    self.receive(conn: conn, buffer: buf)
                    return
                }
                Self.send(conn: conn, status: 400, body: #"{"detail":"bad request"}"#, contentType: "application/json")
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
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func sendFile(conn: NWConnection, url: URL, mime: String) {
        guard let data = try? Data(contentsOf: url) else {
            send(conn: conn, status: 404, body: #"{"detail":"not found"}"#, contentType: "application/json")
            return
        }
        var h = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var out = Data(h.utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func jsonOK(_ obj: [String: Any], extra: [String: String] = [:]) -> (Int, String) {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
        return (200, String(data: data, encoding: .utf8) ?? "{}")
    }

    private func respond(conn: NWConnection, req: Req, body: Data) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        let isSafe = req.method == "GET" || req.method == "HEAD"

        if !isSafe {
            let host = req.headers["host"] ?? ""
            let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
            let xrw = req.headers["x-requested-with"] ?? ""
            if !allowed.contains(host) || xrw.isEmpty {
                Self.send(conn: conn, status: 403, body: #"{"detail":"CSRF"}"#, contentType: "application/json")
                return
            }
        }

        switch true {
        case path == "/api/info":
            let (c, s) = jsonOK(["platform": "macos", "native_picker": true])
            Self.send(conn: conn, status: c, body: s, contentType: "application/json")
        case path == "/" || path == "/index.html":
            Self.sendFile(conn: conn, url: staticDir.appendingPathComponent("index.html"), mime: "text/html; charset=utf-8")
        case path.hasPrefix("/static/"):
            let rel = String(path.dropFirst("/static/".count))
            Self.sendFile(conn: conn, url: staticDir.appendingPathComponent(rel), mime: "application/octet-stream")
        case path.hasPrefix("/api/live/"):
            live(conn: conn, req: req, rel: String(path.dropFirst("/api/live/".count)))
        case path.hasPrefix("/api/preview/") && req.method == "GET":
            let tok = path.components(separatedBy: "/").last?.replacingOccurrences(of: ".html", with: "") ?? ""
            stateLock.lock(); let entry = previews[tok]; stateLock.unlock()
            if let entry {
                Self.send(conn: conn, status: 200, body: entry.html, contentType: "text/html; charset=utf-8")
            } else {
                Self.send(conn: conn, status: 403, body: #"{"detail":"预览无效"}"#, contentType: "application/json")
            }
        case path == "/api/project/open" && req.method == "POST":
            projectOpen(conn: conn, body: body)
        case path == "/api/project/read" && req.method == "POST":
            projectRead(conn: conn, body: body)
        case path == "/api/project/save-raw" && req.method == "POST":
            projectSave(conn: conn, body: body)
        case path == "/api/preview" && req.method == "POST":
            previewCreate(conn: conn, body: body)
        case path == "/api/analyze" && req.method == "POST":
            analyze(conn: conn, body: body)
        default:
            Self.send(conn: conn, status: 404, body: #"{"detail":"not found"}"#, contentType: "application/json")
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
        guard d.path.hasPrefix(home.path) else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"项目必须在用户主目录内"}"#, contentType: "application/json")
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
        } else if let en = fm.enumerator(at: d, includingPropertiesForKeys: nil) {
            var count = 0
            for case let u as URL in en {
                if u.lastPathComponent.hasPrefix(".") { continue }
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
                if count >= 2000 { break }
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
        let (c, s) = jsonOK(payload)
        Self.send(conn: conn, status: c, body: s, contentType: "application/json")
    }

    private func projectRead(conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let path = obj["path"] as? String ?? ""
        stateLock.lock(); let r = root; stateLock.unlock()
        guard let r else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"请先打开项目"}"#, contentType: "application/json")
            return
        }
        let p = URL(fileURLWithPath: path).standardizedFileURL
        guard p.path.hasPrefix(r.path) else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"文件必须在项目内"}"#, contentType: "application/json")
            return
        }
        guard let content = try? String(contentsOf: p, encoding: .utf8) else {
            Self.send(conn: conn, status: 404, body: #"{"detail":"无法读取"}"#, contentType: "application/json")
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
        Self.send(conn: conn, status: c, body: s, contentType: "application/json")
    }

    private func projectSave(conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let path = obj["path"] as? String ?? ""
        let content = obj["content"] as? String ?? ""
        let mtime = obj["mtime"] as? Double ?? 0
        stateLock.lock(); let r = root; stateLock.unlock()
        guard let r else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"请先打开项目"}"#, contentType: "application/json")
            return
        }
        let p = URL(fileURLWithPath: path).standardizedFileURL
        guard p.path.hasPrefix(r.path) else {
            Self.send(conn: conn, status: 403, body: #"{"detail":"不在项目内"}"#, contentType: "application/json")
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: p.path) {
            let st = (try? fm.attributesOfItem(atPath: p.path)) ?? [:]
            let cur = (st[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if abs(cur - mtime) > 1.0 {
                Self.send(conn: conn, status: 409, body: #"{"detail":"文件已被外部修改"}"#, contentType: "application/json")
                return
            }
            let bak = p.path + ".bak.\(Int(Date().timeIntervalSince1970))"
            try? fm.copyItem(atPath: p.path, toPath: bak)
        }
        try? content.write(to: p, atomically: true, encoding: .utf8)
        let st = (try? fm.attributesOfItem(atPath: p.path)) ?? [:]
        let (c, s) = jsonOK([
            "ok": true, "path": p.path, "size": content.utf8.count,
            "mtime": (st[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
        ])
        Self.send(conn: conn, status: c, body: s, contentType: "application/json")
    }

    private func previewCreate(conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let html = obj["html"] as? String ?? ""
        let tok = UUID().uuidString.prefix(16).description
        stateLock.lock()
        previews[tok] = (html, Date().timeIntervalSince1970)
        stateLock.unlock()
        let (c, s) = jsonOK(["ok": true, "url": "/api/preview/\(tok).html"])
        Self.send(conn: conn, status: c, body: s, contentType: "application/json")
    }

    private func analyze(conn: NWConnection, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let path = obj["path"] as? String ?? ""
        let p = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) else {
            Self.send(conn: conn, status: 404, body: #"{"detail":"不存在"}"#, contentType: "application/json")
            return
        }
        let mode = isDir.boolValue ? "site" : "single"
        let (c, s) = jsonOK([
            "ok": true, "mode": mode, "dir": p.deletingLastPathComponent().path,
            "file": p.path, "entry": p.path, "html_count": 1, "reason": "本地文件",
        ])
        Self.send(conn: conn, status: c, body: s, contentType: "application/json")
    }

    private func live(conn: NWConnection, req: Req, rel: String) {
        stateLock.lock(); let r = root; stateLock.unlock()
        guard let r else {
            Self.send(conn: conn, status: 400, body: #"{"detail":"尚未打开项目"}"#, contentType: "application/json")
            return
        }
        let decoded = rel.removingPercentEncoding ?? rel
        var target = r.appendingPathComponent(decoded).standardizedFileURL
        if !target.path.hasPrefix(r.path) {
            Self.send(conn: conn, status: 403, body: #"{"detail":"路径越界"}"#, contentType: "application/json")
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            target = target.appendingPathComponent("index.html")
        }
        let mime: String
        switch target.pathExtension.lowercased() {
        case "html", "htm": mime = "text/html; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        case "js", "mjs": mime = "application/javascript; charset=utf-8"
        case "json": mime = "application/json"
        case "svg": mime = "image/svg+xml"
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "ico": mime = "image/x-icon"
        default: mime = "application/octet-stream"
        }
        Self.sendFile(conn: conn, url: target, mime: mime)
    }

    private func reqHeaders(_ conn: NWConnection) -> Req {
        Req(method: "GET", path: "/", headers: [:])
    }
}
