# 项目 Review 记录 · HTML 可视化编辑器 v4.3

日期：2026-09-13
范围：原生 App（`native/HTML辑霸/Sources`）+ 本地服务（LocalHTTPServer）

## 0. v4.3 重构（本轮）— 实测驱动的修复与功能

**实机测试方式**：构建 → 安装 `~/Applications` → computer-use 驱动真实 UI（AX 树断言 + 视觉审查）→ 修订 → 再测试，共 8 轮。

### 数据毁坏级修复（v4.2 遗留）

| 缺陷 | 根因 | 修复 |
|------|------|------|
| **保存会删除鼠标悬停的元素** | `strip()` 把带 `.j-hover`（悬停标记类）的用户元素直接 `remove()`——鼠标最后停在哪，保存时哪个元素从文件里消失 | 只删除编辑器注入的节点（`#jiba-styles`/`.j-handle`）；标记类改为 `classList.remove`（`EditorWebView.swift` strip） |
| **保存固化 `<base href="/api/live/">`** | live 渲染注入的 base 标签随序列化写回源文件，独立打开时相对资源全断 | strip 时移除 `base[href^="/api/live/"]` |
| **编辑器注入的 `position:relative`/`data-j-was-static` 写进文件** | 选中手柄升级 static 元素 position 后从不还原 | `removeHandles` 还原 + strip 兜底 |
| **画布空白（首页打开后不渲染）** | `loadPage` 在 SwiftUI 挂载 WebView 前一帧执行，`webView?.load` 静默空操作 | `makeNSView` 挂载后重放 `store.currentPage`；另发现 `setCookie` completion 可能被丢弃，改为不等待回调直接加载 |
| **演示模式黑屏** | `PresentOverlay` 用不透明黑罩盖住画布 | 演示=隐藏 chrome、画布铺满窗口（cover 缩放）、底部半透明控制条；进入/退出不再重建 WebView（视图结构不随 presenting 分支），未保存编辑与页码位置全程保留 |

### 功能更新

| 功能 | 说明 |
|------|------|
| **PPT 复制页 / 删除页** | v4.2 是空壳按钮；现完整实现（克隆当前 slide、重扫 deck、自动跳转；删除保留至少一页），支持撤销 |
| **幻灯片侧栏** | 检测到 HTML-PPT 时侧栏列出每页（编号+标题），点击跳页 |
| **动效触发器（PowerPoint 对标）** | 载入即播 / 点击时 / 悬停时 / 滚入视口；后三者通过 `data-jiba-anim` + 随保存注入的 `jiba-anim-runtime` 脚本持久化，浏览器直接打开依然生效 |
| **插入定位到当前页** | 检测到 deck 时，形状/文字框/表格/图片插入当前幻灯片并绝对定位，而不是落到 body（原来在 PPT 里不可见） |
| **段落对齐修复** | 工具栏「段落 左/中/右」原调用 `align()`（把元素绝对定位到父级边缘，破坏布局）；现改为 `text-align`。相对父级对齐保留在检查器 |
| **本地图片插入** | NSOpenPanel 选图 → 复制进项目 `assets/` → 插入相对路径 `<img>`，项目可移植 |
| **未保存守卫** | 关窗/回首页/打开新项目/切页时三选一确认（保存/放弃/取消）；保存并退出走保存回调确认后退出 |
| **检查器防抖** | 样式字段 550ms 防抖提交 + 回车立即提交，替代逐键 applyStyle（原来每敲一个字推一次撤销栈）；程序化同步回显不再触发提交 |
| **缩放统一** | 缩放倍率由 Swift 侧 scale 承担（fit × zoom，可滚动平移），不再用页面内 CSS zoom 重排；新增「适应」复位 |
| **B/I/U 完整切换** | B 由"只能加粗"改为双向切换 |
| **服务器加固** | `/api/live` 补 token 校验（与 Python 版对齐，本地任意进程不能再读项目文件）；预览字典过期清理；目录枚举跳过 node_modules 等 |
| **品牌对齐 kangzhe-design-3d** | 强调色 #FF9900、副 #FFCC00、深 #DB6B05、墨字 #0F1115；全浅色底、橙色面积 ≤12% |

### 实测验证（全部通过）

- API：project open/read/save-raw（mtime 冲突 409、.bak 备份）、live token 403/200、CSRF 403、base 注入
- UI（AX 断言）：示例 PPT 打开 → 3 页检测 + 侧栏列表 + 徽章 1/3；下页 2/3；复制页 4 页（侧栏含副本）；删除页回 3 页
- 保存落盘：动画内联样式 + `data-v4-anim/trigger` 持久化；三标题完整；零 base/手柄/标记类污染
- 触发式动画：点击触发 `data-jiba-anim` + runtime 脚本写入文件
- 演示：chrome 隐藏、幻灯片可见（非黑屏）、控制条翻页、Esc 退出、位置保留、无页面重载
- 流式页：demo-page 选中→段落居中→保存 → `text-align:center` 落盘
- 视觉审查（kangzhe 合规）：全浅色、橙色 <10%、深字浅底可读、玻璃质感、无对比度问题
- Finder 启动（re-exec 链路）+ 终端启动均正常

