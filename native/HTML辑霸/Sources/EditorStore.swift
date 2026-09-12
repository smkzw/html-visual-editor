import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    static let shared = EditorStore()

    @Published var phase: Phase = .landing
    @Published var project: ProjectInfo?
    @Published var pages: [PageFile] = []
    @Published var currentPage: PageFile?
    @Published var selectedTag: String?
    @Published var selectedLabel: String?
    @Published var dirty = false
    @Published var presenting = false
    @Published var zoom: CGFloat = 1.0
    @Published var deviceW: CGFloat = 1280
    @Published var deviceH: CGFloat = 800
    @Published var isPPT = false
    @Published var pptIndex = 0
    @Published var pptCount = 0
    @Published var slides: [SlideInfo] = []
    @Published var toast: String?
    @Published var styleSnapshot: StyleSnapshot = .init()
    @Published var animName: String = ""
    @Published var animTrigger: String = "load"
    @Published var liveToken: String?

    /// Set when the user chose "保存并退出"; terminates the app once save completes.
    var terminateAfterSave = false

    enum Phase { case landing, editor }

    weak var webView: (any EditorWebControlling)?

    private var toastTask: Task<Void, Never>?

    // MARK: - Unsaved-changes guard

    /// Returns true if it is OK to drop the current page state.
    /// Shows a native confirm when there are unsaved edits.
    func confirmDiscard(verb: String = "放弃当前修改") -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "有未保存的修改"
        alert.informativeText = "离开将丢失画布上未保存的修改。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveCurrent()
            return true // proceed; save is async and posts its own toast on failure
        case .alertSecondButtonReturn:
            dirty = false
            return true
        default:
            return false
        }
    }

    // MARK: - Open

    func pickAndOpen(preferFile: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = !preferFile
        panel.allowsMultipleSelection = false
        panel.message = preferFile ? "选择 HTML 网页文件" : "选择项目文件夹"
        panel.prompt = "打开"
        if preferFile { panel.allowedContentTypes = [.html] }
        if panel.runModal() == .OK, let url = panel.url {
            guard confirmDiscard(verb: "不保存，直接打开") else { return }
            if url.hasDirectoryPath {
                openProject(dir: url.path)
            } else {
                openSingleFile(path: url.path)
            }
        }
    }

    func openProject(dir: String) {
        Task {
            do {
                let p: ProjectOpenResponse = try await API.post("/api/project/open", ["dir": dir])
                applyProject(p)
            } catch {
                showToast(error.localizedDescription, icon: "⚠")
            }
        }
    }

    func openSingleFile(path: String) {
        Task {
            do {
                let p: ProjectOpenResponse = try await API.post("/api/project/open", ["dir": "", "file": path])
                applyProject(p)
            } catch {
                showToast(error.localizedDescription, icon: "⚠")
            }
        }
    }

    func openSample(_ file: String) {
        let samples = Bundle.main.resourceURL?
            .appendingPathComponent("app/samples/\(file)").path
            ?? (FileManager.default.currentDirectoryPath + "/src/app/samples/\(file)")
        if FileManager.default.fileExists(atPath: samples) {
            guard confirmDiscard(verb: "不保存，直接打开") else { return }
            openSingleFile(path: samples)
        } else {
            showToast("未找到示例文件", icon: "⚠")
        }
    }

    private func applyProject(_ p: ProjectOpenResponse) {
        project = ProjectInfo(dir: p.dir, name: p.name, token: p.token)
        liveToken = p.token
        pages = p.pages
        phase = .editor
        dirty = false
        let entry = pages.first { $0.name.lowercased().contains("index") } ?? pages.first
        if let entry { loadPage(entry, force: true) }
        showToast("已打开「\(p.name)」· \(pages.count) 个页面")
    }

    func goHome() {
        guard confirmDiscard(verb: "不保存，返回首页") else { return }
        phase = .landing
        project = nil
        pages = []
        currentPage = nil
        selectedTag = nil
        dirty = false
        isPPT = false
        slides = []
        webView?.loadBlank()
    }

    // MARK: - Page

    func loadPage(_ page: PageFile, force: Bool = false) {
        if !force && page.path == currentPage?.path { return }
        if !force { guard confirmDiscard(verb: "不保存，切换页面") else { return } }
        currentPage = page
        dirty = false
        selectedTag = nil
        styleSnapshot = .init()
        let base = BackendManager.shared.baseURL
        // DO NOT use appendingPathComponent("api/live/xxx") — it percent-encodes "/" as %2F
        // and every live page becomes a blank 404.
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let encodedRel = page.rel.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        comps.path = "/api/live/" + encodedRel
        guard let url = comps.url else {
            showToast("页面地址无效", icon: "⚠")
            return
        }
        webView?.load(url: url, token: liveToken)
    }

    func saveCurrent() {
        webView?.requestSave()
    }

    func saveAndTerminate() {
        terminateAfterSave = true
        saveCurrent()
        // Safety: if save never reports back (page gone), quit after a grace period.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.terminateAfterSave { NSApp.terminate(nil) }
        }
    }

    func onSaved(ok: Bool) {
        if ok && terminateAfterSave {
            terminateAfterSave = false
            NSApp.terminate(nil)
        }
    }

    func enterPresent() {
        guard currentPage != nil else { return }
        presenting = true
        webView?.requestPresent()
    }

    func exitPresent() {
        presenting = false
        webView?.exitPresent()
    }

    // MARK: - Bridge callbacks

    func onSelectionChanged(tag: String?, label: String?, style: StyleSnapshot, anim: String, trigger: String) {
        selectedTag = tag
        selectedLabel = label
        styleSnapshot = style
        animName = anim
        animTrigger = trigger.isEmpty ? "load" : trigger
    }

    func onDirty() { dirty = true }

    func onPPT(active: Bool, index: Int, count: Int, slides: [SlideInfo]) {
        isPPT = active
        pptIndex = index
        pptCount = count
        self.slides = slides
    }

    func showToast(_ msg: String, icon: String = "✓") {
        toast = "\(icon) \(msg)"
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: - Commands to web

    private func requireSelection() -> Bool {
        guard styleSnapshot.hasSelection, selectedTag != nil else {
            showToast("请先单击画布中的元素", icon: "ℹ")
            return false
        }
        return true
    }

    func applyStyle(_ dict: [String: String]) {
        guard requireSelection() else { return }
        webView?.eval("window.__jiba.applyStyle(\(dict.jsObjectLiteral))")
    }
    func applyAnim(name: String, dur: Double, delay: Double, ease: String, iter: Int, trigger: String = "load") {
        guard requireSelection() else { return }
        webView?.eval("window.__jiba.applyAnim('\(name)',\(dur),\(delay),'\(ease)',\(iter),'\(trigger)')")
    }
    func clearAnim() { webView?.eval("window.__jiba.clearAnim()") }
    func previewAnim() { webView?.eval("window.__jiba.previewAnim()") }
    func align(_ mode: String) {
        guard requireSelection() else { return }
        webView?.eval("window.__jiba.align('\(mode)')")
    }
    func deleteSelected() {
        guard requireSelection() else { return }
        webView?.eval("window.__jiba.deleteSelected()")
    }
    func duplicateSelected() {
        guard requireSelection() else { return }
        webView?.eval("window.__jiba.duplicateSelected()")
    }
    func insertShape(index: Int) { webView?.eval("window.__jiba.insertShape(\(index))") }
    func insertNode(_ kind: String) { webView?.eval("window.__jiba.insertNode('\(kind)')") }
    func insertTable() { webView?.eval("window.__jiba.insertTable(3,3)") }
    func insertImage(url: String) {
        let esc = url.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView?.eval("window.__jiba.insertImage('\(esc)')")
    }

    /// PowerPoint-style "insert local picture": copy the file into the project
    /// (assets/) and insert a relative <img> so the saved page stays portable.
    func pickLocalImage() {
        guard let project else { showToast("请先打开一个项目", icon: "ℹ"); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择图片文件"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .image]
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let assetsDir = URL(fileURLWithPath: project.dir).appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            var dst = assetsDir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                let stem = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                dst = assetsDir.appendingPathComponent("\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)")
            }
            try FileManager.default.copyItem(at: src, to: dst)
            insertImage(url: "assets/\(dst.lastPathComponent)")
            showToast("已插入 \(dst.lastPathComponent)")
        } catch {
            showToast("复制图片失败: \(error.localizedDescription)", icon: "⚠")
        }
    }

    func undo() { webView?.eval("window.__jiba.undo()") }
    func redo() { webView?.eval("window.__jiba.redo()") }
    func pptNav(_ d: Int) { webView?.eval("window.__jiba.pptNav(\(d))") }
    func pptGo(_ i: Int) { webView?.eval("window.__jiba.pptGo(\(i))") }
    func pptDup() { webView?.eval("window.__jiba.pptDup()") }
    func pptDel() { webView?.eval("window.__jiba.pptDel()") }
    func setZoom(_ z: Double) { zoom = CGFloat(min(2.5, max(0.25, z))) }
    func setDevice(w: Double, h: Double) {
        deviceW = CGFloat(w); deviceH = CGFloat(h)
    }
    func exportHTML() { webView?.eval("window.__jiba.export()") }

    // PowerPoint-style ribbon actions
    func copySelected() { guard requireSelection() else { return }; webView?.eval("window.__jiba.copySelected()") }
    func cutSelected() { guard requireSelection() else { return }; webView?.eval("window.__jiba.cutSelected()") }
    func pasteSelected() { webView?.eval("window.__jiba.pasteSelected()") }
    func bringForward() { guard requireSelection() else { return }; webView?.eval("window.__jiba.bringForward()") }
    func sendBackward() { guard requireSelection() else { return }; webView?.eval("window.__jiba.sendBackward()") }
    func bringToFront() { guard requireSelection() else { return }; webView?.eval("window.__jiba.bringToFront()") }
    func sendToBack() { guard requireSelection() else { return }; webView?.eval("window.__jiba.sendToBack()") }
    func toggleBold() { guard requireSelection() else { return }; webView?.eval("window.__jiba.toggleBold()") }
    func toggleItalic() { guard requireSelection() else { return }; webView?.eval("window.__jiba.toggleItalic()") }
    func toggleUnderline() { guard requireSelection() else { return }; webView?.eval("window.__jiba.toggleUnderline()") }
    func setTextAlign(_ v: String) { applyStyle(["textAlign": v]) }
    func setTextColor(_ hex: String) { applyStyle(["color": hex]) }
    func setBackgroundColor(_ hex: String) { applyStyle(["backgroundColor": hex]) }
    func groupSelected() { guard requireSelection() else { return }; webView?.eval("window.__jiba.groupSelected()") }
    func selectAll() { webView?.eval("window.__jiba.selectAll()") }
}

