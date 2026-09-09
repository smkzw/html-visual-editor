# HTML辑霸

> 像做 PPT 一样编辑任何 HTML。原生 macOS 界面（SwiftUI + Liquid Glass），实景渲染 + 覆盖层编辑。

## 启动方式

**推荐：双击 `~/Applications/启动HTML辑霸.command`**

> 说明：直接双击 `.app` 在部分 macOS 上会因 LaunchServices 网络归因导致保存接口无响应；`.command` 经 Terminal 启动，功能完整。

也可在终端运行：

```bash
JIBA_REEXEC=1 ~/Applications/HTML辑霸.app/Contents/MacOS/HTML辑霸
```

## 功能

- 打开单文件网页 / 多文件站点 / HTML-PPT
- 双击改字、拖拽移动、八向缩放
- 插入形状、图片、表格、文字框、按钮、卡片
- 动效面板（入场/出场/强调，时长延迟缓动可调）
- 相对父级对齐工具
- F5 / 工具栏演示模式（PPT 翻页）
- 保存 / 导出（mtime 冲突检测 + 自动备份）

## 架构

```
HTML辑霸.app
├── SwiftUI + Liquid Glass 外壳（原生工具栏/侧栏/检查器）
├── WKWebView 画布（实景渲染 HTML）
└── LocalHTTPServer（进程内 Swift HTTP，文件读写/预览）
```

## 从源码构建

```bash
./scripts/build-macos.sh
# 产物: dist/HTML辑霸.app
cp -R dist/HTML辑霸.app ~/Applications/
cp scripts/启动HTML辑霸.command ~/Applications/
```

## 目录

```
native/HTML辑霸/Sources/   Swift 源码
src/app/                   Python 参考实现 / 示例 / 静态资源
scripts/                   构建与启动脚本
assets/AppIcon.png         应用图标
```

## License

MIT
