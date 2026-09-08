# Design System Master File — Quotio (macOS 26 Edition)

> **LOGIC:** This Master document defines the global macOS 26 Apple HIG design system tokens, component patterns, and interaction rules for Quotio.

---

**Project:** Quotio\
**Updated:** 2026-09-06\
**Platform:** macOS 14+ (macOS 26 Design Direction)\
**Category:** Developer Tool / AI Gateway & Quota Manager\
**Design Paradigm:** **外方内圆 (Squircle Containers + Capsule Controls)**

---

## 1. Global Color Tokens

| Role | Dark Hex | Light Hex | SwiftUI Token | Usage |
|------|----------|-----------|---------------|-------|
| Canvas Background | `#101420` | `#F8FAFC` | `QuotioTheme.Colors.canvasBackground` | Global window background, penetrates toolbar |
| Sidebar Background | `#121624` (35%) | `#F1F5F9` (40%) | `QuotioTheme.Colors.sidebarBackground` | Translucent vibrancy sidebar panel |
| Card Background | `#1C212F` | `#FFFFFF` | `QuotioTheme.Colors.cardBackground` | Floating cards, modal panels, selected tabs |
| Card Inset (沉槽) | `#0E111B` | `#F1F5F9` | `QuotioTheme.Colors.cardInset` | Input fields, tab tracks, metric wells |
| Card Tag (胶囊标) | `#242A38` | `#E2E8F0` | `QuotioTheme.Colors.cardTag` | Account badges, active model chips |
| Card Elevated | `#262D3E` | `#FFFFFF` | `QuotioTheme.Colors.cardElevated` | Hover and active card states |
| Sidebar Border | `rgba(255,255,255,0.08)` | `rgba(0,0,0,0.08)` | `QuotioTheme.Colors.sidebarBorder` | 0.5pt subtle container hairline border |
| Accent / Primary | `#2563EB` / `#22C55E` | `#2563EB` | `Color.accentColor` | Primary actions, switches, focus rings |

---

## 2. Geometry & Spatial Hierarchy (外方内圆)

### A. 外方：结构容器层 (Squircle Containers)
- **Window & Sidebars**: Full-bleed macOS native panel with integrated traffic lights.
- **Surface Cards**: Apple continuous Squircle with `Radius.lg: 14pt` or `Radius.xl: 16pt`.
- **Inner Compartments**: Sub-wells inside cards use `Radius.md: 10pt`.

### B. 内圆：交互件与状态层 (Capsule Controls)
- **Buttons**: All action buttons MUST use `Capsule()`.
- **Tab Switchers**: Both the outer track and the inner sliding thumb MUST use `Capsule()`.
- **Input Fields**: Single-line text inputs and search fields MUST use `Capsule()`.
- **Badges & Pills**: Status, tier, and counter indicators MUST use `Capsule()`.

---

## 3. Core Component Specifications

### 1. Capsule Buttons
- **Shape**: `Capsule()` (border-radius: 9999px).
- **Primary**: Solid accent color pill with white semibold text and 0.5pt inner highlight.
- **Secondary / Inset**: `cardInset` (`#0E111B`) pill with medium text.
- **Bordered**: Transparent background with 0.5pt `sidebarBorder` stroke.
- **Sizes**:
  - **L (36pt height)**: Modal actions, primary confirm (`font: 13pt/semibold`, `px: 18pt`).
  - **M (30pt height)**: Toolbar actions, card triggers (`font: 12pt/medium`, `px: 14pt`).
  - **S (24pt height)**: In-row actions, copy/refresh (`font: 11pt/medium`, `px: 10pt`).
- **Tactile Interaction**: Active press compression `scaleEffect(0.97)` with spring return.

### 2. Capsule Segmented Controls & Tab Switchers
- **Outer Track**: Continuous `Capsule()` container.
  - Background: `cardInset` (`#0E111B`), Border: 0.5pt `sidebarBorder`, Padding: 3–4pt.
- **Active Thumb**: Floating `Capsule()`.
  - Background: `cardBackground` (`#1C212F`), Shadow: `rgba(0,0,0,0.35)` radius 4, y: 1.5, Border: 0.5pt `rgba(255,255,255,0.08)`.
- **Transition**: Smooth spring sliding animation (`.spring(response: 0.28, dampingFraction: 0.72)`) between tabs.
- **Height**: Standard 32pt, Compact 28pt. Text: 12pt Medium / Semibold.

### 3. Capsule Input Fields & Search Bars
- **Shape**: `Capsule()` (height 32–34pt).
- **Background**: `cardInset` (`#0E111B`) with 0.5pt `sidebarBorder`.
- **Leading Element**: SF Symbol icon with `tertiary` color.
- **Trailing Action**: Circular clear button when text is present.
- **Focus State**: Soft breathing focus ring (`accentColor.opacity(0.4)`, 1.5pt lineWidth), avoiding square default system rings.

### 4. Capsule Badges & Metrics
- **Shape**: `Capsule()` (height 18–20pt).
- **Typography**: 11pt medium with **`.monospacedDigit()`** to prevent layout shudder during counter updates.

---

## 4. Typography & Numerics

- **Primary UI Font**: San Francisco (System default).
- **Monospace Font**: SF Mono / system monospaced design for code and numerical meters.
- **Tabular Figures**: Every numeric display (Token metrics, latency, percentage, pricing) MUST apply `.monospacedDigit()`.

---

## 5. Prohibited Anti-Patterns

- ❌ **Rectangle buttons with 4–8px radius**: Violates the macOS 26 capsule standard.
- ❌ **System `.textFieldStyle(.roundedBorder)`**: Incompatible with the dark canvas.
- ❌ **`.ultraThinMaterial` on segmented controls**: Creates washed-out milky artifacts on `#101420`.
- ❌ **Emojis as interface icons**: Use SF Symbols exclusively.
- ❌ **Instantaneous 0ms state changes**: Always employ spring or 150–200ms ease transitions.
