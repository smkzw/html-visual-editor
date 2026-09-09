# HTML 可视化编辑器 · HTML Visual Editor

> 像做 PPT 一样编辑任何网页。双击改字、拖拽缩放、插入形状图片、配置动效、全屏演示，全程不用写代码。

本地运行的 HTML 可视化编辑器：实景渲染真实页面，在覆盖层上做所见即所得编辑，兼容**站点式**（多文件网站）、**流式**（长页滚动）与 **HTML-PPT**（多页演示稿）。

## 功能亮点

| 类别 | 能力 |
|------|------|
| 打开 | 系统原生选择器 / 拖入文件或文件夹 / 自动识别单文件·网站·独立页集合 |
| 编辑 | 双击改字、富文本栏、拖拽移动、八向缩放、属性面板（字体/布局/外观） |
| 插入 | SVG 形状库、图片（URL/本地内嵌）、表格、文字框、按钮、卡片、分隔线、视频… |
| 动效 | 入场 / 出场 / 强调动效库，可调时长·延迟·缓动·次数，写入页面 CSS 持久化 |
| 对齐 | 相对父容器左/右/水平居中、顶/底/垂直居中 |
| PPT | 自动检测多页、缩略图、拖拽排序、复制/删除页、演示模式（F5） |
| 工程 | 多文件网站实景加载、CSS/JS 源码编辑、60 步撤销重做 |
| 保存 | 原子写入、自动备份轮转、mtime 冲突检测、导出纯净 HTML |

## 快速开始

### 方式一：一键启动（推荐）

```bash
# macOS / Linux
./scripts/start.sh

# Windows
scripts\start-windows.bat
```

首次运行会自动创建虚拟环境并安装依赖（fastapi / uvicorn / python-multipart）。

### 方式二：安装为 macOS App

```bash
./scripts/install-macos.sh
```

安装到 `~/Applications/HTML可视化编辑器.app`，双击即可启动。

### 方式三：手动运行

```bash
cd src/app
python3 -m venv .venv
source .venv/bin/activate
pip install -r ../../requirements.txt
uvicorn server:app --host 127.0.0.1 --port 9100
# 浏览器打开 http://127.0.0.1:9100
```

浏览器请使用 **Chrome / Edge**（Chromium 内核）。

## 示例

`src/app/samples/` 内含：

- `demo-page.html` — 单文件网页
- `demo-site/` — 多页 HTML-PPT 演示稿

## 架构

```
src/app/
  server.py          FastAPI 后端：文件 I/O、安全沙箱、实景渲染、预览
  launcher.py        跨平台启动器（venv + uvicorn + 浏览器）
  static/index.html  前端编辑器（单页应用）
  native/            macOS 原生文件选择器（Swift AppKit）
  samples/           示例文件
scripts/
  start.sh           macOS/Linux 一键启动
  install-macos.sh   安装为 .app
  start-windows.bat  Windows 一键启动
```

编辑器架构：**实景 iframe**（`/api/live/*` 真实 URL，同源）+ **覆盖层编辑**。  
不经过虚拟 DOM 抽象层，复杂站点与 JS 动态页都能真实渲染；编辑操作直接改 iframe DOM，保存时序列化写回源文件。

## 安全说明

- 仅监听 `127.0.0.1`，不对外网开放
- 项目根限制在用户主目录内，敏感目录（`.ssh` / `.aws` / `.config` 等）黑名单拦截
- 路径穿越防护、CSRF 校验、CSP 响应头
- 保存带自动备份（每文件保留最近 5 份）
- 编辑会**真实修改你的文件**，重要文件请先备份

## 系统要求

- Python 3.10+
- Chrome / Edge 浏览器
- macOS 或 Windows（Linux 可用启动脚本）

## License

MIT
