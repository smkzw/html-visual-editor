import SwiftUI

/// Main editor chrome: glass toolbar + sidebar + canvas + inspector
struct EditorChromeView: View {
    @EnvironmentObject var store: EditorStore
    @State private var sidebarCollapsed = false
    @State private var inspectorTab = 0 // 0 style 1 anim 2 page

    var body: some View {
        VStack(spacing: 0) {
            GlassToolbar(
                sidebarCollapsed: $sidebarCollapsed,
                inspectorTab: $inspectorTab
            )
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarPanel()
                        .frame(width: 220)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                CanvasArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                InspectorPanel(tab: $inspectorTab)
                    .frame(width: 280)
            }
        }
        .animation(.smooth(duration: 0.22), value: sidebarCollapsed)
    }
}

// MARK: - Toolbar

struct GlassToolbar: View {
    @EnvironmentObject var store: EditorStore
    @Binding var sidebarCollapsed: Bool
    @Binding var inspectorTab: Int
    @State private var showInsert = false
    @State private var showShape = false
    @State private var imageURL = ""

    var body: some View {
        HStack(spacing: 10) {
            ToolbarIcon(systemImage: sidebarCollapsed ? "sidebar.left" : "sidebar.squares.left") {
                sidebarCollapsed.toggle()
            }
            ToolbarIcon(systemImage: "folder") { store.pickAndOpen(preferFile: true) }
            ToolbarIcon(systemImage: "house") { store.goHome() }

            Divider().frame(height: 18)

            if let name = store.currentPage?.name {
                HStack(spacing: 6) {
                    Text(store.project?.name ?? "")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(name)
                        .foregroundStyle(.orange)
                    if store.dirty {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                    }
                    if store.isPPT {
                        Text("PPT \(store.pptIndex+1)/\(store.pptCount)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            if store.isPPT {
                ToolbarIcon(systemImage: "chevron.left") { store.pptNav(-1) }
                ToolbarIcon(systemImage: "chevron.right") { store.pptNav(1) }
                ToolbarIcon(systemImage: "plus.square.on.square") { store.pptDup() }
                Divider().frame(height: 18)
            }

            ToolbarIcon(systemImage: "arrow.uturn.backward") { store.undo() }
            ToolbarIcon(systemImage: "arrow.uturn.forward") { store.redo() }

            Divider().frame(height: 18)

            Menu {
                ForEach(0..<7, id: \.self) { i in
                    Button(["矩形","圆形","椭圆","三角","菱形","星形","箭头"][i]) { store.insertShape(index: i) }
                }
            } label: {
                Label("形状", systemImage: "square.on.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 72)

            Menu {
                Button("文字框") { store.insertNode("textbox") }
                Button("标题") { store.insertNode("title") }
                Button("按钮") { store.insertNode("button") }
                Button("分隔线") { store.insertNode("divider") }
                Button("卡片") { store.insertNode("card") }
                Button("图标") { store.insertNode("icon") }
                Button("表格") { store.insertTable() }
                Divider()
                Button("图片 URL…") { showInsert = true }
            } label: {
                Label("插入", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 72)

            // Align
            ToolbarIcon(systemImage: "align.horizontal.left") { store.align("left") }
            ToolbarIcon(systemImage: "align.horizontal.center") { store.align("center") }
            ToolbarIcon(systemImage: "align.horizontal.right") { store.align("right") }
            ToolbarIcon(systemImage: "align.vertical.top") { store.align("top") }
            ToolbarIcon(systemImage: "align.vertical.center") { store.align("middle") }
            ToolbarIcon(systemImage: "align.vertical.bottom") { store.align("bottom") }

            Divider().frame(height: 18)

            ToolbarIcon(systemImage: "sparkles") { inspectorTab = 1 }
            ToolbarIcon(systemImage: "play.fill") { store.enterPresent() }
            ToolbarIcon(systemImage: "square.and.arrow.down") { store.exportHTML() }

            Button {
                store.saveCurrent()
            } label: {
                Label("保存", systemImage: "square.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(colors: [.orange, .orange.opacity(0.9)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(store.currentPage == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            if #available(macOS 26.0, *) {
                Rectangle().fill(.clear).glassEffect(.regular, in: .rect)
            } else {
                Color.clear.background(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .alert("插入图片", isPresented: $showInsert) {
            TextField("图片 URL", text: $imageURL)
            Button("插入") { if !imageURL.isEmpty { store.insertImage(url: imageURL); imageURL = "" } }
            Button("取消", role: .cancel) {}
        }
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
                .frame(width: 28, height: 28)
                .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Sidebar

struct SidebarPanel: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.isPPT ? "幻灯片 · \(store.pptCount) 页" : "项目文件")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.pages) { page in
                        Button {
                            store.loadPage(page)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: page.ext == ".html" ? "doc.text" : "doc")
                                    .foregroundStyle(.orange)
                                Text(page.name)
                                    .lineLimit(1)
                                    .foregroundStyle(store.currentPage?.path == page.path ? Color.orange : Color.primary)
                                Spacer()
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                store.currentPage?.path == page.path
                                    ? Color.orange.opacity(0.12)
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
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Divider() }
    }
}

// MARK: - Canvas

struct CanvasArea: View {
    @EnvironmentObject var store: EditorStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.03)
            GeometryReader { geo in
                let scale = min(1.4, max(0.3, (geo.size.width - 80) / store.deviceW))
                ZStack {
                    EditorWebView(store: store)
                        .frame(width: store.deviceW, height: store.deviceH)
                        .scaleEffect(store.presenting ? 1 : scale)
                        .clipShape(RoundedRectangle(cornerRadius: store.presenting ? 0 : 12, style: .continuous))
                        .overlay {
                            if !store.presenting {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.black.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            VStack {
                Spacer()
                HStack(spacing: 10) {
                    GlassChip {
                        Button { store.setZoom(max(0.25, Double(store.zoom) - 0.1)) } label: { Image(systemName: "minus") }
                        Text("\(Int(store.zoom * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 40)
                        Button { store.setZoom(min(2.5, Double(store.zoom) + 0.1)) } label: { Image(systemName: "plus") }
                        Divider().frame(height: 12)
                        Button("桌面") { store.setDevice(w: 1280, h: 800) }
                        Button("平板") { store.setDevice(w: 768, h: 1024) }
                        Button("手机") { store.setDevice(w: 390, h: 844) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.bottom, 14)
            }
        }
    }
}

struct GlassChip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
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

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == 0 { StyleInspector() }
                    else if tab == 1 { AnimInspector() }
                    else { PageInfoInspector() }
                }
                .padding(14)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) { Divider() }
    }
}

struct TabBtn: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(active ? Color.orange.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(active ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

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
                HStack {
                    Text(label)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                        .foregroundStyle(.orange)
                    Spacer()
                }
                InspectorField(title: "字号", text: $fontSize)
                    .onChange(of: fontSize) { _, v in store.applyStyle(["fontSize": v + "px"]) }
                InspectorField(title: "颜色", text: $colorHex)
                    .onChange(of: colorHex) { _, v in store.applyStyle(["color": v]) }
                InspectorField(title: "背景", text: $bgHex)
                    .onChange(of: bgHex) { _, v in store.applyStyle(["backgroundColor": v]) }
                HStack(spacing: 8) {
                    InspectorField(title: "宽", text: $width)
                        .onChange(of: width) { _, v in store.applyStyle(["width": v + "px"]) }
                    InspectorField(title: "高", text: $height)
                        .onChange(of: height) { _, v in store.applyStyle(["height": v + "px"]) }
                }
                HStack(spacing: 8) {
                    GlassMiniBtn("粗体") { store.applyStyle(["fontWeight": "700"]) }
                    GlassMiniBtn("常规") { store.applyStyle(["fontWeight": "400"]) }
                    GlassMiniBtn("居中") { store.applyStyle(["textAlign": "center"]) }
                }
                HStack(spacing: 8) {
                    GlassMiniBtn("复制") { store.duplicateSelected() }
                    GlassMiniBtn("删除", danger: true) { store.deleteSelected() }
                }
            }
            .onAppear {
                fontSize = store.styleSnapshot.fontSize
                colorHex = store.styleSnapshot.color
                bgHex = store.styleSnapshot.background
                width = store.styleSnapshot.width
                height = store.styleSnapshot.height
            }
            .onChange(of: store.styleSnapshot) { _, snap in
                fontSize = snap.fontSize
                colorHex = snap.color
                bgHex = snap.background
                width = snap.width
                height = snap.height
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("单击画布元素开始编辑\n双击修改文字")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }
}

struct AnimInspector: View {
    @EnvironmentObject var store: EditorStore
    @State private var dur = "0.6"
    @State private var delay = "0"
    @State private var ease = "ease"
    @State private var iter = "1"

    let entrance = [
        ("v4-fade-in","淡入"),("v4-slide-up","上滑"),("v4-slide-left","左滑"),
        ("v4-zoom-in","放大"),("v4-bounce-in","弹入"),("v4-flip-in","翻转")
    ]
    let emphasis = [
        ("v4-pulse","脉冲"),("v4-shake","抖动"),("v4-float","漂浮"),
        ("v4-glow","发光"),("v4-spin","旋转")
    ]

    var body: some View {
        if !store.styleSnapshot.hasSelection {
            Text("请先选中画布中的元素")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 30)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("入场")
                FlowLayout(spacing: 6) {
                    ForEach(entrance, id: \.0) { item in
                        AnimChip(label: item.1, active: store.animName == item.0) {
                            store.applyAnim(name: item.0, dur: Double(dur) ?? 0.6, delay: Double(delay) ?? 0, ease: ease, iter: Int(iter) ?? 1)
                        }
                    }
                }

                SectionHeader("强调")
                FlowLayout(spacing: 6) {
                    ForEach(emphasis, id: \.0) { item in
                        AnimChip(label: item.1, active: store.animName == item.0) {
                            store.applyAnim(name: item.0, dur: Double(dur) ?? 0.6, delay: Double(delay) ?? 0, ease: ease, iter: Int(iter) ?? 1)
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
                .font(.system(size: 12))
                InspectorField(title: "次数 0=∞", text: $iter)

                HStack(spacing: 8) {
                    GlassMiniBtn("播放") { store.previewAnim() }
                    GlassMiniBtn("清除", danger: true) { store.clearAnim() }
                }
            }
        }
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
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
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
            Text(k).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(v).lineLimit(2)
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
            .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background((danger ? Color.red.opacity(0.12) : Color.primary.opacity(0.06)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(danger ? Color.red : Color.primary)
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
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? Color.orange.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(active ? Color.orange : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Simple flow layout for chips
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
