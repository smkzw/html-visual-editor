import SwiftUI
import AppKit

/// Main editor chrome: glass toolbar + sidebar + canvas + inspector.
/// Presenting hides the chrome and gives the canvas the full window.
struct EditorChromeView: View {
    @EnvironmentObject var store: EditorStore
    @State private var sidebarCollapsed = false
    @State private var inspectorTab = 0

    var body: some View {
        VStack(spacing: 0) {
            if !store.presenting {
                GlassToolbar(sidebarCollapsed: $sidebarCollapsed, inspectorTab: $inspectorTab)
            }
            HStack(spacing: 0) {
                if !sidebarCollapsed && !store.presenting {
                    SidebarPanel()
                        .frame(width: 220)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                CanvasArea(presenting: store.presenting)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !store.presenting {
                    InspectorPanel(tab: $inspectorTab)
                        .frame(width: 280)
                }
            }
        }
        .animation(.smooth(duration: 0.22), value: sidebarCollapsed)
        .animation(.smooth(duration: 0.25), value: store.presenting)
    }
}

// MARK: - PowerPoint-style Ribbon

struct GlassToolbar: View {
    @EnvironmentObject var store: EditorStore
    @Binding var sidebarCollapsed: Bool
    @Binding var inspectorTab: Int
    @State private var imageURL = ""
    @State private var showInsert = false
    @State private var fontSize = "16"
    @State private var textColor = "#0f1115"

