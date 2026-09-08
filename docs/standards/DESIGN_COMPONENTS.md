# Component and Interaction Standards — Quotio

- Domain: design

> Enforceable component composition, geometry, sizing, and interaction rules based on the macOS 26 Apple HIG design language.

## Maintenance

- UI Agent maintains approved reusable composition/state rules; PM reviews scope and adoption.
- Apple macOS conventions are the foundation. The **Dual-Geometry System (外方内圆)** describes custom product components only; it does not override the appearance, geometry or behavior of native controls.

## 0. 原生组件与设置导航优先规则

- `[des-native-001] [hard]` 系统已有合适组件时优先复用。设置使用原生 `Form`、`Section`、`LabeledContent`、`Toggle`、`Picker`、`TextField`、`Stepper` 与 `Button`。系统分隔线、标准输入框、焦点环及默认按钮形状均允许且应保留。
- `[des-native-002] [hard]` 设置首页直接展示应用模式；分类使用单列系统导航行。页面入口使用 `NavigationLink` 和 `NavigationStack`，不手工模拟返回按钮、不通过切换主侧栏绕过返回路径。
- `[des-native-003] [hard]` 自定义配色、间距和信息层级必须服务于平台一致性。不得为了统一胶囊或卡片外形，牺牲系统导航、键盘交互、无障碍或可读性。本节优先于下面面向自定义组件的样式细则。
- `[des-native-004] [hard]` 页面配置采用 Push；删除、模式切换、密钥轮换等操作使用系统确认。不可中断的写入期间可暂时禁止返回，结束后恢复系统返回按钮，不替换为自绘按钮。

---

## 1. Capsule Button System (胶囊按钮规范)

- `[des-button-001] [hard]` Product-specific capsule buttons use `Capsule()` rather than arbitrary small rounded rectangles. Native action buttons retain their system silhouette and are not subject to forced capsule styling.
- `[des-button-002] [hard]` **Button Styles & Token Mapping**:
  - **Primary**: Solid accent color (e.g., `#2563EB` or `#22C55E`) or subtle linear gradient pill with white text (`.fontWeight(.semibold)`). Must include a 0.5pt subtle inner top highlight (`Color.white.opacity(0.15)`).
  - **Secondary / Inset**: `QuotioTheme.Colors.cardInset` background pill with primary/secondary text. Delivers a quiet, integrated feel inside cards.
  - **Bordered / Outline**: Transparent background with `QuotioTheme.Colors.sidebarBorder` (or accent color opacity 0.25) hairline stroke.
  - **Destructive**: `QuotioTheme.Colors.danger` with light background tint (`danger.opacity(0.12)`) and red label.
- `[des-button-003] [hard]` **Sizing Standards**:
  - **Large (L - 36pt height)**: Modal dialog primary confirmation, onboarding setup actions. Font: 13pt / Semibold, horizontal padding: 18pt.
  - **Medium (M - 30pt height)**: Screen toolbars, card-level actions, search filter toggles. Font: 12pt / Medium, horizontal padding: 14pt.
  - **Small (S - 24pt height)**: Table/list row inline quick actions (copy, retry, refresh). Font: 11pt / Medium, horizontal padding: 10pt.
- `[des-button-004] [hard]` **Tactile Press Physics**: Buttons must include active press scaling (`scaleEffect(configuration.isPressed ? 0.97 : 1.0)`) with spring release animation (`.spring(response: 0.25, dampingFraction: 0.7)`).

---

## 2. Capsule Segmented Controls & Tab Switchers (胶囊分段与Tab切换)

- `[des-tab-001] [hard]` All top navigation tabs and segmented filter controls (Usage Statistics period/source tabs, Call Analytics view switcher, Quota Provider switcher) MUST adopt the **Capsule Segmented Bar (`QuotioCapsuleSegmentedControl`)** architecture.
- `[des-tab-002] [hard]` **Track & Thumb Geometry & Multi-Layer Depth**:
  - **Outer Track (滑槽容器)**: Continuous `Capsule()` container. Fill: `QuotioTheme.Colors.cardInset` (`#0E111B`), Border: `QuotioTheme.Colors.sidebarBorder` 0.5pt, Inner padding: 3pt.
  - **Selected Thumb (滑块胶囊双层材质)**:
    - Base layer: Solid `QuotioTheme.Colors.cardBackground` (`#1C212F`).
    - Brand Ambient Tint Glow: Dynamic option brand color overlay (`tintColor.opacity(colorScheme == .dark ? 0.16 : 0.10)`) to infuse organic brand personality.
    - Hairline Highlight Stroke: LinearGradient border (`(tintColor ?? .white).opacity(0.42)` top to `0.14` bottom) with 0.75pt line width.
    - Diffuse Cast Shadow: `(tintColor ?? .black).opacity(colorScheme == .dark ? 0.35 : 0.12)`, radius 6, y: 1.5.
  - **Unselected Items**: Transparent fill (`Color.clear`), secondary text color (`Color.secondary`). Hover: `QuotioTheme.Colors.cardElevated` opacity 0.5~0.6 pill.
