// HTML 可视化编辑器 — 统一文件/文件夹选择器（macOS）
// 必须打包为 .app 并经 `open -W` 启动，LaunchServices 才能正确激活前台，
// 使 NSOpenPanel 成为 key window（侧边栏文件夹可点击导航）。
// 用法: picker <result-file>
//   选中 → 把绝对路径写入 result-file；取消 → 写入空字符串。退出码恒为 0。
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: picker <result-file>\n", stderr); exit(2) }
let resultPath = args[1]

func writeResult(_ s: String) {
    try? s.write(toFile: resultPath, atomically: true, encoding: .utf8)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let panel = NSOpenPanel()
panel.canChooseFiles = true
panel.canChooseDirectories = true
panel.allowsMultipleSelection = false
panel.canCreateDirectories = false
panel.title = "打开网页文件或文件夹"
panel.message = "选择网页文件（.html），或选择整个网页文件夹"
panel.prompt = "打开"

// 激活并运行模态对话框。runModal 自带模态事件循环，对话框可成为 key window。
DispatchQueue.main.async {
    NSApp.activate(ignoringOtherApps: true)
    let response = panel.runModal()
    if response == .OK, let url = panel.url {
        writeResult(url.path)
    } else {
        writeResult("")
    }
    exit(0)
}

RunLoop.main.run()