    var body: some View {
        VStack(spacing: 0) {
            // Title strip
            HStack(spacing: 10) {
                ToolbarIcon(systemImage: sidebarCollapsed ? "sidebar.left" : "sidebar.squares.left") {
                    sidebarCollapsed.toggle()
                }
                ToolbarIcon(systemImage: "folder") { store.pickAndOpen(preferFile: true) }
                ToolbarIcon(systemImage: "house") { store.goHome() }
                if let name = store.currentPage?.name {
                    HStack(spacing: 6) {
                        Text(store.project?.name ?? "").foregroundStyle(Theme.inkSecondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.inkTertiary)
                        Text(name).foregroundStyle(Theme.accentDeep)
                        if store.dirty { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                        if store.isPPT {
                            Text("幻灯片 \(store.pptIndex+1)/\(store.pptCount)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.18), in: Capsule())
                                .foregroundStyle(Theme.accentDeep)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                Spacer()
                Button { store.saveCurrent() } label: {
                    Label("保存", systemImage: "square.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.plain)
                .disabled(store.currentPage == nil)
                .opacity(store.currentPage == nil ? 0.4 : 1)
                ToolbarIcon(systemImage: "play.fill") { store.enterPresent() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Ribbon groups
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    RibbonGroup(title: "撤销") {
                        RibbonBtn("撤销", "arrow.uturn.backward") { store.undo() }
                        RibbonBtn("重做", "arrow.uturn.forward") { store.redo() }
                    }
                    RibbonSep()
                    RibbonGroup(title: "剪贴板") {
                        RibbonBtn("剪切", "scissors") { store.cutSelected() }
                        RibbonBtn("复制", "doc.on.doc") { store.copySelected() }
                        RibbonBtn("粘贴", "doc.on.clipboard") { store.pasteSelected() }
                        RibbonBtn("副本", "plus.square.on.square") { store.duplicateSelected() }
                    }
                    RibbonSep()
                    RibbonGroup(title: "字体") {
                        HStack(spacing: 4) {
                            RibbonBtn("B", nil, bold: true) { store.toggleBold() }
                            RibbonBtn("I", nil) { store.toggleItalic() }
                            RibbonBtn("U", nil) { store.toggleUnderline() }
                        }
                        HStack(spacing: 4) {
                            TextField("字号", text: $fontSize)
                                .textFieldStyle(.plain)
                                .frame(width: 40)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .onSubmit { store.applyStyle(["fontSize": fontSize + "px"]) }
                            ColorPicker("", selection: Binding(
                                get: { Color(hexString: textColor) },
                                set: { c in textColor = c.toHexString(); store.setTextColor(textColor) }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 28, height: 24)
                        }
                    }
                    RibbonSep()
                    RibbonGroup(title: "段落") {
                        RibbonBtn("左", "align.horizontal.left") { store.setTextAlign("left") }
                        RibbonBtn("中", "align.horizontal.center") { store.setTextAlign("center") }
                        RibbonBtn("右", "align.horizontal.right") { store.setTextAlign("right") }
                    }
                    RibbonSep()
                    RibbonGroup(title: "插入") {
                        Menu {
                            ForEach(0..<7, id: \.self) { i in
                                Button(["矩形","圆形","椭圆","三角","菱形","星形","箭头"][i]) { store.insertShape(index: i) }
                            }
                        } label: { RibbonLabel("形状", "square.on.circle") }
                        Menu {
                            Button("本地图片…") { store.pickLocalImage() }
                            Button("图片 URL…") { showInsert = true }
                            Divider()
                            Button("文字框") { store.insertNode("textbox") }
                            Button("标题") { store.insertNode("title") }
                            Button("按钮") { store.insertNode("button") }
                            Button("分隔线") { store.insertNode("divider") }
                            Button("卡片") { store.insertNode("card") }
                            Button("图标") { store.insertNode("icon") }
                            Button("表格") { store.insertTable() }
                        } label: { RibbonLabel("插入", "plus") }
                    }
                    RibbonSep()
                    RibbonGroup(title: "排列") {
                        RibbonBtn("上移", "arrow.up.to.line") { store.bringForward() }
                        RibbonBtn("下移", "arrow.down.to.line") { store.sendBackward() }
                        RibbonBtn("置顶", "arrow.up.to.line.compact") { store.bringToFront() }
                        RibbonBtn("置底", "arrow.down.to.line.compact") { store.sendToBack() }
                        RibbonBtn("组合", "square.stack.3d.down.right") { store.groupSelected() }
                        RibbonBtn("删除", "trash", danger: true) { store.deleteSelected() }
                    }
                    RibbonSep()
                    if store.isPPT {
                        RibbonGroup(title: "幻灯片") {
                            RibbonBtn("上页", "chevron.left") { store.pptNav(-1) }
                            RibbonBtn("下页", "chevron.right") { store.pptNav(1) }
                            RibbonBtn("复制页", "plus.square.on.square") { store.pptDup() }
                            RibbonBtn("删除页", "trash", danger: true) { store.pptDel() }
                        }
                        RibbonSep()
                    }
                    RibbonGroup(title: "视图") {
                        RibbonBtn("动效", "sparkles") { inspectorTab = 1 }
                        RibbonBtn("演示", "play.fill") { store.enterPresent() }
                        RibbonBtn("导出", "square.and.arrow.down") { store.exportHTML() }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background {
            ZStack {
                Theme.glassPanel.opacity(0.92)
                if #available(macOS 26.0, *) {
                    Rectangle().fill(.clear).glassEffect(.regular, in: .rect)
                } else {
                    Rectangle().fill(.regularMaterial.opacity(0.5))
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 0.5) }
        .alert("插入图片 URL", isPresented: $showInsert) {
            TextField("图片 URL", text: $imageURL)
            Button("插入") { if !imageURL.isEmpty { store.insertImage(url: imageURL); imageURL = "" } }
            Button("取消", role: .cancel) {}
        }
    }
}

struct RibbonSep: View {
    var body: some View {
        Rectangle().fill(Theme.ink.opacity(0.10)).frame(width: 1, height: 44).padding(.vertical, 4)
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) { content }
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct RibbonLabel: View {
    let title: String
    let icon: String?
    init(_ title: String, _ icon: String? = nil) { self.title = title; self.icon = icon }
    var body: some View {
        VStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 14)) }
            else { Text(title).font(.system(size: 13, weight: .bold)) }
            if icon != nil {
                Text(title).font(.system(size: 9, weight: .medium))
            }
        }
        .foregroundStyle(Theme.ink)
        .frame(minWidth: 40, minHeight: 40)
        .padding(.horizontal, 4)
        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct RibbonBtn: View {
    let title: String
    let icon: String?
    var bold = false
    var danger = false
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, _ icon: String? = nil, bold: Bool = false, danger: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.bold = bold; self.danger = danger; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)) }
                else { Text(title).font(.system(size: bold ? 15 : 13, weight: bold ? .black : .bold)) }
                if icon != nil {
                    Text(title).font(.system(size: 9, weight: .medium))
                }
            }
            .foregroundStyle(danger ? Color.red : Theme.ink)
            .frame(minWidth: 36, minHeight: 40)
            .padding(.horizontal, 4)
            .background(hover ? Theme.ink.opacity(0.10) : Theme.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ToolbarIcon: View {
    let systemImage: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 28, height: 28)
                .background(hover ? Theme.ink.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension Color {
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(red: Double((v >> 16) & 0xFF)/255, green: Double((v >> 8) & 0xFF)/255, blue: Double(v & 0xFF)/255)
        } else {
            self.init(white: 0.12)
        }
    }
    func toHexString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

// MARK: - Sidebar

struct SidebarPanel: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.isPPT && !store.slides.isEmpty {
                        Text("幻灯片 · \(store.slides.count) 页")
                            .font(.system(size: 11, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        ForEach(store.slides) { slide in
                            Button {
                                store.pptGo(slide.index)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("\(slide.index + 1)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(
                            store.pptIndex == slide.index ? Theme.solidAccent : Theme.ink.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        )
                                    Text(slide.label)
                                        .lineLimit(1)
                                        .foregroundStyle(store.pptIndex == slide.index ? Theme.accentDeep : Theme.ink)
                                    Spacer()
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    store.pptIndex == slide.index
                                        ? Theme.accent.opacity(0.16)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(store.isPPT ? "项目文件" : "项目文件 · \(store.pages.count)")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    ForEach(store.pages) { page in
                        Button {
                            store.loadPage(page)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: page.ext == ".html" ? "doc.text" : "doc")
                                    .foregroundStyle(Theme.accentDeep)
                                Text(page.rel)
                                    .lineLimit(1)
                                    .foregroundStyle(store.currentPage?.path == page.path ? Theme.accentDeep : Theme.ink)
                                Spacer()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                store.currentPage?.path == page.path
                                    ? Theme.accent.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .background(Theme.glassPanel.opacity(0.78))
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 0.5)
        }
    }
}

// MARK: - Canvas

struct CanvasArea: View {
    @EnvironmentObject var store: EditorStore
    var presenting = false

    var body: some View {
        GeometryReader { geo in
            let fit = min(1.25, max(0.15, min(
                (geo.size.width - 48) / max(store.deviceW, 1),
                (geo.size.height - 56) / max(store.deviceH, 1))))
            // Present: cover the whole stage. Edit: fit × user zoom (scrollable when larger).
            // NOTE: the view structure below must NOT depend on `presenting` —
            // branching would rebuild the WKWebView and reload (losing edits).
            let scale = presenting
                ? min(2.0, max(geo.size.width / max(store.deviceW, 1), geo.size.height / max(store.deviceH, 1)))
                : fit * store.zoom
            let visW = store.deviceW * scale
            let visH = store.deviceH * scale

            ScrollView([.horizontal, .vertical]) {
                canvas(scale: scale, visW: presenting ? max(visW, geo.size.width) : visW,
                       visH: presenting ? max(visH, geo.size.height) : visH)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(presenting ? 0 : 24)
            }
            .defaultScrollAnchor(.center)
            .scrollDisabled(presenting)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background {
            if presenting { Color.black } else { CanvasDesk() }
        }
        .overlay {
            if presenting { PresentControls() }
        }
        .overlay(alignment: .bottom) {
            if !presenting && store.currentPage != nil { ZoomHud() }
        }
        .overlay {
            if !presenting && store.currentPage == nil {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 42))
                        .foregroundStyle(Theme.inkTertiary)
                    Text("打开 HTML 文件开始编辑")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                    Text("支持单页 · 多页站点 · HTML-PPT")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    private func canvas(scale: CGFloat, visW: CGFloat, visH: CGFloat) -> some View {
        EditorWebView(store: store)
            .frame(width: store.deviceW, height: store.deviceH)
            .scaleEffect(scale, anchor: .center)
            .frame(width: visW, height: visH)
            .clipped()
            .background(presenting ? Color.black : Color.white)
            .clipShape(presenting ? AnyShape(Rectangle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            .overlay {
                if !presenting {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.ink.opacity(0.14), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(presenting ? 0 : 0.18), radius: 24, y: 10)
            .allowsHitTesting(true)
    }
}

struct CanvasDesk: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.94, green: 0.95, blue: 0.97),
                         Color(red: 0.90, green: 0.91, blue: 0.94)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(colors: [Theme.accent.opacity(0.08), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 400)
        }
    }
}

// MARK: - Zoom HUD

struct ZoomHud: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        HStack(spacing: 10) {
            GlassChip {
                Button { store.setZoom(Double(store.zoom) - 0.1) } label: {
                    Image(systemName: "minus").foregroundStyle(Theme.ink)
                }
                Text("\(Int(store.zoom * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40)
                Button { store.setZoom(Double(store.zoom) + 0.1) } label: {
                    Image(systemName: "plus").foregroundStyle(Theme.ink)
                }
                Button("适应") { store.setZoom(1.0) }.foregroundStyle(Theme.ink)
                Divider().frame(height: 12)
                Button("桌面") { store.setDevice(w: 1280, h: 800) }.foregroundStyle(Theme.ink)
                Button("平板") { store.setDevice(w: 768, h: 1024) }.foregroundStyle(Theme.ink)
                Button("手机") { store.setDevice(w: 390, h: 844) }.foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .padding(.bottom, 14)
    }
}

struct GlassChip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.glassChip, in: Capsule())
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.panelStroke, lineWidth: 0.6))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

// MARK: - Present controls (over the canvas, not covering it)

struct PresentControls: View {
    @EnvironmentObject var store: EditorStore
    @State private var monitor = PresentKeyMonitor()

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    Button { store.pptNav(-1) } label: { Image(systemName: "chevron.left") }
                    Text(store.isPPT ? "\(store.pptIndex+1) / \(store.pptCount)" : "演示中")
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minWidth: 56)
                    Button { store.pptNav(1) } label: { Image(systemName: "chevron.right") }
                    Divider().frame(height: 14)
                    Button("退出 (Esc)") { store.exitPresent() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .padding(.bottom, 22)
            }
        }
        .onAppear {
            monitor.start(
                next: { Task { @MainActor in store.pptNav(1) } },
                prev: { Task { @MainActor in store.pptNav(-1) } },
                exit: { Task { @MainActor in store.exitPresent() } }
            )
        }
        .onDisappear { monitor.stop() }
    }
}

/// Arrow/space/Esc handling while presenting (WKWebView eats raw keys).
final class PresentKeyMonitor {
    private var id: Any?
    func start(next: @escaping () -> Void, prev: @escaping () -> Void, exit: @escaping () -> Void) {
        stop()
        id = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 123, 33: prev(); return nil   // ← / PageUp
            case 124, 34, 49: next(); return nil // → / PageDown / Space
            case 53: exit(); return nil         // Esc
            default: return e
            }
        }
    }
    func stop() {
        if let id { NSEvent.removeMonitor(id) }
        id = nil
    }
}

// MARK: - Inspector

struct InspectorPanel: View {
    @EnvironmentObject var store: EditorStore
    @Binding var tab: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TabBtn(title: "样式", active: tab == 0) { tab = 0 }
                TabBtn(title: "动效", active: tab == 1) { tab = 1 }
                TabBtn(title: "页面", active: tab == 2) { tab = 2 }
            }
            .padding(8)

            Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == 0 { StyleInspector() }
                    else if tab == 1 { AnimInspector() }
                    else { PageInfoInspector() }
                }
                .padding(14)
            }
        }
        .background(Theme.glassPanel.opacity(0.82))
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 0.5)
        }
    }
}

