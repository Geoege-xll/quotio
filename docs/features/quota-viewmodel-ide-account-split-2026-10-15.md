# IDE 额度与账号变更分文件维护：第二轮第四批

日期：2026-10-15。本批承接[QuotaViewModel 第三批拆分](quota-viewmodel-split-2026-10-15.md)，完整迁移 IDE 额度与账号变更方法，不调整状态、任务或服务所有权。当前入口见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 实施范围

主类从 2,996 行缩减到 2,452 行，新增以下两个同类型扩展；方法正文、属性、调用顺序和条件编译保持原样，仅加入中文职责说明并调整必要跨文件可见性。

| 文件（相对 `Quotio/Shared/Accounts/ViewModels`） | 行数／方法数 | 维护内容 |
|---|---|---|
| `QuotaViewModel+IDEQuotas.swift` | 272 行／9 个原方法 | Cursor／Trae 读取、原 `nonisolated static` 合并、已有账号刷新及私有单提供商／取数辅助、用户同意扫描、原键保存恢复 |
| `QuotaViewModel+AccountMutations.swift` | 311 行／13 个原方法 | 监控禁用删除、IDE 派生删除、额度清理、OpenRouter／Amp／FactoryDroid 保存及私有辅助、CPA 删除提交与请求、自定义连接变更及私有清理、禁用开关 |

跨主类及所有扩展的原 250 个成员保持唯一，22 个原方法本批移入扩展。第三批四个扩展与 `OAuthState` 源码不变；仍是单应用 Target，不建立新的 Service、状态容器、Task 或真正的编译依赖隔离。

## 必需的跨文件访问白名单

以下 20 项从 `private` 调整为应用 Target 内部可见。四个实例依赖与静态键仍为原只读声明；不新增 `public` API，不开放可变私有存储或 setter。

| 声明 | 跨文件需要与保留边界 |
|---|---|
| `monitorCoordinator` | 账号变更扩展复用原监控快照与账号协调器，实例仍由主类持有 |
| `cursorFetcher` | IDE 扩展调用原 Cursor 获取器，不新建实例 |
| `traeFetcher` | IDE 扩展调用原 Trae 获取器，不新建实例 |
| `ideScanSettings` | IDE 扩展复用原扫描状态和设置单例，不建立第二份偏好或扫描结果 |
| `ideQuotasKey` | IDE 保存恢复复用原静态持久化键，键值不变 |
| `refreshContext` | 两个扩展固定原刷新上下文，生成逻辑留在主类 |
| `canCommit` | IDE 挂起后继续使用主类原提交校验 |
| `canApplyMutation` | 账号操作挂起后继续使用原变更上下文校验 |
| `loadDisabledAuthFiles` | 账号变更扩展读取原禁用集合 |
| `saveDisabledAuthFiles` | 账号变更扩展通过原入口保存禁用偏好 |
| `beginBatchRefresh` | IDE 刷新复用主类原批次槽位申请与并发合并 |
| `endBatchRefresh` | IDE 刷新由原入口释放槽位，集合仍由主类持有 |
| `removeDisabledMonitorQuotas` | IDE 扫描结束后复用原禁用额度清理，私有占位账号辅助仍留在主类 |
| `discoverMonitorAccounts` | 扩展收尾时复用原账号发现和目录合并 |
| `finishScopedRefresh` | 账号变更调用主类原统一刷新收尾，不复制提交逻辑 |
| `refreshCursorQuotasInternal` | 原 Cursor 刷新移入 IDE 扩展，主类既有调用点继续可用 |
| `refreshTraeQuotasInternal` | 原 Trae 刷新移入 IDE 扩展，主类既有调用点继续可用 |
| `savePersistedIDEQuotas` | 主类及账号变更扩展继续调用 IDE 扩展原保存逻辑 |
| `loadPersistedIDEQuotas` | 主类初始化继续调用 IDE 扩展原恢复逻辑 |
| `removeQuotaEntry` | 原额度清理移入账号变更扩展，其他原调用点继续复用 |

## 状态、会话与删除边界