### 遗留（下轮建议）

1. 文字编辑经 AX 无法直接输入（contenteditable 为 AXStaticText），键盘输入路径需人工验证
2. 多选/分布对齐、元素大纲面板未做
3. SPA 动态页保存固化渲染结果（继承 v4.1 已知限制）
4. 旧 `src/app` Web UI 为遗留参考实现，未随本轮更新

---

## 1. 项目来龙去脉（v4.1 记录）

日期：2026-09-09  
范围：`src/app` 全量源码 + 部署脚本

## 1. 项目来龙去脉

前身是 `_build/` 下的本地工具：FastAPI 后端 + 单页前端 + 原生 macOS 文件选择器。  
目标是让用户像 PowerPoint 一样编辑任意 HTML（站点式 / 流式 / HTML-PPT），双击改字、拖拽缩放、插入元素，不写代码。

原结构问题：

- 源码、打包 Python 运行时、release 产物混在 `_build/`，不利于版本管理
- 无 `requirements.txt` / README / LICENSE / 启动脚本的统一入口
- CSS/JS 在文件树中标注「只读」，但后端已有 `read` / `save-raw` 能力
- 缺少 PPT 核心能力：动效编辑、对齐分布、演示模式、更多插入类型

## 2. 架构结论（保留）

```
浏览器 SPA (static/index.html)
        │
        ▼
FastAPI 127.0.0.1:9100 (server.py)
  ├─ /api/pick, /analyze, /import     打开入口
  ├─ /api/project/open|read|save-raw  项目与文件 I/O
  ├─ /api/live/{path}                 实景渲染（同源 iframe）
  └─ /api/preview                     同源预览快照
```

核心设计：**实景 iframe + 覆盖层编辑**。  
不经过 GrapesJS 等虚拟 DOM 层，复杂站点与 JS 动态页真实渲染；编辑直接改 iframe DOM，保存时 `serializeFull` 写回源文件。

安全边界（保留并已冒烟验证）：

- 仅绑定 127.0.0.1
- 项目根限制在用户主目录；敏感目录/文件黑名单
- 路径穿越防护、CSRF Host/Origin 校验、CSP 响应头
- 项目会话 token（HttpOnly cookie / X-Project-Token）
- 原子写 + 备份轮转（5 份）+ mtime 冲突检测

## 3. 本次修复与功能更新

### 修复

| 项 | 说明 |
|----|------|
| `launcher.py` 去掉 `eval()` | 版本探测改为安全解析 |
| CSS/JS 只读标注 | 改为可点击打开源码编辑器 |
| 路径注入风险 | 源码编辑入口改用索引表，避免 onclick 字符串拼接路径 |
| 缺少依赖声明 | 新增根目录与 `src/app/requirements.txt` |
| 工程结构 | 源码收敛到 `src/`，脚本在 `scripts/`，文档在 `docs/` |

### 新增功能

| 功能 | 说明 |
|------|------|
| **动效面板** | 入场（淡入/滑入/缩放/弹跳/旋转/翻转）、出场、强调（脉冲/抖动/漂浮/发光/旋转）；可调时长、延迟、缓动、次数；一键播放/清除；Keyframes 注入页面 head，保存持久化 |
| **对齐工具** | 相对父容器左/右/水平居中、顶/底/垂直居中；自动处理 static 父级 |
| **演示模式** | F5 进入全屏放映；PPT 页 ←/→ /空格 翻页；Esc 退出；基于当前编辑态快照 |
| **插入元素库** | 文字框、标题、按钮、分隔线、引用、卡片、图标、容器、视频 |
| **CSS/JS 源码编辑** | 侧栏点击样式/脚本 → 暗色源码编辑器 → 保存写回磁盘（带备份） |

### 验证

- 前端 JS：`node --check` 通过
- 后端：`py_compile` 通过；uvicorn 启动成功
- API 冒烟：
  - `GET /`、`/static/index.html` → 200
  - `POST /api/project/open` → ok + token + cookie
  - `GET /api/live/*` 带 cookie → 200；无 token → 403
  - `POST /api/preview` 带 X-Project-Token → 返回 url
  - `POST /api/project/read` + `save-raw` → 读写成功，生成 `.bak`，mtime 冲突 409 正常触发
  - 无 X-Requested-With 的 mutation → CSRF 403

## 4. 已知限制 / 后续建议

1. **动态页（React/Vue SPA）**：保存会固化渲染结果；已用 confirm 警告，仍建议导出快照。
2. **Shadow DOM**：序列化会丢失内容；已有拦截提示。
3. **多选对齐**：当前是「选中元素对齐到父级」；多选后互相对齐/分布可做二期。
4. **动效触发方式**：目前是 CSS `animation` 即播；点击触发 / 滚动触发需要 IntersectionObserver 或 class 切换，可后续加。
5. **撤销模型**：整页 innerHTML 快照；超大 DOM 会占内存（已有 maxUndo 缩放）。
6. **无自动化 E2E**：建议后续加 Playwright 对打开/编辑/保存链路做回归。

## 5. 目录结构（v4.1）