struct TabBtn: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(active ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(active ? Theme.accentDeep : Theme.inkSecondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Style inspector — debounced commits (one undo step per settle, not per keystroke)

struct StyleInspector: View {
    @EnvironmentObject var store: EditorStore
    @State private var fontSize = "16"
    @State private var colorHex = "#1f2937"
    @State private var bgHex = "#ffffff"
    @State private var width = "0"
    @State private var height = "0"

    var body: some View {
        if let label = store.selectedLabel, store.styleSnapshot.hasSelection {
            VStack(alignment: .leading, spacing: 10) {
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.accentDeep)

                DebouncedStyleField(title: "字号", key: "fontSize", suffix: "px", text: $fontSize, sync: store.styleSnapshot.fontSize)
                DebouncedStyleField(title: "颜色", key: "color", suffix: "", text: $colorHex, sync: store.styleSnapshot.color)
                DebouncedStyleField(title: "背景", key: "backgroundColor", suffix: "", text: $bgHex, sync: store.styleSnapshot.background)
                HStack(spacing: 8) {
                    DebouncedStyleField(title: "宽", key: "width", suffix: "px", text: $width, sync: store.styleSnapshot.width)
                    DebouncedStyleField(title: "高", key: "height", suffix: "px", text: $height, sync: store.styleSnapshot.height)
                }
                HStack(spacing: 8) {
                    GlassMiniBtn("加粗") { store.applyStyle(["fontWeight": "700"]) }
                    GlassMiniBtn("常规") { store.applyStyle(["fontWeight": "400"]) }
                    GlassMiniBtn("居中") { store.applyStyle(["textAlign": "center"]) }
                }
                SectionHeader("相对父级对齐")
                HStack(spacing: 8) {
                    GlassMiniBtn("左") { store.align("left") }
                    GlassMiniBtn("水平居中") { store.align("center") }
                    GlassMiniBtn("右") { store.align("right") }
                }
                HStack(spacing: 8) {
                    GlassMiniBtn("顶") { store.align("top") }
                    GlassMiniBtn("垂直居中") { store.align("middle") }
                    GlassMiniBtn("底") { store.align("bottom") }
                }
                HStack(spacing: 8) {
                    GlassMiniBtn("复制") { store.duplicateSelected() }
                    GlassMiniBtn("删除", danger: true) { store.deleteSelected() }
                }
            }
            .onAppear { syncFields() }
            .onChange(of: store.styleSnapshot) { _, _ in syncFields() }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.inkTertiary)
                Text("单击画布元素开始编辑\n双击修改文字")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    private func syncFields() {
        fontSize = store.styleSnapshot.fontSize
        colorHex = store.styleSnapshot.color == "transparent" ? bgHex : store.styleSnapshot.color
        bgHex = store.styleSnapshot.background == "transparent" ? "transparent" : store.styleSnapshot.background
        width = store.styleSnapshot.width
        height = store.styleSnapshot.height
    }
}

/// Text field that commits a style after typing settles (or on Enter).
/// Skips commits triggered by programmatic sync from the selection snapshot.
struct DebouncedStyleField: View {
    @EnvironmentObject var store: EditorStore
    let title: String
    let key: String
    let suffix: String
    @Binding var text: String
    let sync: String
    @State private var task: Task<Void, Never>?

    var body: some View {
        InspectorField(title: title, text: $text)
            .onChange(of: text) { _, v in
                guard v != sync else { return } // echo from snapshot, not user typing
                task?.cancel()
                task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    guard !Task.isCancelled else { return }
                    store.applyStyle([key: v + suffix])
                }
            }
            .onSubmit {
                task?.cancel()
                if text != sync { store.applyStyle([key: text + suffix]) }
            }
    }
}

struct AnimInspector: View {
    @EnvironmentObject var store: EditorStore
    @State private var dur = "0.6"
    @State private var delay = "0"
    @State private var ease = "ease"
    @State private var iter = "1"
    @State private var trigger = "load"

    let entrance = [
        ("v4-fade-in","淡入"),("v4-slide-up","上滑"),("v4-slide-down","下滑"),("v4-slide-left","左滑"),
        ("v4-slide-right","右滑"),("v4-zoom-in","放大"),("v4-bounce-in","弹入"),("v4-rotate-in","旋转"),
        ("v4-flip-in","翻转"),("v4-fade-out","淡出")
    ]
    let emphasis = [
        ("v4-pulse","脉冲"),("v4-shake","抖动"),("v4-float","漂浮"),
        ("v4-glow","发光"),("v4-spin","旋转强调")
    ]

    var body: some View {
        if !store.styleSnapshot.hasSelection {
            Text("请先选中画布中的元素")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 30)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("入场 / 出场")
                FlowLayout(spacing: 6) {
                    ForEach(entrance, id: \.0) { item in
                        AnimChip(label: item.1, active: store.animName == item.0) {
                            apply(item.0)
                        }
                    }
                }
                SectionHeader("强调")
                FlowLayout(spacing: 6) {
                    ForEach(emphasis, id: \.0) { item in
                        AnimChip(label: item.1, active: store.animName == item.0) {
                            apply(item.0)
                        }
                    }
                }
                SectionHeader("参数")
                InspectorField(title: "时长 s", text: $dur)
                InspectorField(title: "延迟 s", text: $delay)
                Picker("缓动", selection: $ease) {
                    Text("缓入缓出").tag("ease")
                    Text("线性").tag("linear")
                    Text("缓入").tag("ease-in")
                    Text("缓出").tag("ease-out")
                    Text("弹簧").tag("cubic-bezier(.2,.9,.25,1.15)")
                }
                .foregroundStyle(Theme.ink)
                InspectorField(title: "次数 0=∞", text: $iter)
                Picker("触发方式", selection: $trigger) {
                    Text("载入即播").tag("load")
                    Text("点击时").tag("click")
                    Text("悬停时").tag("hover")
                    Text("滚入视口").tag("scroll")
                }
                .foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    GlassMiniBtn("播放") { store.previewAnim() }
                    GlassMiniBtn("清除", danger: true) { store.clearAnim() }
                }
                Text("点击/悬停/滚入触发会随保存写入页面，浏览器打开依然生效。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .onAppear { trigger = store.animTrigger }
            .onChange(of: store.animTrigger) { _, v in trigger = v }
        }
    }

    private func apply(_ name: String) {
        store.applyAnim(name: name, dur: Double(dur) ?? 0.6, delay: Double(delay) ?? 0,
                        ease: ease, iter: Int(iter) ?? 1, trigger: trigger)
    }
}

