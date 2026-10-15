# QuotioPlus Development Guide

## 1. Git Workflow
- **Direct on Master**: Always work and commit directly on the `master` branch.
- **No Worktrees / No Feature Branches**: Do not create git worktrees or auxiliary branches unless explicitly requested by the user.

## 2. Testing Guidelines (STRICT)
- **Targeted Tests ONLY**: QuotioPlus contains 98+ test files. **NEVER run full test suites** (`xcodebuild test` without `-only-testing`). Running all tests is strictly prohibited as it is slow, wasteful, and unnecessary.
- **Scheme Name**: The scheme is `QuotioPlus` (do not use `Quotio`).
- **Command Syntax**:
  ```bash
  xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/<TestSuiteName> 2>&1 | tail -n 30
  ```
- **Examples by Domain**:
  - Routing / Optical Flow:
    `xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/CPARoutingTests -only-testing:QuotioPlusTests/RoutingFlowAnimationTests -only-testing:QuotioPlusTests/RoutingAccountPositionTests`
  - Account Management:
    `xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/AccountPageFusionTests -only-testing:QuotioPlusTests/AccountPageRenderingTests`
  - Analytics:
    `xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/AnalyticsNavigationTests -only-testing:QuotioPlusTests/AnalyticsScreenRenderingTests`
  - Settings:
    `xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/CPASettingsInteractionTests`

## 3. Architecture & UI Conventions
- **macOS / SwiftUI**: AppKit + SwiftUI macOS application using Swift Observation (`@Observable`, `@Environment`).
- **Design Tokens**: Use `QuotioTheme.Colors`, `QuotioTheme.Spacing`, and `QuotioTheme.CornerRadius` for visual consistency.
- **UI Design System**: Strictly adhere to the "Squircle Containers + Capsule Controls" (外方内圆) paradigm. No rectangular borders or `.stroke()` outlines on cards. Controls must use Capsule buttons (`QuotioCapsuleControls.swift`).
- **Localization**: UI text should support localization through `Quotio/Resources/Localizable.xcstrings`.
- **Architecture Standards**: Follow the 5-layer dependency and module blueprint in [docs/ARCHITECTURE_STANDARDS.md](docs/ARCHITECTURE_STANDARDS.md).

## 4. 源码目录与测试归属
- 架构标准规范见 [docs/ARCHITECTURE_STANDARDS.md](docs/ARCHITECTURE_STANDARDS.md)；完整目录规范与主要入口见 [docs/SOURCE_LAYOUT.md](docs/SOURCE_LAYOUT.md)；当前项目索引见 [docs/PROJECT.md](docs/PROJECT.md)。
- 应用装配、导航、菜单栏放在 `Quotio/App`；业务页面和专用服务放在 `BusinessModules`；跨业务能力与通用 UI 放在 `Shared`；外部 API、进程、安全和系统接入放在 `Infrastructure`；本地化与 Assets 放在 `Resources`。
- 客户端配置归 `AgentConfiguration`，会话／技能／存储归 `Workspace`；路由中心位于 `Dashboard/Routing`，公共 CPA 账本位于 `Shared/Analytics/CPA`。
- `QuotioTests` 同步业务归属，公共离线 HTTP 夹具在 `Support/Networking/LifecycleHTTPFixture.swift`。类名与 `QuotioPlusTests` Target 不变，继续只执行直接相关定向测试。
- 第一轮目录规整后，第二轮第一批已将 `Models.swift`、`MenuBarSettings.swift`、`AgentModels.swift` 的公共模型及纯规则按完整声明拆分；当前入口见目录规范及[实施记录](docs/features/public-model-split-2026-10-15.md)。
- `QuotaViewModel.swift` 等状态文件、Task、单例和 manager 所有权继续保持原样；不因模型归位改变配置键、历史兼容和运行时数据位置。新增或优化代码加入详细中文注释。