- `[des-tab-003] [hard]` **Silky-Smooth Spring Gliding Physics (丝滑弹簧滑动物理)**:
  - Container-level spring animation MUST be bound to the root container (`.animation(.spring(response: 0.30, dampingFraction: 0.74), value: selection)`) and coordinated via `matchedGeometryEffect(id: "ACTIVE_CAPSULE_THUMB", in: segmentNamespace)`.
  - Ensures external Binding updates and direct clicks glide seamlessly without jumping or frame snapping.
  - Interactive tactile tap feedback: `scaleEffect(configuration.isPressed ? 0.96 : 1.0)` with spring release.
- `[des-tab-004] [hard]` **Dynamic Brand Tinting (按项专属品牌色体系)**:
  - Supports `optionTint: ((Option) -> Color?)?` allowing individual options to dynamically project their signature brand identity:
    - **Claude Code**: `QuotioTheme.Colors.claudeOrange` (Anthropic Terracotta Orange `#D97757`).
    - **Claude Code 用量统计页例外**: 使用 `QuotioTheme.Colors.claudeUsage(for:)`，与该页黄色系热力图、单来源趋势图一致；其他页面仍沿用官方暖橙色。
    - **Codex**: `QuotioTheme.Colors.codexGreen` (OpenAI Emerald `#10A37F`).
    - **OpenCode**: `QuotioTheme.Colors.opencodeBlue` (Terminal Sky Blue `#3B82F6`).
    - **All / Neutral**: `.indigo` or system accent.
- `[des-tab-005] [hard]` **Height & Sizing Specifications**:
  - **Large (34pt height)**: Page-level primary navigation, font 13pt / Semibold, horizontal padding: 16pt.
  - **Medium (30pt height)**: Filter decks, source pickers, range controls, font 12pt / Medium (12pt Semibold active), horizontal padding: 14pt.
  - **Small (26pt height)**: In-card rankings, popover filters, font 11pt, horizontal padding: 10pt.

- `[des-tab-006] [hard]` 用量统计顶部筛选固定两行：来源在第一行，视图/时间范围在第二行。宽窗口不得自动合并两行，窄窗口保留各行独立横向滚动。

### 仪表盘筛选与总览（2026-09-07 用户确认）

- `[des-dashboard-001] [hard]` CPA 卡片下方的筛选区默认折叠，收起时保留当前条件摘要和更多筛选入口；点击标题行展开时间范围、分组、提供商，使用共享胶囊分段控件。折叠只影响展示，不清空或重置筛选条件。顶部时间范围仅保留预设选项，自定义日期与时间在完整筛选面板中保留；分组与提供商在窄窗口拆行。
- `[des-dashboard-002] [hard]` “更多筛选”保持固定入口，使用原生 Sheet 展示全部八项条件。草稿重置和取消不影响当前统计，应用一次提交完整条件；按钮计数只包含常驻区未展示的附加条件，其中包括已启用的自定义时间。选项目录可读取完整本地索引，不能启动额外采集。
- `[des-dashboard-003] [hard]` 总览使用四个主指标内嵌卡：请求数、Tokens、成功率、平均延迟；图标默认彩色，数字使用系统主文本色。十三项次级指标在一个轻量底面内分成 Token 用量、缓存、性能与吞吐、请求结果四组，名称和值同行、名称左对齐、数值右对齐。宽窗口四列、中等宽度两列，极窄时单列；全部指标直接展示，不再设置“更多指标”，不重复同一指标。
- `[des-dashboard-004] [hard]` 已知正数下界使用“≥”，未知数值使用“—”；总体分母无法确定时不能显示精确比率。历史日汇总与单次请求分开显示，不用旧日桶虚构请求时间、缓存拆分或请求详情。

