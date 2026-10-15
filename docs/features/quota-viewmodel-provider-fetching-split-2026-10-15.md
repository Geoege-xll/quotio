# 提供商取数分文件维护：第二轮第五批

日期：2026-10-15。本批承接 [IDE 额度与账号变更拆分](quota-viewmodel-ide-account-split-2026-10-15.md)，仅将本地、CPA 和监控模式的提供商取数按完整原方法归类。当前入口见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 实施范围

主类从 2,452 行缩减到 1,784 行，新增以下三个同类型扩展。新增文件头和详细中文职责注释；原方法正文、属性标注、账号映射、并发、失败回退及会话校验保持不变。

| 文件（相对 `Quotio/Shared/Accounts/ViewModels`） | 行数／原方法数 | 维护内容 |
|---|---|---|
| `QuotaViewModel+LocalQuotaFetching.swift` | 244 行／12 个 | Claude Code、Codex CLI、GLM、ClinePass、Warp、Kiro、Antigravity、OpenAI／Codex、Copilot 的原读取与局部辅助 |
| `QuotaViewModel+CPAQuotaRefresh.swift` | 100 行／1 个 | CPA 接管判定、当前凭据目录、精确及旧身份映射、并发额度请求、逐账号套餐和错误提交 |
| `QuotaViewModel+MonitorQuotaRefresh.swift` | 392 行／3 个 | 监控批量取数、单提供商取数和原 `nonisolated static` Copilot 协调器合并方法 |

主类和全部扩展仍有 250 个原成员，各保留一份；本批迁移 16 个方法。前六个扩展及原 `OAuthState` 不变；没有增加 Service、状态容器、获取器实例、Task 持有者或编译 Target。

## 必需的跨文件访问白名单

共 26 项由 `private` 调整为应用 Target 内部可见，不增加 `public` API，不开放可变私有存储或 setter。

| 声明 | 调整原因及保留边界 |
|---|---|
| `antigravityFetcher`、`openAIFetcher`、`copilotFetcher`、`glmFetcher`、`warpFetcher`、`clinePassFetcher` | 本地与监控取数扩展复用原实例；`let`、`ObservationIgnored`、初始化位置与顺序不变 |
| `factoryDroidFetcher`、`devinFetcher`、`grokFetcher`、`openRouterFetcher`、`ampFetcher` | 监控取数扩展复用主类原只读引用；主类既有调用继续使用同一实例 |
| `claudeCodeFetcher`、`codexCLIFetcher` | CLI 与监控路径复用主类原实例，不新增凭据读取器 |
| `refreshClaudeCodeQuotasInternal`、`refreshGlmQuotasInternal`、`refreshClinePassQuotasInternal`、`refreshWarpQuotasInternal`、`refreshKiroQuotasInternal` | 方法移入本地取数扩展，原主类批量及单提供商调用点继续可用 |
| `refreshAntigravityQuotasInternal`、`refreshAntigravityQuotasWithoutDetect`、`refreshOpenAIQuotasInternal`、`refreshCodexQuotasInternal`、`refreshCopilotQuotasInternal` | 方法移入本地取数扩展，原刷新与账号切换调用关系不变 |
| `refreshCPAQuotas` | 主类单账号／单提供商刷新和本地取数扩展调用同一 CPA 接管入口 |
| `refreshMonitorProvider` | 主类的单提供商刷新继续调用完整原监控读取方法 |
| `clearRecoveredMonitorAccountIssues` | 实现仍在主类；监控批量取数继续复用原成功时间判定，不复制错误恢复逻辑 |

仅在本地扩展内部使用的 `refreshCodexCLIQuotasInternal` 与 `fetchLocalQuota` 继续保持 `private`。原 `refreshQuotasDirectly` 和 `refreshCopilotThroughCoordinator` 的可见性不变，后者继续保留 `nonisolated static` 及原 `@Sendable` 闭包。

## 状态与运行行为边界

