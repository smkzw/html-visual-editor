# 项目 Review 记录 · HTML 可视化编辑器 v4.1

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
