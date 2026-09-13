import SwiftUI
import AppKit

@main
struct HTMLJibaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var backend = BackendManager.shared
    @StateObject private var store = EditorStore.shared

    var body: some Scene {
        WindowGroup("HTML辑霸") {
            RootView()
                .environmentObject(backend)
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 700)
                .background(WindowAccessor { window in
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.isMovableByWindowBackground = true
                    window.toolbarStyle = .unifiedCompact
                    // Light-only brand (kangzhe core): in Dark Mode the regular
                    // materials go near-black and ink text becomes unreadable, and
                    // WKWebView renders unstyled JSON black — force aqua.
                    window.appearance = NSAppearance(named: .aqua)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…") {
                    Task { @MainActor in EditorStore.shared.pickAndOpen(preferFile: true) }
                }
                .keyboardShortcut("o")
                Button("打开文件夹…") {
                    Task { @MainActor in EditorStore.shared.pickAndOpen(preferFile: false) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Button("保存") {
                    Task { @MainActor in EditorStore.shared.saveCurrent() }
                }
                .keyboardShortcut("s")
                Button("演示") {
                    Task { @MainActor in EditorStore.shared.enterPresent() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let instanceNotification = Notification.Name("local.htmleditor.jiba.launched")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices-launched copies of this app accept GET but stall on POST
        // to localhost. Re-exec through bash with a clean env so the process is
        // no longer an LS child (same as running the binary from Terminal).
        if ProcessInfo.processInfo.environment["JIBA_REEXEC"] != "1" {
            let exe = Bundle.main.executableURL?.path ?? "/usr/bin/true"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Pass the path as $1 (never string-interpolated) so quotes/spaces/
            // CJK in the install path can't break the shell command.
            p.arguments = ["-lc", "JIBA_REEXEC=1 exec \"$1\"", "--", exe]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
            return
        }
        BackendManager.shared.start()
        // Single instance: if 9100 is already served by another copy of this app
        // (we had to fall back to a higher port), hand off to it and quit — two
        // live instances would share one cookie jar across different ports.
        if BackendManager.shared.port != 9100 && Self.probeIsJiba(port: 9100) {
            DistributedNotificationCenter.default().post(
                name: Self.instanceNotification, object: nil)
            NSApp.terminate(nil)
            return
        }
        // Announce AFTER our server is up so an already-running instance comes
        // front; the newcomer above quits instead of lingering.
        DistributedNotificationCenter.default().post(
            name: Self.instanceNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            forName: Self.instanceNotification, object: nil, queue: .main
        ) { [weak self] _ in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// True when `port` answers with this app's engine signature.
    private static func probeIsJiba(port: UInt16) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/info") else { return false }
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        var result = Data()
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.7
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data ?? Data(); sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 0.9)
        ok = String(data: result, encoding: .utf8)?.contains("native_picker") == true
        return ok
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.isVisible }
    }
    func applicationWillTerminate(_ notification: Notification) {
        BackendManager.shared.stop()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Guard against losing unsaved canvas edits.
        guard EditorStore.shared.dirty else { return .terminateNow }
        if EditorStore.shared.terminateAfterSave { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "有未保存的修改"
        alert.informativeText = "退出前要保存当前页面吗？"
        alert.addButton(withTitle: "保存并退出")
        alert.addButton(withTitle: "不保存，退出")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            EditorStore.shared.saveAndTerminate()
            return .terminateCancel // terminate resumes when save reports back
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

/// Transparent titlebar helper
struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window { onResolve(w) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { onResolve(w) }
        }
    }
}
