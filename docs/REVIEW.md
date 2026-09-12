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