```
html编辑器/
  README.md
  LICENSE
  requirements.txt
  .gitignore
  src/app/
    server.py
    launcher.py
    requirements.txt
    static/index.html
    native/
    samples/
  scripts/
    start.sh
    install-macos.sh
    start-windows.bat
  docs/
    REVIEW.md
```

## 0.1 v4.3.1 会商 LOOP（2026-09-13 下午）— 用户报告 P0 后的完整回归

用户实测报告「打开任何 HTML 显示 {"detail":"not found"} 且黑屏、工具栏全暗」。启动会商机制（用户视角 / 工程师视角 / 对抗测试 / 代码审计 / 稳定性 / 数据完整性，每轮独立 prompt），共 6 轮测试-修订-再测试 LOOP。

### 用户报告的 P0 根因链（Round-0 复现）

| 现象 | 根因 | 修复 |
|------|------|------|
| 工具栏全暗 | 系统深色模式下 `.regularMaterial` 变深色材质，墨色文字不可读 | 窗口强制浅色外观（`NSAppearance .aqua`，符合 kangzhe 全轨浅色铁律） |
| 黑屏 + not found | WKWebView 深色模式渲染无样式 JSON 404 → 黑底白字 | 404 改浅色 HTML 错误页 + 外观强制 |
| not found 本体 | 引擎绑定 `*:9100`（全网卡）+ 多实例并存时请求分裂到不同 root 的实例 | 绑定收紧 127.0.0.1（`requiredLocalEndpoint`）+ 单实例互斥（DistributedNotificationCenter，后来者自退、前任前置） |

### 会商各轮新发现与修复

| 轮次 | 视角 | 发现 → 修复 |
|------|------|------------|
| R1 | 用户（浏览器侧）+ 工程师（合同） | 遗留 Web UI 暴露根路径且会话协议断裂 → `/` 改引擎说明页；previewAnim `animation=''` 级联清空 longhand（预览即销毁动效）→ longhand 快照恢复；open 不存在路径返回 200 假项目并踢会话 → 存在性校验；re-exec 单引号路径断裂 → `$1` 参数传递；端口千分位 `9,100` → `Text(verbatim:)`；strip 残留 `data-v4-*` → 清除 |
| R2 | 对抗测试 + 代码审计 | **引擎绑全网卡 + read/save 无 token（局域网未授权读写）** → loopback 绑定 + token 校验；`<base href>` 反射注入（同源 XSS 进原生桥）→ HTML 属性转义；兄弟目录前缀绕过（`proj` vs `proj2`）→ 围栏加 `/` 边界；目录 save 假成功 → isDir 校验；守卫「保存后导航」中止异步 fetch 静默丢稿 → pendingNavigation 续延；点击空白选中 body、Delete 删掉整个 body → 结构根元素禁选；外链/重定向把 token 带离项目 → decidePolicyFor 白名单（同 host）；save 写盘失败假成功 → 错误返回；undo 后触发式动画失活 → restore 重挂 runtime；负 Content-Length 崩溃 / 请求无上限 → 校验 + 64MB 上限；/static 穿越 → 围栏；备份同秒覆盖 + 无限累积 → 毫秒时间戳 + 轮转 keep=20；演示键码错误（`[`/`I`）→ PageUp/Down；侧栏图标恒假 → ext 无点比较；防抖竞态误施新元素 → 元素指纹校验；根相对资源（/style.css）404 → 根路径映射项目目录 |
| R2.5 | 自测回归 | 保存注入回归：`JSONSerialization([path])` 把 `__jibaPath` 变数组 → 全部保存 403「不在项目内」；改字符串顶层 → NSJSONSerialization 崩溃 → 终案：数组序列化 + JS `[0]` 解包 |
| R3 | 终验合同 | 备份轮转在串行 HTTP 队列同步枚举目录，FS 瞬时阻塞死锁全引擎 → 轮转移后台队列 |
| R4 | 稳定性 | 轮转按字典序，垃圾 `*.bak.<hash>` 挤掉真实时间戳备份 → 按 mtime 排序 |
| R5/R6 | 数据完整性 / UI 终验 | **P0-P4 清零**（连续两轮） |

### LOOP 证据

- 20 连发保存全部 200、单次 ≤2.4ms；3MB 报文 38.5ms；21 并发混合轰炸 63ms 全响应；pkill 秒级恢复
- 端到端数据链：open→live 逐字节一致→编辑保存 diff 仅预期行→备份恰为保存前版本→跨会话持久 ✓
- UI：打开面板中文/空格文件名、33MB 真实文档渲染、动效应用+播放+保存落盘、PPT 翻/复制/删除页、演示进出无黑屏、守卫保存后自动续导航、深色系统下全浅色可读

### 已知遗留

- 双击改字后的键盘输入路径未自动化（AX 无法写 contenteditable），需人工验证
- `~/Applications` 下升级安装时旧实例若在运行，双击只激活旧版——升级前请先退出旧实例
- 9100 被第三方进程占用时两实例并存的可能仍在（低概率，cookie 按域共享会互踩）
- 演示模式 cover 缩放在极端宽高比下会裁切边缘（contain 更保守，未改）
