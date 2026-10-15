# QuotioPlus 代码架构标准体系 (Code Architecture Standards)

> **生效日期**：2026-10-15  
> **适用范围**：`Quotio/` 与 `QuotioTests/` 源码库，所有后续功能开发、重构及 AI Agent 协同任务的硬性约束。

---

## 1. 架构目标与背景

QuotioPlus 基于单一 Xcode Target（`QuotioPlus`）进行开发，结合 macOS 15+、Swift 6 与 SwiftUI Observation 体系。为了杜绝在单 Target 下容易滋生的跨层耦合、上帝类臃肿、模块结构参差、以及 UI 视觉风格退化等问题，特制定本套标准代码结构体系，确保应用具备**高内聚、低耦合、职责单一、风格统一、可长期维护**的代码健康度。

---

## 2. 总体分层与单向依赖准则 (Layering Hierarchy)

代码仓库划分为 5 个核心层级，依赖关系严格遵循**单向向下流动**，严禁逆向或横向非法穿透：

```text
┌────────────────────────────────────────────────────────┐
│                      Quotio/App                        │
│            应用装配、生命周期、主窗口、菜单栏、全局环境          │
└───────────────────────────┬────────────────────────────┘
                            │ 依赖注入
                            ▼
┌────────────────────────────────────────────────────────┐
│                Quotio/BusinessModules                  │
│       业务模块 (Accounts, Dashboard, Settings, ...)     │
└───────────────────────────┬────────────────────────────┘
                            │ 仅依赖 Shared & Infrastructure
                            ▼
┌────────────────────────────────────────────────────────┐
│                     Quotio/Shared                      │
│        跨业务领域模型、通用协调器、Shared/UI 设计系统控件          │
└───────────────────────────┬────────────────────────────┘
                            │ 仅依赖 Infrastructure
                            ▼
┌────────────────────────────────────────────────────────┐
│                 Quotio/Infrastructure                  │
│       底座接入 (CPA 代理进程、终端执行、网络、持久化、系统)       │
└────────────────────────────────────────────────────────┘
```

### 分层规则白名单与黑名单：

1. **`App` (应用装配层)**：
   - **职责**：负责 App 生命周期、导航协调、环境对象注入、主菜单栏装配。
   - **依赖许可**：允许依赖 `BusinessModules`、`Shared`、`Infrastructure`。
2. **`BusinessModules` (业务模块层)**：
   - **职责**：独立侧边栏功能与垂直业务能力（如账号管理、仪表盘、用量统计、智能体客户端配置、工作区会话等）。
   - **依赖许可**：允许依赖 `Shared`、`Infrastructure`。
   - **【强制禁令】**：**业务模块之间禁止横向强依赖**。
     - *反例*：`BusinessModules/Dashboard` 禁止直接 `import` 或调用 `BusinessModules/Workspace` 的内部私有类/状态。
     - *正例*：如需跨业务共享数据，下沉至 `Shared` 领域模型或通过 `App/State` 协调器广播。
3. **`Shared` (公共领域与通用 UI 层)**：
   - **职责**：跨多个业务模块实际复用的纯领域模型（Domain Models）、全局偏好、公共格式化工具、以及统一设计系统基础组件（`Shared/UI`）。
   - **依赖许可**：只允许依赖 `Infrastructure` 与 `Resources`。
   - **【强制禁令】**：`Shared` **严禁反向依赖任何 `BusinessModules`**！一旦出现说明抽象泄露。
4. **`Infrastructure` (基础设施底座层)**：
   - **职责**：外部系统与底层能力接入，包括 CPA 本地代理进程管理、终端执行器（TerminalLauncher）、提供商底层 API 客户端、SQLite 持久化引擎、Keychain 及系统通知。
   - **依赖许可**：只允许依赖系统 SDK，与任何具体业务无关。
   - **【强制禁令】**：基础设施层必须是纯粹的技术实现，**严禁引入任何业务 ViewModel、界面 View 或业务状态**。
5. **`Resources` (资源层)**：
   - **职责**：存放静态资源（`Assets.xcassets`）、多语言本地化（`Localizable.xcstrings`）及开源许可证。

---

## 3. 标准业务模块骨架 (Standard Module Template)

为保证项目内每个功能模块的一致性，凡位于 `Quotio/BusinessModules/<FeatureName>` 的模块，统一遵循以下解剖学标准骨架：