- 84 个存储属性及其顺序继续留在主类，全部可变私有属性、Debug 钩子、四个 Task 句柄及七个 `private(set)` 保持原样。
- 主类仍提供刷新上下文、账号／模式／代理会话校验、槽位申请与释放、错误恢复判定及统一收尾；扩展操作同一实例，不保存另一份账号或额度快照。
- CPA 已接管但请求失败时仍返回接管结果，保留旧额度及失败提示，不改用本机其他账号的数据。客户端指针身份、运行状态、运行会话及取消检查保持原位置。
- CPA 仍优先精确凭据键，旧邮箱仅唯一匹配时迁移；相同邮箱的不同凭据保持隔离。额度与套餐使用同一账号身份，原 TaskGroup 分发与逐结果提交顺序不变。
- 本地取数保留原空结果清理、不同来源合并和失败处理。Kiro 的 CPA 凭据、直读凭据和未消费原键映射顺序不变；Antigravity 的套餐合并与活跃账号检测顺序不变。
- 监控取数保留原 `async let` 并发、凭据存在性与有效键过滤、失败旧值合并、Codex 凭据分组，以及 Copilot 在协调器合并后归一别名的规则。
- 原连续内存发布段不增加 `await`，发布后持久化、IDE 刷新、通知与菜单同步的校验及顺序不变。取数不消费 CPA 用量队列。
- 原类型名称、配置键、数据路径、历史兼容、布局和交互不变。代理生命周期、自动刷新和预热的后续批次未提前实施。

## 验证记录

以下结果均来自本批精确快照、构建日志和实际测试结果包。

- 起始快照：`/tmp/quotio-quota-viewmodel-fifth-before-20261015`，覆盖 650 个原文件。
- 原方法映射及访问白名单：`/tmp/quotio-quota-viewmodel-fifth-map-20261015.json`。
- 完整性验证：`/tmp/quotio-quota-viewmodel-fifth-verification-20261015.json`。逐成员比较全部 250 个原成员的完整声明和正文，仅归一白名单内的访问权限差异；全部一致。84 个存储属性、可变私有存储、四个 Task、七个私有 setter、前六个扩展及 104 个测试源码均保留。
- 独立只读审查：复审者直接读取精确基线，自行比较 16 个迁移声明及主类剩余代码，未依赖既有完整性验证报告。全部迁移声明一致；主类剩余代码忽略新增注释和空白后的 token SHA256 一致，26 项访问调整均有真实跨文件调用。MainActor／Observation、任务与状态所有权、CPA 接管及账号映射、监控并发和连续提交段均未发现本批引入的可行动问题。
- 应用构建：`QuotioPlus`／Debug／macOS，`CODE_SIGNING_ALLOWED=NO`，结果 **BUILD SUCCEEDED**，未出现编译器警告。日志 `/tmp/quotio-quota-viewmodel-fifth-build-20261015.log`。
- 定向回归：**35 项通过，0 失败，0 跳过**。仅通过 `-only-testing` 指定下表范围，没有运行全部测试，没有新增、删除或修改测试源码。

| 定向范围 | 数量 | 验证内容 |
|---|---:|---|
| `CPAQuotaParityTests` | 15 | CPA 精确认证索引、项目与端点回退、凭据隔离、模型额度和失败保留等底层契约 |
| `CopilotQuotaFetcherTests` | 13 | 账号身份、唯一／歧义别名、较新快照保留，以及迁移后的协调器合并方法 |
| `MenuBarAccountSyncTests` 的三个方法 | 3 | 原本地取数在跨模式等待、GLM 删除、Claude 同键重加后的迟到结果拒绝提交 |
| `RefreshInteractionTests` 的两个方法 | 2 | 原刷新槽位等待、后台合并和取消后不预约 |
| `MonitorUpstreamCompletionTests` 的两个方法 | 2 | 协调器过滤移除身份但保留失败旧值、共享等待者拒绝旧世代并允许新刷新 |

`MenuBarAccountSyncTests` 只执行 `testScopedWaitCannotRefreshNewModeAfterOldSlotReleases`、`testGLMDeletionRejectsLateResultAndPreservesOtherConnection`、`testAccountDeletionRejectsLateQuotaEvenWhenSameKeyIsReadded`。

`RefreshInteractionTests` 只执行 `testManualBatchWaitsForConflictStartedDuringDirectoryRead`、`testBackgroundBatchCoalescesAndCanceledManualBatchDoesNotAcquire`。

`MonitorUpstreamCompletionTests` 只执行 `testCoordinatorFiltersRemovedIdentityButKeepsFailedLiveAccount`、`testAllSharedWaitersRejectDeletedGenerationAndAllowNewRefresh`。

测试结果包 `/tmp/quotio-quota-viewmodel-fifth-targeted-20261015.xcresult`，日志为同名 `.log`。`xcresulttool` 汇总为 `Passed`，无失败、跳过或运行时警告。底层契约测试与完整方法一致性核对共同验证本次迁移；没有将这些用例表述为全部提供商的真实网络端到端验证。

现行维护索引同步更新，第三、四批历史报告保留原样。
