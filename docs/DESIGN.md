# HTML辑霸 设计规范（App + Web 一致）

## 品牌
| 项 | 值 |
|----|-----|
| 名称 | HTML辑霸 |
| 图标 | `assets/AppIcon.png`（同步到 `src/app/static/assets/logo.png`） |
| 强调色 | `#FF9900` / 副 `#FFCC00` / 深 `#DB6B05` |
| 墨色主字 | `#0F1115` |
| 次级字 | `#525A66` |
| 三级字 | `#7A828E`（仍需可读，禁止用近白灰） |

## 对比度铁律
1. **禁止** 浅色字出现在半透明浅玻璃上（`ultraThinMaterial` / `glassEffect(.regular)` 无底色）。
2. 玻璃面板必须有 **白色 ≥72% 填充** 或 **深色实底**；文字用 `Theme.ink`。
3. 白色文字 **只允许** 出现在 **实心橙色按钮** 或 **深色 Toast/演示遮罩** 上。
4. 禁止 `Color.primary` 自适应色叠在 `fill(.clear)` + glass 上（在浅色外观下会变成浅灰）。

## Liquid Glass 语言
- 连续圆角 `RoundedRectangle(cornerRadius:style:.continuous)` / CSS `border-radius:14px`
- 背景：`regularMaterial` + 白色半透明叠加；Web：`backdrop-filter: blur(20px) saturate(180%)`
- 描边：白色 0.65 透明度 0.5–1px
- 阴影：柔和低对比，偏黑 8–14%
- 强调：橙色实心渐变按钮，不用半透明橙玻璃承载白字

## 组件对照
| 组件 | Swift | Web |
|------|-------|-----|
| 顶栏 | `Theme.glassPanel.opacity(0.88)` + material | `#topbar` glass vars |
| 侧栏/检查器 | 同上 | `#sidebar` / `#panel` |
| 主按钮 | 实心橙渐变 + 白字 | `.open-cta` / `.save-btn` |
| Toast | 黑底 78% + 白字 | `#toast`（保持深底） |
| HUD | 白玻璃胶囊 + 墨色字 | `.hud-pill` |

## 版本
v4.3 · 2026-09-13（对齐 kangzhe-design-3d core：#FF9900 / #FFCC00 / #DB6B05 / 墨 #0F1115，全轨浅色 ONLY）