- 84 个存储属性及其顺序继续留在主类；所有可变私有属性和 Debug 测试钩子保持原样。四个 Task 句柄与七个 `private(set)` 均不改变。
- 上下文生成、提交与变更校验、刷新槽位、统一收尾保留主类实现；扩展复用原实例，不复制刷新集合或账号状态。
- IDE 账号仍需用户显式同意扫描后导入。日常刷新只合并当前已导入账号，未读到的新值保留旧值，不自动导入未扫描账号。
- 异步操作继续检查原账号世代、模式、管理客户端及代理运行会话；来源失效或账号已删除时不提交旧结果。同步发布与持久化之间不增加挂起点。
- IDE 删除继续清理内存额度、原 `persisted.ideQuotas` 镜像、监控快照、禁用状态及菜单固定项，保留跨模式删除后不复活逻辑。
- CPA 和监控账号操作保留原身份范围、逐账号并发与失败处理；自定义连接和密钥账号保存仍经原服务，布局、交互、配置与存储格式不变。
- 104 个原测试文件不改动，不运行全量测试。前三批历史报告和旧验证事实保持原样。

## 验证记录

以下结果来自本批精确快照、实际源码、构建日志及定向测试结果包，没有沿用前批结果。

- 起始快照：`/tmp/quotio-quota-viewmodel-fourth-before-20261015`。
- 原方法映射及访问白名单：`/tmp/quotio-quota-viewmodel-fourth-map-20261015.json`。
- 完整性验证：`/tmp/quotio-quota-viewmodel-fourth-verification-20261015.json`。全部 250 个原成员正文与属性保持一致；84 个存储属性、可变私有属性、四个 Task 句柄、七个私有 setter、前批源码及 104 个测试文件保留。
- 当前维护索引和本批新增链接已同步；文档链接只检查本轮新增或调整目标。
- 独立只读复审：直接对照本批基线，核对完整方法、访问白名单、MainActor／Observation、IDE 刷新槽位和挂起后写回、账号世代与 CPA client／模式／运行会话检查；未发现本轮引入的可行动问题。
- 应用构建：`QuotioPlus` / Debug / macOS，`CODE_SIGNING_ALLOWED=NO`，结果 **BUILD SUCCEEDED**；日志 `/tmp/quotio-quota-viewmodel-fourth-build-20261015.log`。
- 相关定向验证：**41 项通过，0 失败，0 跳过**。使用 `-only-testing` 指定下列三个测试类和九个方法，没有运行全量测试，也没有新增或删除测试。

| 定向范围 | 数量 | 主要覆盖 |
|---|---:|---|
| `IDEQuotaRefreshTests` | 5 | 已导入账号合并、未扫描不自动导入、删除不复活、缺失新值保留旧值 |
| `IDEQuotaRefreshReentrancyTests` | 5 | 请求挂起时删除账号／提供商、取消后不写回、刷新槽位互斥、空目录不读取 |
| `MenuBarAccountSyncTests` | 22 | 凭据身份、模式目录、固定项、自定义连接变更、CPA 删除、迟到目录和额度拒绝提交 |
| `MonitorUpstreamCompletionTests` 的五个指定方法 | 5 | IDE 删除重加、模式往返、发现挂起时删除、孤立套餐与错误清理、并行账号变更 |
| `MonitorRuntimeTests` 的四个指定方法 | 4 | 跨模式删除后的快照恢复、保留无关账号、身份匹配删除、禁用标记清理 |

`MonitorUpstreamCompletionTests` 只执行 `testIDEDeletionAndReaddRejectsOldInFlightResult`、`testModeRoundTripInvalidatesInFlightRefresh`、`testDiscoverySuspendedDuringDeletionCannotRestoreAccountList`、`testDisableClearsOrphanSubscriptionAndIssueWithoutQuotaEntry`、`testIndependentAccountMutationsBothPersistButSameAccountKeepsLatest`。

`MonitorRuntimeTests` 只执行 `testDeletingIDEAccountOutsideMonitorModeSurvivesMonitorBootstrap`、`testForgettingIDEAccountLeavesUnrelatedSnapshotEntriesIntact`、`testSnapshotRemovalMatchesMonitorAccountIdentity`、`testForgettingIDEAccountClearsItsMonitorDisabledFlag`，没有执行该类其余无关方法。

测试结果包 `/tmp/quotio-quota-viewmodel-fourth-targeted-20261015.xcresult`，日志为同名 `.log`；`xcresulttool` 汇总为 `Passed`，无失败、跳过或运行时警告。
