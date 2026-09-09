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
    @Published var toast: String?
    @Published var styleSnapshot: StyleSnapshot = .init()
    @Published var animName: String = ""
    @Published var liveToken: String?

    enum Phase { case landing, editor }

    weak var webView: (any EditorWebControlling)?

    private var toastTask: Task<Void, Never>?

    // MARK: - Open

    func pickAndOpen(preferFile: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = preferFile ? "选择 HTML 网页文件" : "选择项目文件夹"
        panel.prompt = "打开"
        panel.allowedContentTypes = preferFile ? [.html, .html] : []
        if !preferFile {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        }
        if panel.runModal() == .OK, let url = panel.url {
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

    func openSampleDemo() {
        let samples = Bundle.main.resourceURL?
            .appendingPathComponent("app/samples/demo-page.html").path
            ?? (FileManager.default.currentDirectoryPath + "/src/app/samples/demo-page.html")
        if FileManager.default.fileExists(atPath: samples) {
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
        if let entry { loadPage(entry) }
        showToast("已打开「\(p.name)」· \(pages.count) 个页面")
    }

    func goHome() {
        phase = .landing
        project = nil
        pages = []
        currentPage = nil
        selectedTag = nil
        dirty = false
        isPPT = false
        webView?.loadBlank()
    }

    // MARK: - Page

    func loadPage(_ page: PageFile) {
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

    func enterPresent() {
        presenting = true
        webView?.requestPresent()
    }

    func exitPresent() {
        presenting = false
        webView?.exitPresent()
    }

    // MARK: - Bridge callbacks

    func onSelectionChanged(tag: String?, label: String?, style: StyleSnapshot, anim: String) {
        selectedTag = tag
        selectedLabel = label
        styleSnapshot = style
        animName = anim
    }

    func onDirty() { dirty = true }

    func onPPT(active: Bool, index: Int, count: Int) {
        isPPT = active
        pptIndex = index
        pptCount = count
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

    func applyStyle(_ dict: [String: String]) { webView?.eval("window.__jiba.applyStyle(\(dict.jsonLiteral))") }
    func applyAnim(name: String, dur: Double, delay: Double, ease: String, iter: Int) {
        webView?.eval("window.__jiba.applyAnim('\(name)',\(dur),\(delay),'\(ease)',\(iter))")
    }
    func clearAnim() { webView?.eval("window.__jiba.clearAnim()") }
    func previewAnim() { webView?.eval("window.__jiba.previewAnim()") }
    func align(_ mode: String) { webView?.eval("window.__jiba.align('\(mode)')") }
    func deleteSelected() { webView?.eval("window.__jiba.deleteSelected()") }
    func duplicateSelected() { webView?.eval("window.__jiba.duplicateSelected()") }
    func insertShape(index: Int) { webView?.eval("window.__jiba.insertShape(\(index))") }
    func insertNode(_ kind: String) { webView?.eval("window.__jiba.insertNode('\(kind)')") }
    func insertTable() { webView?.eval("window.__jiba.insertTable(3,3)") }
    func insertImage(url: String) { webView?.eval("window.__jiba.insertImage('\(url)')") }
    func undo() { webView?.eval("window.__jiba.undo()") }
    func redo() { webView?.eval("window.__jiba.redo()") }
    func pptNav(_ d: Int) { webView?.eval("window.__jiba.pptNav(\(d))") }
    func pptDup() { webView?.eval("window.__jiba.pptDup()") }
    func pptDel() { webView?.eval("window.__jiba.pptDel()") }
    func setZoom(_ z: Double) { zoom = CGFloat(z); webView?.eval("window.__jiba.setZoom(\(z))") }
    func setDevice(w: Double, h: Double) {
        deviceW = CGFloat(w); deviceH = CGFloat(h)
        webView?.eval("window.__jiba.setDevice(\(w),\(h))")
    }
    func exportHTML() { webView?.eval("window.__jiba.export()") }

    // PowerPoint-style ribbon actions
    func copySelected() { webView?.eval("window.__jiba.copySelected()") }
    func cutSelected() { webView?.eval("window.__jiba.cutSelected()") }
    func pasteSelected() { webView?.eval("window.__jiba.pasteSelected()") }
    func bringForward() { webView?.eval("window.__jiba.bringForward()") }
    func sendBackward() { webView?.eval("window.__jiba.sendBackward()") }
    func bringToFront() { webView?.eval("window.__jiba.bringToFront()") }
    func sendToBack() { webView?.eval("window.__jiba.sendToBack()") }
    func setFontWeight(_ w: String) { applyStyle(["fontWeight": w]) }
    func toggleItalic() { webView?.eval("window.__jiba.toggleItalic()") }
    func toggleUnderline() { webView?.eval("window.__jiba.toggleUnderline()") }
    func setTextColor(_ hex: String) { applyStyle(["color": hex]) }
    func setBackgroundColor(_ hex: String) { applyStyle(["backgroundColor": hex]) }
    func groupSelected() { webView?.eval("window.__jiba.groupSelected()") }
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
    var jsonLiteral: String {
        let pairs = map { "\($0.key.jsonEscaped):\($0.value.jsonEscaped)" }.joined(separator: ",")
        return "[{\(pairs)}]" // wrong - need object
            .replacingOccurrences(of: "[{", with: "{")
            .replacingOccurrences(of: "}]", with: "}")
    }
}

extension String {
    var jsonEscaped: String {
        let data = try? JSONSerialization.data(withJSONObject: [self])
        if let s = String(data: data ?? Data(), encoding: .utf8) {
            return String(s.dropFirst().dropLast())
        }
        return "\"\(self)\""
    }
}
