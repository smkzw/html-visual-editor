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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices-launched copies of this app accept GET but stall on POST
        // to localhost. Re-exec through bash with a clean env so the process is
        // no longer an LS child (same as running the binary from Terminal).
        if ProcessInfo.processInfo.environment["JIBA_REEXEC"] != "1" {
            let exe = Bundle.main.executableURL?.path ?? "/usr/bin/true"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-lc", "JIBA_REEXEC=1 exec '\(exe)'"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
            return
        }
        BackendManager.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        BackendManager.shared.stop()
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