---

## 3. Capsule Input Fields & Search Bars (胶囊输入框与搜索框)

- `[des-input-001] [hard]` Custom capsule inputs use `Capsule()`. Native settings inputs may use the system default or `.textFieldStyle(.roundedBorder)`; native search uses `.searchable`. Do not replace system focus behavior merely for visual uniformity.
- `[des-input-002] [hard]` **Structure & Visual Tokens**:
  - **Height**: Standard 32pt to 34pt.
  - **Background**: `QuotioTheme.Colors.cardInset` (`#0E111B` in Dark Mode) with 0.5pt `sidebarBorder` stroke.
  - **Leading Icon**: SF Symbol (e.g., `magnifyingglass`, `key`, `network`) in `.tertiary` styling.
  - **Trailing Action**: Clear button (`xmark.circle.fill`) appears smoothly when text is present.
- `[des-input-003] [hard]` **Focus State (聚焦微光)**: When active, the border transitions to a subtle breathing focus ring (`Color.accentColor.opacity(0.4)`, 1.5pt lineWidth) with soft glow, without displacing surrounding layout.

---

## 4. Status Pills, Badges & Metric Tags (状态与指标胶囊)

- `[des-pill-001] [hard]` Status indicators, provider account counters, subscription badges (Pro/Free/Team), and token metrics MUST use `Capsule()` geometry.
- `[des-pill-002] [hard]` **Dimensions**: Fixed micro-height (18pt ~ 20pt), font: 11pt, horizontal padding: 6pt ~ 8pt.
- `[des-pill-003] [hard]` **Numeric Uniformity**: Dynamic numeric counters inside pills MUST apply `.monospacedDigit()` to prevent width shudder during rapid data updates.

---

## 5. Structural Cards & Surface Hierarchy (外方卡片体系)

- `[des-card-001] [hard]` Custom cards use continuous corners with `QuotioTheme.Radius.lg` or `.xl`. System Form/Section containers retain native geometry and spacing.
- `[des-card-002] [hard]` Floating cards use `QuotioTheme.Colors.cardBackground` (`#1C212F`), 0.5pt subtle white border highlight, and deep diffuse shadow (`Color.black.opacity(0.35)` radius 14, y: 5).
- `[des-card-003] [hard]` Inner recessed card compartments (such as detail drawers and metric wells) MUST use `QuotioTheme.Colors.cardInset` with `Radius.md` (10pt) continuous corners.
- `[des-card-004] [hard]` **Zero-Divider Inset Well Architecture (零分割线嵌套槽卡片组)**:
  - Collapsible provider decks and multi-account groups MUST NOT use table separators or horizontal divider lines (`Divider()`).
  - Outer grouping card: `QuotioTheme.Radius.lg` (14pt) squircle with `cardBackground` and `sidebarBorder` hairline stroke.
  - Accordion trigger: Interactive header with spring-animated rotating chevron (`.spring(response: 0.32, dampingFraction: 0.80)`) and provider brand capsule badge.
  - Accounts Inset Well: `QuotioTheme.Colors.cardInset` recessed container with `Radius.md` (10pt) continuous corners, housing independent floating account tiles separated by 6pt negative space.
  - Floating Account Tiles: `Radius.md` (10pt) squircle tiles with smooth 120ms hover elevation to `cardElevated`.
  - Row Action Controls: 26pt circular interactive targets (`Circle()`) with subtle background wash on hover.

---

## 6. Prohibited Anti-Patterns (禁用模式)

- Native separators are expected in system forms and lists. Only custom inset card decks should prefer spacing over unnecessary table-style separators.
- ❌ **Rectangle with 4–8px radius on buttons or tabs**: Violates the macOS 26 capsule design rule.
- System `.roundedBorder` text fields are permitted in native forms. Do not mix custom input skins and native field styles arbitrarily within the same setting group.
- ❌ **`.ultraThinMaterial` on segmented controls**: Produces a washed-out, milky blur on dark canvases; use solid `cardInset` + `cardBackground` instead.
- ❌ **Instantaneous 0ms hover/active state changes**: Always use spring or 150–200ms ease transitions.
- ❌ **Emojis as interface icons**: Use SF Symbols exclusively.