```text
BusinessModules/<FeatureName>/
├── Views/          # 视图层：纯 SwiftUI View、页面局部组件、弹窗 Sheet
├── ViewModels/     # 交互状态层：@Observable class，负责页面交互驱动、任务生命周期
├── Models/         # 模块私有模型：仅该模块内部使用的 DTO、表单状态、私有展示快照
└── Services/       # 领域服务层：该模块专有的业务算法、数据格式适配器 (可选，无则不建)
```

### 规约细则：
- **Views 保持轻量**：View 仅负责声明式布局与简单 UI 动效，复杂状态流转、异步加载、格式化计算统一交由对应的 `ViewModel` 或 `Shared/Formatting` 处理。
- **ViewModels 单一职责**：一个页面视图对应一个主导的 `ViewModel`，ViewModel 内部使用 Swift 并发，标注 `@MainActor`，禁止在 View 内部直接编写长篇网络或文件读写代码。
- **命名规范**：
  - 顶级页面：`[Feature]Screen.swift`（如 `AgentSetupScreen.swift`、`ProvidersScreen.swift`）
  - 局部组件：`[Feature][Component]View.swift` 或 `[Feature][Component]Card.swift`
  - 弹窗面板：`[Feature][Action]Sheet.swift`
  - 交互状态：`[Feature]ViewModel.swift`

---

### 按业务职责组织与制定重构计划

后续目录调整和职责拆分以业务能力、共同变更原因、依赖方向及状态／任务所有权为依据。行数用于发现值得检查的位置；文件变短、文件数量增加或“一类型一文件”均不作为重构目标和验收标准。

- **先确定业务归属**：按账号、路由、客户端配置、用量统计、工作区等业务识别能力，再在业务内部按实际职责组织。侧边栏帮助定位业务入口，共享的领域能力仍按真实使用方归属，不机械复制导航层级。
- **保持内聚**：共同服务同一业务规则、需要一起修改且依赖紧密的类型可在同文件维护；职责清晰的长文件可以保留。此前按完整声明迁移是对应批次的安全实施方式，不要求后续所有类型继续单独成文件。
- **以具体收益决定优先级**：优先处理职责混杂、重复规则、跨业务强耦合以及难以独立验证的边界。仅减少行数、增加转发层或造成频繁跨文件跳转而没有维护收益的调整不列入实施批次。
- **计划写清边界**：每批说明业务能力与使用方、当前耦合证据、调整后的职责、状态与 Task 所有者、事务／会话约束及必要定向验证；文件清单作为边界确定后的结果。
- **抽取遵循实际复用**：业务专用模型、视图及服务保留在所属业务；只有已有跨业务使用方的稳定能力进入 Shared。提取时保留现有功能、配置、类型名称、私有 setter、状态和任务所有权；事务及会话规则按原流程完整保留。

---

## 4. 状态管理与上帝类治理军规 (State & Anti-God-Object)

针对历史上 `QuotaViewModel` 过度膨胀的问题，特订立以下状态管理红线：

1. **全面使用 Swift 6 Observation**：
   - 全面采用 `@Observable`，彻底杜绝已废弃的 Combine/`ObservableObject`/`@Published`/`@StateObject`。
   - 视图层按需监听，局部私有状态使用 `@State`，业务树向下传递使用 `@Environment`。
2. **`QuotaViewModel` 治理红线**：
   - **严禁向 `QuotaViewModel` 追加新的存储属性（Stored Properties）**。
   - 目前 `QuotaViewModel` 已进入只减不增的收敛期；新功能（如新提供商协议、新客户端配置、新遥测指标）必须独立建立各自模块专属的 Service 或 ViewModel，通过依赖注入形式协作。
3. **全局单例准入限制**：
   - 仅代表**宿主操作系统级唯一物理资源**的技术设施，允许暴露 `static let shared` 单例（例如管理单例进程的 `CLIProxyManager.shared`、管理系统终端拉起的 `TerminalLauncher.shared`、管理本地通知的 `NotificationManager.shared`）。
   - 业务视图状态与业务流程**一律禁止滥用静态单例**，统一通过应用级环境或父视图传递生命周期。
   - 所有单例类必须明确其线程隔离（如标注 `@MainActor` 或符合 `Sendable`）。

---

## 5. UI 设计系统与控件规范 (Design System & Capsule Controls)

全面落实 `design-system/quotio/MASTER.md` 的**“外方内圆”**规范，杜绝视觉风格参差：