// MARK: - Models

struct ProjectInfo {
    let dir: String
    let name: String
    let token: String?
}

struct ProjectOpenResponse: Decodable {
    let ok: Bool
    let dir: String
    let name: String
    let token: String?
    let pages: [PageFile]
}

struct PageFile: Decodable, Identifiable, Hashable {
    let name: String
    let rel: String
    let path: String
    let ext: String
    let size: Int?
    let mtime: Double?
    var id: String { path }
}

struct SlideInfo: Equatable, Identifiable {
    let index: Int
    let label: String
    var id: Int { index }
}

struct StyleSnapshot: Equatable {
    var fontSize: String = "16"
    var fontWeight: String = "400"
    var color: String = "#1f2937"
    var background: String = "#ffffff"
    var textAlign: String = "left"
    var width: String = "0"
    var height: String = "0"
    var opacity: String = "1"
    var borderRadius: String = "0"
    var hasSelection: Bool = false
}

// MARK: - API

enum API {
    static func post<T: Decodable>(_ path: String, _ body: [String: String]) async throws -> T {
        let base = await MainActor.run { BackendManager.shared.baseURL }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        comps.path = path
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let token = await MainActor.run(body: { EditorStore.shared.liveToken }) {
            req.setValue(token, forHTTPHeaderField: "X-Project-Token")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = obj["detail"] as? String {
                throw NSError(domain: "API", code: code, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            throw NSError(domain: "API", code: code, userInfo: [NSLocalizedDescriptionKey: "请求失败 \(code)"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Dictionary where Key == String, Value == String {
    /// JSON object literal for eval'ing into the page.
    var jsObjectLiteral: String {
        guard let data = try? JSONSerialization.data(withJSONObject: self, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
