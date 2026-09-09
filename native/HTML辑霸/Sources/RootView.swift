import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: EditorStore
    @EnvironmentObject var backend: BackendManager

    var body: some View {
        ZStack {
            AmbientBackground()

            switch store.phase {
            case .landing:
                LandingView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .editor:
                EditorChromeView()
                    .transition(.opacity)
            }

            if let toast = store.toast {
                VStack {
                    Spacer()
                    ToastView(text: toast)
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            if store.presenting {
                PresentOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.28), value: store.phase)
        .animation(.smooth(duration: 0.2), value: store.toast)
        .animation(.smooth(duration: 0.25), value: store.presenting)
        .frame(minWidth: 1100, minHeight: 700)
    }
}

// MARK: - Ambient background (matches web liquid-glass canvas)

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.97, blue: 0.98),
                    Color(red: 0.94, green: 0.95, blue: 0.97),
                    Color(red: 0.96, green: 0.94, blue: 0.91)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Theme.accent.opacity(0.16), .clear],
                center: .topLeading, startRadius: 0, endRadius: 560
            )
            RadialGradient(
                colors: [Color(red: 0, green: 0.12, blue: 0.35).opacity(0.08), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Toast — solid dark glass + light text (never light-on-light)

struct ToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background {
            if #available(macOS 26.0, *) {
                Capsule().fill(Color.black.opacity(0.78))
                    .overlay {
                        Capsule().fill(.clear)
                            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
                    }
            } else {
                Capsule().fill(Color.black.opacity(0.82))
            }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

// MARK: - Landing

struct LandingView: View {
    @EnvironmentObject var store: EditorStore
    @EnvironmentObject var backend: BackendManager

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                BrandHeader()

                Text("像做 PPT 一样\n编辑任何 HTML")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)

                Text("实景渲染 · 覆盖层编辑 · 动效 · 对齐 · 演示模式\n兼容站点式 / 流式 / HTML-PPT")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(1.6)

                VStack(spacing: 12) {
                    GlassButton(title: "打开网页文件或文件夹", systemImage: "folder", prominent: true) {
                        store.pickAndOpen(preferFile: true)
                    }
                    HStack(spacing: 10) {
                        GlassButton(title: "示例页面", systemImage: "doc.text") {
                            store.openSampleDemo()
                        }
                        GlassButton(title: "打开文件夹", systemImage: "square.grid.2x2") {
                            store.pickAndOpen(preferFile: false)
                        }
                    }
                }
                .padding(.top, 8)

                StatusPill(
                    ok: backend.isRunning,
                    text: backend.isRunning ? "引擎运行中 · 127.0.0.1:\(backend.port)" : (backend.lastError ?? "引擎启动中…")
                )
                .padding(.top, 12)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 480, alignment: .leading)

            PreviewStage(port: backend.port)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            if let img = NSApp.applicationIconImage {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            Text("HTML辑霸")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.ink)
            Text("v4.2")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.accent.opacity(0.18), in: Capsule())
                .foregroundStyle(Theme.accentDeep)
        }
    }
}

struct PreviewStage: View {
    let port: Int
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.glassPanel)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Theme.panelStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 40, y: 16)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(.red.opacity(0.8)).frame(width: 10, height: 10)
                    Circle().fill(.yellow.opacity(0.85)).frame(width: 10, height: 10)
                    Circle().fill(.green.opacity(0.8)).frame(width: 10, height: 10)
                    Spacer()
                    Text("127.0.0.1:\(port)/api/live/index.html")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.inkTertiary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("HTML辑霸 · 实景画布")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.5)
                        .foregroundStyle(Theme.accentDeep)
                    Text("新一代 临床数据平台")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.12)).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.09)).frame(width: 220, height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.06)).frame(width: 160, height: 8)
                    Text("了解详情")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.solidAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.top, 6)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .padding(20)
    }
}

struct GlassButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title).fontWeight(.semibold)
            }
            .font(.system(size: 14))
            // CRITICAL: white only on SOLID accent; dark ink on glass
            .foregroundStyle(prominent ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background {
                if prominent {
                    // Solid fill — never white text on translucent orange glass
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accentDeep],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.glassChip)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.panelStroke, lineWidth: 0.8)
                        )
                }
            }
            .shadow(color: prominent ? Theme.accent.opacity(hover ? 0.45 : 0.28) : .black.opacity(0.08),
                    radius: hover ? 16 : 10, y: hover ? 6 : 3)
            .scaleEffect(hover ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.18), value: hover)
    }
}

struct StatusPill: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ok ? Color.green : Theme.accent)
                .frame(width: 7, height: 7)
                .shadow(color: (ok ? Color.green : Theme.accent).opacity(0.6), radius: 4)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.glassChip, in: Capsule())
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.panelStroke, lineWidth: 0.6))
    }
}

// MARK: - Present overlay

struct PresentOverlay: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    Button { store.pptNav(-1) } label: { Image(systemName: "chevron.left") }
                    Text(store.isPPT ? "\(store.pptIndex+1) / \(store.pptCount)" : "演示中")
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minWidth: 56)
                    Button { store.pptNav(1) } label: { Image(systemName: "chevron.right") }
                    Divider().frame(height: 14)
                    Button("退出") { store.exitPresent() }
                        .keyboardShortcut(.escape)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .padding(.bottom, 22)
            }
        }
    }
}