### 1. 结构容器：超椭圆材质卡片（外方）
- **规范**：所有表面卡片一律使用 `.quotioCard(cornerRadius:padding:)` 或深色沉槽 `.quotioInsetCard()`。
- **【严禁项】**：
  - ❌ **严禁在卡片外层添加直角或显式描边线框（`.stroke` / `.strokeBorder`）**。卡片依靠材质原色与微环境光阴影建立空间层级。
  - ❌ **严禁随意使用纯色矩形背景填充**。

### 2. 交互件：胶囊与触控微钮（内圆）
- **规范**：
  - 主要操作胶囊：`.buttonStyle(.quotioPrimaryCapsule)`（高 36pt）或微胶囊 `.quotioPrimaryMicroCapsule(height:tint:)`（高 24~28pt）。
  - 次要/辅助胶囊：`.buttonStyle(.quotioSecondaryCapsule)` 或微胶囊 `.buttonStyle(.quotioMicroCapsule)`。
  - 独立行内微操作：统一使用 26pt 触控圆钮 `QuotioCircularIconButton`（内置 hover 高光与触控物理按压回弹）。
  - 分段控制器：统一使用胶囊分段控件 `QuotioCapsuleSegmentedControl`。
- **【严禁项】**：
  - ❌ **严禁在卡片内部使用系统默认带方框/灰底的直角按钮（`.buttonStyle(.bordered)`）**。
  - ❌ **严禁使用 4~8px 的直角小圆角按钮**。

### 3. 排版与数值显示
- **等宽数字**：所有动态变化的数值（Token 数量、请求延迟、价格、配额百分比、会话条数）必须声明 `.monospacedDigit()`，防止数字跳变导致 UI 颤抖。
- **图标标准**：统一使用 Apple SF Symbols，严禁使用 Emoji 代替功能图标。

### 4. 行内输入与提交/应用交互规范 (Inline Field & Apply Controls)
- **单字段行内提交**：输入框与“应用”操作必须在同一水平行内排列（`[Label] -------- [TextField] [应用胶囊按钮]`），严禁将应用按钮孤立放置在下一行开头。统一采用通用控件 `QuotioInlineApplyField` 与微胶囊按钮 `.buttonStyle(.quotioPrimaryMicroCapsule(height: 24))`。
- **基线感知与状态机**：必须跟踪持久化基线（`savedValue`），仅当发生实际变更且校验合法时启用按钮，无修改保持禁用；支持回车（`.onSubmit`）与点击同构触发；异步提交期间呈现微型加载指示器。
- **分组批量提交**：折叠面板或多字段组的批量应用按钮必须靠右对齐（`HStack { Spacer(); Button(...) }`），对比草稿与持久化基线（`hasChanges`）实施按需激活。

---

## 6. 异步并发与错误处理准则 (Concurrency & Error Handling)

1. **结构化并发与 MainActor 隔离**：
   - 涉及 UI 渲染与状态驱动的 ViewModel、Views 统一声明 `@MainActor`。
   - 纯后台运算（如数据统计、日志解析、文件归档）必须置于后台 Actor 或后台异步 Task 中执行，禁止阻塞主线程。
2. **严谨的异常处理**：
   - **禁止滥用静默吞噬**：除预知且无害的探测流程外，关键业务操作（如保存配置、启动代理、拉起终端、升级卸载）**严禁随意使用无声无息的 `try? await`**。
   - 关键失败必须记录日志或通过 ViewModel 向用户暴露友好的错误信息（Inline Error Banner、Toast 提示或统一 Alert 对话框）。

---

## 7. 测试驱动与变更验证守则 (Testing Contract)

1. **测试用例路径与生产代码 1:1 镜像**：
   - 新增业务文件 `Quotio/BusinessModules/Foo/ViewModels/FooViewModel.swift`，对应的测试用例必须放置在 `QuotioTests/BusinessModules/Foo/FooViewModelTests.swift`。
2. **坚守定向测试铁律（Targeted Tests ONLY）**：
   - **严禁执行全量测试**（`xcodebuild test` 不带参数）。全量运行包含 98+ 文件极其缓慢。
   - 必须使用定向测试参数 `-only-testing:QuotioPlusTests/<TestSuiteName>` 执行校验：
     ```bash
     xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/<TestSuiteName> 2>&1 | tail -n 30
     ```
3. **验证闭环**：
   - 任何涉及核心架构、数据流或 UI 改造的改动，必须确保关联的定向测试 100% 绿色通过，且无编译器 Warning / Error。
