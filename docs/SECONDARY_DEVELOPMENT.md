# Quotio 二次开发与上游合并维护指南

本文用于说明本项目从哪里二开、当前改了什么，以及后续如何同步上游而保留本地功能。仓库状态核对日期：**2026-09-05**。文中命令是维护步骤，不代表已经执行远端配置、拉取、提交或合并。

**2026-09-08 首发整理**：QuotioPlus 使用 `1.0.0`（构建号 `73`）作为首个独立发行版，将首发前的 28 个本地开发提交及未提交源码合并成一个提交，父提交保留为上游基线 `13fd478c5b69f361d078e3b3bfc7ec041dde850d`。原作者历史继续保留，旧本地开发历史保存在 `codex/backup-before-v1.0.0-20260908` 备份分支；备份分支不随首发上传。以下第 2 节是二开初期的历史核对记录，首发内容以 [1.0.0 发行说明](releases/1.0.0.md) 为准。

## 1. 上游与参考项目分别是谁

| 角色 | 仓库 | 在本项目中的作用 | 更新方式 |
|---|---|---|---|
| Quotio 原项目／主要代码上游 | [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio) | 原生 macOS 应用主体，包含界面、代理管理、OAuth、配额和 CLI 配置 | 拉取到 `upstream`，通过 Git 三方合并整合应用代码 |
| 当前二开仓库 | [Geoege-xll/quotio](https://github.com/Geoege-xll/quotio) | 当前工作副本的 `origin`，用于保存和发布二开成果 | 在本仓库开发分支提交，经验证后推送到自己的仓库 |
| 运行时代理服务 | [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | Quotio 下载、启动和管理的独立代理二进制 | 升级代理版本，并验证管理 API 协议；不将其整个源码合并进 Swift 工程 |
| 统计与界面参考 | [sylearn/AIUsage](https://github.com/sylearn/AIUsage) | 仪表盘部分布局、用量统计、调用分析和客户端统计规则 | 独立参考 checkout，对比已采用提交与新提交，按模块移植 |
| CLI 配置参考 | [farion1231/cc-switch](https://github.com/farion1231/cc-switch) | Claude 模型映射、默认模型、显示名，以及 Codex 配置分层读取思路 | 独立参考 checkout，核对协议与行为，适配为 Swift 实现 |

**Quotio 才是整仓 Git 合并的主要上游。AIUsage、cc-switch 和 CLIProxyAPI 不应作为无共同历史的整仓分支合并进来。** 当前没有把这些参考仓库作为 Git submodule 或 vendored 源码目录管理；它们的更新不会随 `git pull origin` 自动进入 Quotio。

证据入口：原项目地址见根目录 `README.md`、`README.zh.md`；运行时代理仓库常量见 `Quotio/Services/Proxy/CLIProxyManager.swift`；AIUsage 移植记录见[许可证与来源说明](licenses/AIUsage-attribution.md)。`origin` 地址来自当前本地 Git 配置；本文不依赖 GitHub 页面是否显示 Fork 标识。

## 2. 当前基线：哪些事实已经确定

| 项目 | 2026-09-05 核对结果 |
|---|---|
| 当前分支 | `master`，跟踪 `origin/master` |
| 已配置远端 | 只有 `origin = https://github.com/Geoege-xll/quotio.git`，尚未配置 `upstream` |
| 当前已提交 HEAD | `13fd478c5b69f361d078e3b3bfc7ec041dde850d` |
| HEAD 提交说明 | `chore: bump version to 0.31.0 [skip ci]` |
| HEAD 提交时间 | 2026-09-02 19:03:21 UTC |
| 二开状态 | 大量已修改文件和新增文件仍在工作区，尚未形成覆盖本轮成果的二开提交 |
| AIUsage 参考提交 | `bdb83bbe077879855c03e656cbc2fe5890bd27e9` |
| cc-switch 参考提交 | `db41d701879592b8eca938cbe5c5ac28dd732b9f` |
| 本轮 CPA 兼容问题基线 | 7.2.151 的管理用量 API 变化；这是本轮验证版本，不是永久锁定版本 |

这里的 Quotio HEAD 是**本地当前已提交基线**，不是“刚刚拉取并确认的最新上游”。本次文档编写没有执行 `git fetch`，也没有创建基线标签。当前 `HEAD` 上没有指向它的本地标签，不能只凭提交说明就假定本地存在 `v0.31.0` 标签。

开发期间的参考 checkout 在 `/tmp/quotio-aiusage-reference`、`/tmp/quotio-cc-switch-reference`。它们属于临时目录，可能被系统清理；可复现依据应是**仓库 URL + 完整提交 SHA**，不能依赖 `/tmp` 长期存在。

## 3. 本项目是怎样二开的

### 3.1 保留 Quotio 原生架构

本项目继续使用 Swift 6、SwiftUI、Observation 和现有 MVVM 分工，最低支持 macOS 14：

- `Quotio/Views/` 渲染状态、响应交互。
- `Quotio/ViewModels/` 协调页面状态与异步流程。
- `Quotio/Services/` 负责配置读写、网络、扫描、进程和持久化。
- `Quotio/Models/` 定义模型、协议数据和纯统计规则。
- `QuotioTests/` 覆盖配置、解析、去重、时序、持久化与筛选回归。
- `Quotio/Localizable.xcstrings` 统一维护 `en`、`fr`、`vi`、`zh-Hans` 四种语言。

新增统计能力尽量放在独立模块中，再通过 `QuotioApp`、`OperatingMode`、`QuotaViewModel` 等现有入口接入。原生工程由 `Quotio.xcodeproj` 管理，根目录不是 Swift Package；使用 Xcode 的 `Quotio` scheme 构建、测试。

### 3.2 二开功能及冲突热点

下表用于上游合并时逐项核对，实际差异以当前 Git diff 和测试为准。

| 二开范围 | 主要文件／目录 | 合并后必须保留的行为 |
|---|---|---|
| Claude Code 模型映射与默认模型 | `Models/AgentModels.swift`、`Services/AgentConfigurationService.swift`、`ViewModels/AgentSetupViewModel.swift`、`Views/Components/ClaudeModelMappingView.swift`、`AgentDefaultModelPicker.swift`、`AgentConfigSheet.swift` | 模型角色 → 实际请求模型 → 可编辑显示名；默认启动模型独立配置；显示名不能覆盖实际模型 ID |
| Codex CLI 配置 | `Services/AgentConfigurationService.swift`、`Models/AgentModels.swift`、`ViewModels/AgentSetupViewModel.swift` | 顶层模型和 provider 的读取不能被 profiles／MCP 子表混淆；保留用户自有配置内容 |
| 备份管理 | `Services/AgentConfigurationService.swift`、`Views/Components/AgentBackupSection.swift` | 备份不重名覆盖；删除目标经过验证，不能误删配置或越界路径 |
| Antigravity 配额 | `Services/Antigravity/AntigravityQuotaFetcher.swift`、`AntigravityQuotaParser.swift`、`Models/AntigravityQuotaPresentation.swift`、`Services/StatusBarMenuBuilder.swift`、`Views/Screens/QuotaScreen.swift` | 剩余／已用方向正确；不同额度池不随意平均；窗口和菜单栏使用一致的额度、周期和重置时间 |
| 仪表盘与提供商布局 | `Views/Screens/DashboardScreen.swift`、`ProvidersScreen.swift`、`Views/Components/ProxyRuntimeCard.swift`、`DashboardUsageSummary.swift`、`ProviderConnectionSummary.swift`、`AvailableModelsSection.swift` | 顶部 CPA 运行卡、弱化摘要、提供商摘要迁移；模型完整展示，展开入口在右下，无搜索 |
| 首次启动模型目录 | `Services/DashboardModelCatalogLoader.swift`、`ViewModels/QuotaViewModel.swift`、`Models/ModelCatalog.swift` | 同一次加载先取得当前客户端 API key，再请求本机模型目录；启动后自动加载，旧会话响应不能覆盖新会话 |
| CPA 仪表盘用量 | `Models/UsageStatistics/`、`Services/UsageStatistics/`、`Services/ManagementAPIClient.swift`、`ViewModels/QuotaViewModel.swift` | 新队列唯一消费者，跟随应用／代理生命周期；兼容旧累计接口，真实零与未知分开 |
| 客户端 Token 用量 | `Models/ClientUsage/`、`Services/ClientUsage/`、`ViewModels/ClientUsageViewModel.swift`、`Views/Screens/UsageStatisticsScreen.swift`、`Views/Components/UsageStatistics/` | 综合／Claude Code／Codex／OpenCode；只统计 Token；Codex 检查点重算、消息去重，客户端数据不与 CPA 双计 |
| 调用分析 | `Models/CallAnalytics/`、`Services/CallAnalytics/`、`ViewModels/CallAnalyticsViewModel.swift`、`Views/Screens/CallAnalyticsScreen.swift`、`Views/Components/CallAnalytics/` | 来源与时间筛选、工具／MCP／技能分析、代理按会话计数；纯文本代理计入，未知日期不编造 |
| 共用外观与导航 | `Views/Components/Analytics/`、`QuotioTheme.swift`、`SidebarSquircleIcon.swift`、`QuotioApp.swift`、`Models/OperatingMode.swift` | 保留当前主题与导航；客户端统计在监控模式也可用 |
| 工程与本地化 | `Quotio.xcodeproj/project.pbxproj`、`Quotio/Localizable.xcstrings` | 保留新增资源与实际构建设置；按文案键和语言合并，避免整文件覆盖 |

统计模块的详细计算与参考源码对照见[用量统计与调用分析](features/usage-statistics-and-call-analytics.md)。视图和统计规则并非对参考项目原文件的无差别覆盖：AIUsage 使用其自己的 Claude Gateway 归档，本项目使用 Claude Code 本地记录；参考项目的 Codex 代理／非代理轨道尚未在本项目实现。

2026-09-08 客户端统计已改为 SQL 日汇总展示、按变化文件与会话处理，不再让全历史账本和检查点常驻页面。新增「诊断与维护 → 维护入口 → 存储与数据」，区分缓存释放、数据库空间回收和按模块删除统计；合并时必须保留应用级维护屏障、CPA 已消费批次落盘以及多模块失败后缓存失效。详见 [统计内存优化与存储维护](features/analytics-memory-optimization-and-storage-maintenance-2026-09-08.md)。

### 3.3 合并时的关键约束

- CPA 管理请求直接连接本机 `127.0.0.1`，模型请求使用客户端 key；不能把管理 key 回退为客户端 key。
- 代理启停保留 Quotio 自进程保护、运行会话标识和取消检查。
- 版本化代理存储保留 `current` 指向的活动版本。
- 写 CLI 配置时保留用户自有键、创建不冲突备份，验证不可信文件和链接目标。
- 账本只保存必要统计元数据，使用私有原子写入；不提交真实账号、Token、OAuth 文件或本地配置。
- CPA 模型请求量、客户端 Token 量、工具调用量、代理会话次数是不同口径，不能为追求数字一致而相加或相互替代。
- 调用分析 Schema 7 兼容读取 Schema 6。客户端账本与 CPA 账本也有各自版本，合并时先检查解码和迁移，不直接删历史文件解决兼容问题。

## 4. 第一次同步前：先把二开成果保存为提交

**当前工作区尚未提交，不能直接进入合并步骤。** 分支、标签或 `git bundle` 只能保存已提交的对象，不能代替保存未跟踪的新源文件。

先查看全部状态，包括新增文件：

```bash
# 从仓库根目录执行；这些命令不修改工作区。
git status --short
git diff --stat
git diff --name-status
git ls-files --others --exclude-standard
git diff --cached --stat
```

建议先建立长期二开分支 `fork/main`，然后按功能形成提交。新分支会保留工作区修改；如果该分支已经存在，不要重复创建。

```bash
# 仅首次创建二开分支时执行。
git switch -c fork/main

# 对共享的已跟踪文件按补丁选择；新增文件需逐路径显式暂存。
git add -p

# 每次提交前检查暂存区，再按实际功能填写提交说明。
git diff --cached --check
git diff --cached
```

新增路径应按上一节功能表分别 `git add <实际路径>`，再 `git commit`。不建议用 `git add .` 把不同任务、构建产物和本地配置一次性带入。当前还有用户删除的 `AGENTS.md`、`.codex/environments/environment.toml` 等工作区变化，要按实际维护意图处理，不能在合并时自动恢复，也不能假定这些删除都是二开功能所需。

将**全部需要保留的二开源码、新文件、文档和有意删除**保存后，确认 `git status --porcelain` 为空，再建立二开基线标签。标签使用 `fork-baseline-*`，避免误触项目 `v*` 发布流程；标签日期及提交信息应填实际保存时间。

## 5. Quotio 主要上游的标准同步流程

推荐使用 **fetch → 独立 worktree → 三方 merge → 验证 → 合入二开分支**。这能保留共同祖先和合并记录，后续上游更新仍能识别已经吸收的代码。对长期共享二开分支，不常规执行 rebase 重写历史。

### 5.1 配置并获取上游

```bash
# 首次配置。若已有 upstream，先检查地址，不重复添加或盲目覆盖。
git remote -v
git remote add upstream https://github.com/nguyenphutrong/quotio.git

# 获取上游提交但不修改当前源码；不自动导入所有上游发布标签。
git fetch --prune --no-tags upstream

# 查看上游默认分支；本次核对为 master，未来以远端为准。
git remote show upstream
```

保持 `origin` 指向自己的二开仓库，不用原项目覆盖 `origin`。普通 `git pull` 当前只会更新 `origin/master`，不会自动同步 `nguyenphutrong/quotio`。

### 5.2 建立可复核的合并分支

下列示例假设已创建并保存好 `fork/main`，且工作区干净。日期命名只用于可读性；同一天重复执行应加后缀避免重名。变量和 worktree 路径在同一终端会话中使用。

```bash
# 工作区必须先保存完毕。若有输出，先处理再继续。
git status --porcelain

# 在二开已提交基线上创建独立合并工作区。
sync_stamp=$(date +%Y%m%d-%H%M%S)
sync_branch="sync/quotio-${sync_stamp}"
sync_dir="../quotio-upstream-${sync_stamp}"
git worktree add -b "$sync_branch" "$sync_dir" fork/main
cd "$sync_dir"

# 记录本次输入：二开提交、上游目标提交和共同祖先。
fork_before=$(git rev-parse HEAD)
upstream_target=$(git rev-parse upstream/master)
sync_base=$(git merge-base HEAD "$upstream_target")
git log --oneline --left-right HEAD..."$upstream_target"
git diff --stat "$sync_base" "$upstream_target"
git diff --name-only "$sync_base" "$upstream_target"

# 固定到刚记录的目标SHA，不让后续fetch改变本次目标；先不自动提交。
git merge --no-ff --no-commit "$upstream_target"
```

如果 `git merge-base` 找不到共同祖先，应先检查远端 URL、分支和是否为浅克隆，不能通过 `--allow-unrelated-histories` 强行拼接。若上游已包含在当前分支中，Git 会报告已是最新，此时不需要制造空合并提交。

### 5.3 解决冲突：按行为三方比对

```bash
# 查看尚未解决的冲突及双方改动。
git status --short
git diff --name-only --diff-filter=U
git diff
```

在**本流程的 merge 操作中**，`ours` 是二开分支，`theirs` 是上游。不能对整仓执行“全部保留 ours／theirs”：前者会丢掉上游修复，后者会覆盖二开功能。以共同祖先、当前二开和上游三份文件分别判断每个改动目的，解决后显式 `git add <已解决路径>`。

优先审查 `QuotaViewModel`、`AgentConfigurationService`、`QuotioApp`、`ManagementAPIClient`、`CLIProxyManager`、`Localizable.xcstrings`、`project.pbxproj`，因为它们既是上游活跃入口，也承载多项二开功能。

新增模块发生“双方都新增”冲突时，也需要整合实现和对应测试，不能只因为文件位于二开目录就保留整份本地文件。上游若已经修复相同问题，应优先复用上游实现，移除被替代的本地重复实现，但保留能保护二开需求的回归测试。

### 5.4 验证、提交与合入

先确认没有未解冲突，再运行第7节的构建、测试与人工验收。检查本次合并相对原二开基线的变化：

```bash
# 这些检查在合并worktree中执行。
git diff --name-only --diff-filter=U
git diff --check
git diff --cached --check
git diff --cached --stat "$fork_before"

# 确认验证成功后，完成合并提交；提交信息记录实际上游SHA。
git commit -m "chore(upstream): merge Quotio ${upstream_target}"
```

记录每次同步的上游完整 SHA、原二开 SHA、合并提交、重要冲突决策、验证命令和结果。可在 `docs/upstream-sync/` 按日期保存记录；不要只写“更新到最新版”。提交生成后可记录其 SHA 到后续维护记录或 PR，避免要求提交正文引用尚未生成的自身 SHA。

回到原工作区，确认它仍然干净，再合入已验证分支：

```bash
# 以下在原仓库工作区执行；sync_branch 取前面实际创建的分支名。
git switch fork/main
git merge --ff-only "$sync_branch"
```

如果 `--ff-only` 失败，说明开发期间 `fork/main` 又向前推进。返回同步 worktree，把新的 `fork/main` 合入、重新检查受影响范围，再尝试快进；不要强推覆盖并行开发成果。推送和发布按项目正常交付流程进行，本指南不自动推送。

合并尚未提交、需要放弃时，可在独立同步 worktree 中执行 `git merge --abort`，回到合并前提交。已发布的合并需要回退时采用经过审查的 revert 提交，不用 `reset --hard` 改写共享历史；回退合并会影响将来的再次合并，需要同时记录原因和恢复策略。

## 6. AIUsage、cc-switch、CPA 与依赖怎样更新

### 6.1 参考项目使用独立 checkout

建议放到仓库外的长期目录，例如 `~/Developer/quotio-references/`，不放入 Quotio 的同步源码组。以下仅用于第一次建立参考库：

```bash
mkdir -p "$HOME/Developer/quotio-references"
git clone https://github.com/sylearn/AIUsage.git "$HOME/Developer/quotio-references/AIUsage"
git clone https://github.com/farion1231/cc-switch.git "$HOME/Developer/quotio-references/cc-switch"
```

每次更新先获取新提交，再从**已采用的 SHA**比较变化，不直接将参考工作区切到最新版后整文件复制：

```bash
# AIUsage 示例：target SHA由本次选择的上游分支/版本确定。
cd "$HOME/Developer/quotio-references/AIUsage"
git fetch --prune origin
git remote show origin

# 替换下方 NEW_COMMIT 为核对后的完整SHA后执行。
git diff --stat bdb83bbe077879855c03e656cbc2fe5890bd27e9 NEW_COMMIT
git log --oneline bdb83bbe077879855c03e656cbc2fe5890bd27e9..NEW_COMMIT
```

AIUsage 优先核对 `StatsDataAdapter`、`ProxyStatsView*`、`DashboardView+Heatmap`、`CallAnalytics*` 及三个客户端 Provider。先确认新数据规则是否适用于本项目：它自己的 Gateway 归档、provider 排除和代理轨道不能原样套在 Quotio 的独立客户端账本上。移植后更新[源码对照与边界](features/usage-statistics-and-call-analytics.md)以及[来源说明](licenses/AIUsage-attribution.md)，记录具体采用的提交和模块。

cc-switch 从 `db41d701879592b8eca938cbe5c5ac28dd732b9f` 对比新提交，优先看 `src/components/providers/forms/ClaudeFormFields.tsx`、`forms/hooks/useModelState.ts` 以及 `src-tauri/src/` 的配置读写。它使用的前端／Rust实现需转换为现有 Swift 服务和模型，保留本项目私有写入、备份及用户配置保护。配置字段最终还要结合客户端官方文档和实际版本验证，不能把参考项目新增字段直接当作全部版本通用契约。

### 6.2 CPA 独立升级

当前 Quotio 通过 `CLIProxyManager` 从 `router-for-me/CLIProxyAPI` 发布页获取二进制，不在应用工程中编译 CPA 源码。更新时记录实际 CPA 版本，并验证：

1. 版本化存储和活动 `current` 链接可用，升级／回退不会删除活动版本。
2. 代理启动、停止、健康检查、授权和模型目录正常。
3. 管理 API 的路径、鉴权、字段和错误语义；尤其是 `/usage-queue` 的消费式读取与旧 `/usage` 兼容。
4. 队列读取不能套用可能重复消费的普通自动重试；同一时段只能由现有单消费者负责。
5. 请求数／Token 的停止、重启、失败和持久化状态正确。

### 6.3 SwiftPM 依赖

当前锁定文件是 `Quotio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`，已锁定 Sparkle 2.8.1、PostHog 3.64.1。上游更新依赖时连同实际版本约束、锁定文件和 API 变化一起检查，不能为了清除冲突直接删锁定文件并无条件升级全部依赖。

## 7. 每次同步后的验证

使用真实 Xcode 工程，不使用根目录 `swift build` 或 `swift test`：

```bash
# 构建。
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' build

# 串行完整单元测试，便于避免并行调度对依赖状态测试的干扰。
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO test

# 构建并启动新应用；该脚本会停止当前正在运行的Quotio实例。
./scripts/build_and_run.sh --verify
```

重点关注的回归类包括 `ClaudeCodeConfigTests`、`CodexModelConfigTests`、`AgentBackupDeletionTests`、`AntigravityQuotaTests`、`DashboardModelCatalogLoaderTests`、`ModelCatalogTests`、`UsageStatisticsTests`、`UsageStatisticsStoreTests`、`ClientUsageTests`、`CodexClientUsageTests`、`OpenCodeClientUsageTests`、`CallAnalyticsMigrationTests`、`CallAnalyticsReplicaTests`。

2026-09-05 统计迁移完成时，记录过456项通过的串行回归；该次仅排除了两项已知语言环境基线问题：`AmpQuotaFetcherTests.testParserMapsSubscriptionOtherUsageAndRenewalSuffix`、`MonitorRuntimeTests.testCountMetricUnitsUseEnglishSingularAndPluralForms`。这是历史证据，**不代表未来同步可永久跳过它们，也不代表之后新增改动自动获得验证**。未来先运行完整测试，区分本次回归与已复现的环境问题，记录实际结果。

当前用户负责界面人工验收。每次涉及 UI 的同步至少检查：启动 CPA 自动加载模型、模型展开入口、Claude 映射和默认项、Antigravity 窗口／菜单栏一致性、统计来源／日期筛选、模型明细、调用分析以及亮暗色和窄窗口。用户表示“会检查”只代表验收分工，不等于已经验收通过。

## 8. 发布二开版本前必须处理的上游关联

2026-09-08 已将自有更新与上游维护分离：`Config/Updates.xcconfig` 配置自有仓库 `Geoege-xll/quotio`；Bundle、Sparkle、Atom 预检查和打包下载地址共用该配置。原项目 `nguyenphutrong/quotio` 的发行检查位于“诊断与维护 → 维护入口 → 检查上游更新”，只提供源码同步参考。

Bundle ID 已改为 `com.app.george.quotioplus`。首次启动按原迁移机制补齐旧 `app.bytrong.quotio` 的设置和凭据来源，保留新身份下已有设置，排除旧 Sparkle 更新状态。统计、代理和其他 Application Support 数据目录保持连续。

启用自动安装更新前，需要配置本项目的 `SPARKLE_PUBLIC_ED_KEY` 和配套 `SPARKLE_PRIVATE_KEY` 并发布 appcast。两者均未配置时允许发行手动更新版本，通过自有发布页下载安装，不初始化自动安装器；只配置一项会明确失败。打包脚本会用包内公钥验证更新归档签名，拒绝不配对的配置。Developer ID 签名和 Apple 公证也按凭据是否完整区分发行模式，并在发布页注明实际状态。详见 [发行流程](../RELEASE.md) 和 [自有更新与身份调整](features/own-updates-and-app-identity-2026-09-08.md)。

首发已统一以下关联：

- `.github/workflows/release.yml` 仅在显式配置本仓库所有者的 `HOMEBREW_TAP_REPOSITORY` 后才通知自有 tap；不会向上游发送发行通知。
- 根 README 的下载、克隆和反馈链接均指向 `Geoege-xll/quotio`，明确二开来源并感谢原作者；上游 Homebrew tap 仅作为原版安装渠道说明。
- `scripts/build_and_run.sh` 默认身份已统一为 `com.app.george.quotioplus`，启动和日志读取会优先使用构建产物中的实际 Bundle ID；开发构建覆盖身份时也可正确定位应用。
- 当前发布工作流由 `v*` 标签和手动操作触发，日常同步基线使用其它标签前缀。

首发版本号、发行说明和源码在同一提交中保存。工作流校验标签所指提交与版本配置，构建过程不追加版本提交；后续同步仍采用正常合并及快进推送，避免改写已发布历史。

## 9. 许可证与长期记录

根目录 Quotio 许可证为 MIT，保留原作者声明。AIUsage 改编模块保留 Apache-2.0 来源头、修改说明和随应用打包的许可证：`Quotio/Resources/ThirdPartyLicenses/AIUsage-LICENSE.txt`。cc-switch 参考仓库当前许可证为 MIT；后续直接移植代码时，应同时记录具体文件、提交和相应版权声明。

每轮维护至少保存：

- 二开分支、同步前 SHA、上游目标 SHA、合并或移植提交。
- 采用了哪些上游模块，哪些差异继续保留，以及原因。
- 管理 API、CLI 配置字段或本地账本版本是否变化。
- 实际测试／构建命令、结果、环境和人工验收结论。
- 参考项目来源与许可证变化，二开发布地址是否仍正确。

维护文档入口为本文；功能计算规则归入 `docs/features/`，上游来源归入 `docs/licenses/`，实际同步记录建议归入 `docs/upstream-sync/`。不要把“当前临时目录还在”或“上次聊天提到过”作为后续合并的唯一依据。
