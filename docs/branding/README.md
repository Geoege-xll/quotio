# QuotioPlus 1.0.0 图标

最终母版：[quotio-plus-icon.png](quotio-plus-icon.png)。该文件保留透明边缘，尺寸为 1254 × 1254；应用资源按 Xcode 要求生成 16～1024 像素各规格。

图案参考 [原 Quotio 图标](https://github.com/nguyenphutrong/quotio/blob/13fd478c5b69f361d078e3b3bfc7ec041dde850d/Quotio/Assets.xcassets/AppIconImage.imageset/icon.png) 的猫咪、放大镜与统计图概念进行重绘，保留对 Trong Nguyen 及原项目贡献者的致谢和 MIT 许可声明。配色遵循 [设计基础规范](../standards/DESIGN_FOUNDATIONS.md)：午夜蓝底色、灰白猫咪、信息蓝与少量薄荷绿。

图标使用内置 `image_gen` 工具生成和透明背景处理。首轮字母方案未采用；带棋盘格背景的动物草稿也未作为应用资源。仓库仅保存最终透明母版。

## 更新资源

```bash
bash scripts/update_app_icon.sh
```

脚本只做尺寸转换，同步 `AppIcon`、`AppIconBeta`、`AppIconImage`、`AppIconBetaImage` 四组资源，避免侧栏、关于页面、Dock 或更新通道切换时出现旧图标。

## 生成提示词

```text
Use case: logo-brand. The attached image is the ORIGINAL UPSTREAM ICON and is a visual concept reference. Create a new, independently recognizable QuotioPlus macOS app icon inspired by its friendly cat holding a magnifying glass with a usage histogram. Preserve the animal mascot concept, cat + magnifying glass + simple rising bars, but redesign the artwork and colors to match this project's documented native macOS UI palette. Deliver ONE finished square app-icon artwork, straight on, 1024x1024 intent, genuine transparent margin outside a smooth macOS rounded-square tile, no presentation board or variations. Color specification grounded in our UI: background tile midnight navy #101420 with subtle raised navy #1C212F; cat predominantly soft white #F8FAFC and slate-gray #CBD5E1 with tasteful dark navy outlines; magnifying-glass frame information blue #60A5FA; three bold simple bars in blue #60A5FA and mint green #34D399. The bright white friendly cat must be the main subject, recognizable ears, face, two small paws, warm confident expression. Large clean silhouette, uncluttered interior, restrained soft dimensional shading, polished contemporary Apple app icon craft. Make magnifying glass about 38 percent of the tile width toward the lower right, held naturally by the cat, preserving most of its readable face. Light lens interior keeps the histogram clearly visible. Balanced composition and strong contrast at small Dock and sidebar sizes. Keep the animal cute but refined, no elaborate fur textures, no extra props. All principal artwork contained within the tile. About 7 percent transparent safe margin around the tile. Avoid neon purple, magenta, rainbow gradients, glossy plastic, excessive glow, orange-dominant fur, heavy black strokes, words, letters, Q symbols, plus symbols, typography, labels, tiny details and watermarks. This is a working desktop app icon, not an illustration scene. Do not include the rejected Q+ monogram.
```

## 透明背景处理提示词

```text
Use case: background-extraction / precise-object-edit. Edit the attached finished app icon. Keep the navy rounded-square tile, gray-white cat, magnifying glass, blue and mint bars, all artwork, exact geometry, lighting, proportions and colors unchanged. ONLY remove the white/light-gray CHECKERBOARD pattern OUTSIDE the rounded-square tile and replace that outside region with actual transparent alpha pixels in the delivered PNG. This checkerboard is currently baked into the image and is NOT real transparency. The delivered file MUST have an alpha channel with 0 alpha at all canvas corners and true transparent empty margin outside the icon silhouette. Do not render any checkerboard pattern, white backdrop, black backdrop, mockup, or new background; actual transparent PNG cutout is required. Preserve smooth anti-aliased outer tile edges and the existing approximately 7 percent margin. Do NOT change the cat, bars, magnifying glass, palette, tile silhouette or design. One square finished transparent app-icon asset.
```