struct PageInfoInspector: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InfoRow("项目", store.project?.name ?? "—")
            InfoRow("页面", "\(store.pages.count) 个 HTML")
            InfoRow("当前", store.currentPage?.rel ?? "—")
            InfoRow("类型", store.isPPT ? "HTML-PPT · \(store.pptCount) 页" : "静态页面")
            if store.dirty {
                Text("有未保存的修改")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentDeep)
            }
        }
    }
}

struct InfoRow: View {
    let k: String
    let v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack {
            Text(k).foregroundStyle(Theme.inkTertiary).frame(width: 40, alignment: .leading)
            Text(v).lineLimit(2).foregroundStyle(Theme.ink)
            Spacer()
        }
        .font(.system(size: 12))
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(Theme.inkTertiary)
            .padding(.top, 4)
    }
}

struct InspectorField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 64, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct GlassMiniBtn: View {
    let title: String
    var danger = false
    let action: () -> Void

    init(_ title: String, danger: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.danger = danger
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    (danger ? Color.red.opacity(0.12) : Theme.ink.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .foregroundStyle(danger ? Color.red : Theme.ink)
        }
        .buttonStyle(.plain)
    }
}

struct AnimChip: View {
    let label: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? Theme.accent.opacity(0.22) : Theme.ink.opacity(0.06), in: Capsule())
                .foregroundStyle(active ? Theme.accentDeep : Theme.ink)
        }
        .buttonStyle(.plain)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 240
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
