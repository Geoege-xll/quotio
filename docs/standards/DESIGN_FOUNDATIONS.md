# Design Foundations — Quotio

- Domain: design

> Long-lived visual, interaction, platform, token, and accessibility rules matching the macOS 26 Apple HIG design language.

## Maintenance

- PM decides update scope and adoption; UI Agent writes authorized rule changes. Establish or
  replace visual rules from approved decisions, not incidental page styling. Update in place and
  retain unaffected platform/accessibility constraints and stable rule IDs.
- Keep semantic token roles consistent with `QuotioTheme` tokens and production SwiftUI implementations.

## Product principles & Visual Philosophy

- `[des-principle-000] [hard]` **平台规范是产品设计的基础**：Apple macOS 人机界面规范决定窗口、导航、控件语义、焦点、键盘操作、无障碍与系统反馈。Quotio 的风格规范在此基础上统一信息结构、间距、密度和必要的品牌表达，不与平台规范竞争。发生冲突时修改产品规则，而不是自绘一个行为不同的系统控件。
- `[des-principle-001] [hard]` **macOS 26 Design Idiom**: Target the native macOS 26 appearance and interaction model. Prefer appropriate system components and system-managed materials; do not imitate the platform by adding arbitrary transparency, shadows, rounded corners, or custom navigation animations. Older supported systems retain their native appearance.
- `[des-principle-002] [hard]` **Dual-Geometry System (外方内圆)**:
  - **Custom Structural Containers (外方)**: Product-specific cards use continuous rounded rectangles (`Radius.lg` 14pt or `Radius.xl` 16pt). System windows, forms, lists and sheets retain system-managed geometry.
  - **Custom Interactive Controls (内圆)**: Capsule geometry is available for product-specific controls when appropriate. Native buttons, pickers, search fields and text fields MUST NOT be forcibly restyled merely to satisfy this geometry rule.
- `[des-principle-003] [hard]` **Information Density & Developer Precision**: Maintain high data legibility suited for professional developer tools. Combine elegant rounded surfaces with dense, monospace-aligned metrics.
- `[des-principle-004] [hard]` **设置页面**：应用模式置于设置首页；分类使用原生分组导航行，子页面使用 `Form`、`Section` 和系统控件。设置内容区使用单一 `NavigationStack`，由系统提供 Push、返回按钮、标题与导航过渡。禁止以手工页面替换、自绘返回栏或大卡片总览代替系统设置式结构。危险操作确认仍使用系统确认界面。

## Surface and Color Token Architecture

Custom product surfaces MUST reference tokens from `QuotioTheme.Colors` rather than raw hardcoded hex values. Native forms, lists, navigation and controls retain system semantic colors and materials instead of receiving forced token-based overlays:

| Token Role | Dark Value | Light Value | Purpose & Usage |
|---|---|---|---|
| `canvasBackground` | `#101420` (深邃黑蓝) | `#F8FAFC` (雪板浅灰白) | Global window canvas, penetrates navigation safe area |
| `sidebarBackground` | `#121624` @ 35% | `#F1F5F9` @ 40% | Vibrancy-backed translucent sidebar panel |
| `sidebarBorder` | `white.opacity(0.08)` | `black.opacity(0.08)` | Hairline 0.5pt subtle container divider |
| `cardBackground` | `#1C212F` (午夜蓝黑) | `#FFFFFF` (纯白浮层) | Floating cards, modals, and elevated selected capsule thumbs |
| `cardInset` | `#0E111B` (深色沉槽) | `#F1F5F9` (沉槽浅灰) | Capsule input fields, segmented control tracks, metric wells |
| `cardTag` | `#242A38` (微亮胶囊) | `#E2E8F0` (浅灰胶囊) | Account counter pills, active filter chips |
| `cardElevated` | `#262D3E` (高亮悬停) | `#FFFFFF` (高亮纯白) | Hover/Active card and button states |
| `claudeOrange` | `#D97757` (陶土暖橙) | `#D97757` (陶土暖橙) | Claude 官方主题色，用于 Claude 选项选中高光与光晕 |
| `claudeUsage(for:)` | `#FBBF24` (金黄) | `#925408` (深琥珀) | 用量统计页 Claude 来源专色，统一来源选择器、热力图和单来源日趋势；浅色模式加深以保证文字可读性 |
| `codexGreen` | `#10A37F` (翠绿翡翠) | `#10A37F` (翠绿翡翠) | Codex / OpenAI 官方主题色，用于模型高亮与分段高光 |
| `opencodeBlue` | `#3B82F6` (晴空终端蓝) | `#2563EB` (晴空终端蓝) | OpenCode 终端主题色，用于分段选中与状态点 |

- `[des-token-001] [hard]` Custom surfaces reuse `QuotioTheme.Colors` semantic tokens. Do not introduce arbitrary hex colors or manually simulate native materials. System-managed navigation and controls are not required to replace their native colors with custom tokens.
- `[des-token-003] [hard]` 用量统计页按 2026-09-07 的用户配色要求，Claude 使用 `claudeUsage(for:)` 黄色系，而非按名称散列颜色。此例外仅作用于统计页，不替换其他页面的 `claudeOrange` 品牌色；Codex 和 OpenCode 继续使用对应品牌色。模型分布色用于区分模型，不代表客户端来源；Token 类型色在摘要与展开明细中必须一致。
- `[des-token-002] [hard]` Custom elevated cards and floating capsules in Dark mode use the specified 0.5pt highlight and diffuse shadow where needed for optical separation. Do not add these effects to native form sections, navigation rows or system controls.

## Typography & Numeric Alignment

- `[des-type-001] [hard]` **Tabular Numbers**: Any fluctuating numerical display (token counts, percentages, request latencies, prices, countdowns) MUST apply `.monospacedDigit()` to prevent capsule badges and card layouts from jittering.
- `[des-type-002] [hard]` **Weight Hierarchy**: Bold headings (600–700), Medium labels (500), Regular body (400). Avoid ultra-thin or ultra-heavy weights for functional text.

## Motion & Tactile Feedback

- `[des-motion-001] [hard]` **System-first Motion**: Native navigation and controls retain system transitions. Custom transitions may use `.spring(response: 0.28, dampingFraction: 0.72)` when appropriate; do not override system Push or back animations.
- `[des-motion-002] [hard]` **Press Feedback**: Custom interactive capsules and cards may use subtle press compression. Native controls retain their standard feedback and must not receive a second scale animation.
- `[des-motion-003] [hard]` Respect `accessibilityReduceMotion`. When reduced motion is enabled, replace physics translation with smooth opacity crossfades.

## Accessibility & HIG Compliance

- `[des-accessibility-001] [hard]` Meet WCAG AA contrast ratio (minimum 4.5:1 for standard text, 3:1 for large text and key graphical boundaries).
- `[des-accessibility-002] [hard]` Never convey status exclusively through color; always pair colors with icons or textual labels.
- `[des-accessibility-003] [hard]` Maintain visible, accessible focus indicators on all interactive capsule inputs and controls.
