# Flow 视觉规范

日期：2026-11-09。

## 标识

用连续曲线构成向前流动的小写 f，呼应 Flow 的图片与视频浏览。珊瑚红底与米白符号保持清楚的轮廓；页内标识与系统图标使用同一份画稿，不再混用闪光图案和大写 FLOW。

- 原始画稿：[flow-icon-source.png](brand/flow-icon-source.png)。由内置 imagegen 生成；透明草稿的边缘质量不适合作为正式资源，最终选用干净的不透明画稿。
- 应用图标：`Flow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`，1024 × 1024、sRGB、无 alpha。iOS 负责系统图标圆角。
- 页内图标：`Flow/Resources/Assets.xcassets/FlowLogo.imageset/FlowLogo.png`，512 × 512，在代码中按尺寸使用连续圆角。
- 打包：在 `ios/` 运行 `swift scripts/GenerateIcon.swift`。仅调整输出尺寸与 RGB 像素格式，不重新绘制或改变原始构图。

## 色彩

| 用途 | 浅色 | 深色 |
| --- | --- | --- |
| 交互强调 | #AD4036 | #EEA092 |
| 强调底色 | #F3E4DF | #3E2B27 |
| 页面 | #F7F5F1 | #141516 |
| 分组与卡片 | #FFFDFA | #1F2022 |
| 内嵌区域 | #F0EDE7 | #292A2C |
| 主要文字 | #292724 | #F3EFE9 |
| 次要文字 | #716D68 | #AAA6A0 |
| 分隔线 | #E4DFD8 | #36383B |

图标原稿以 #C44D43 珊瑚红为目标色；浅色界面的交互红加深，以保证小字可读。选中标签文字对比度约 4.76:1，白色主按钮文字约 5.89:1；深色主按钮使用石墨色文字，避免浅红底上的白字对比不足。

## 排版与控件

- 使用系统动态字体；标题以 semibold 为主，品牌字标使用圆体小写 flow。提示词和生成参数保留等宽字体。
- 页面左右边距 20 pt；媒体卡片连续圆角 20 pt；筛选、搜索、图标按钮和媒体工具圆角 14 pt。
- 分类与收藏夹共用浅色选中标签；描边 0.5 pt，点击区域至少 44 pt。选中还通过字体和辅助功能状态表达。
- 原生表单和弹层使用相同的页面背景、分组间距与行高。错误仍保留明确的语义提示。
- 沉浸浏览保留黑色媒体背景，品牌、模式菜单、静音和操作按钮共用同一套标识、圆角及半透明底色。
- 成功浮窗沿用 2 秒后淡出的行为，统一为圆角半透明面板。
- 官网嵌入页面保留网站自身样式；本次统一应用的原生外壳。

## 生成方式与提示词

使用内置 imagegen 工具，未调用 API CLI。以下为实际提示词，最终资源使用第二步的不透明图标画稿。

### 初始标识探索

```text
Use case: logo-brand
Asset type: master logo mark for Flow, a native iOS image and video discovery app.
Primary request: design one simple, elegant, distinctive abstract lowercase f monogram that feels like a fluid ribbon in motion. Restrained editorial design, confident silhouette, generous balanced negative space, beautifully controlled curves and slightly softened terminals. It must remain instantly legible as a small 24-point UI brand symbol.
Style: flat vector-like mark, one solid ivory-white silhouette with crisp clean antialiased edges. One cohesive symbol, not a font glyph, no disconnected decorative dot. Optical balance, graceful flowing bend at the top and a clear short crossbar.
Composition: square 1024 by 1024 canvas, mark centered, occupies about 68 percent of canvas height, enough clear space on all four sides.
Background: genuinely transparent alpha.
Text: none. Only the f-shaped symbol.
Avoid: app icon background tile, rounded square frame, gradients, shadows, bevels, 3D, texture, glow, sparkle, play triangle, camera outline, mockup, presentation sheet, multiple options, extra symbols, lettering or watermark.
```

### 最终图标精修

输入：第一步的 f 轮廓参考。

```text
Use case: logo-brand
Asset type: final production iOS app icon for Flow.
Input image: the transparent f logo is the edit target and silhouette reference.
Primary request: refine this flowing lowercase f into immaculate, smooth, flat vector-like geometry and place it on a completely solid muted vermilion coral square (#C44D43). Preserve the distinctive continuous sweeping f concept, leaning slightly forward, rounded top curl and gently curving stem with a short crossbar. Remove ALL rough speckles, jagged edges, detached fragments and texture. A single crisp ivory-white (#FFF9F2) cohesive silhouette. Optically balanced, elegant, minimal, restrained.
Composition: full-bleed 1024x1024 square with straight outer corners (iOS applies its own mask), centered symbol occupies 64 percent of canvas height, comfortable negative space. The coral background must go to every edge and be fully opaque.
Text: none.
Constraints: only one symbol and one flat background. No gradients, no shadows, no 3D, no gloss, no bevels, no frame, no border, no sparkle, no watermark, no mockup, no collage, no rounded outer tile.
```
