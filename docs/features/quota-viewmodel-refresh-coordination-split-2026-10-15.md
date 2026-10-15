# 刷新协调与目录读取分文件维护：第二轮第六批

日期：2026-10-15。本批承接[提供商取数拆分](quota-viewmodel-provider-fetching-split-2026-10-15.md)，将目录读取、手动操作、批量及单提供商／单账号刷新、账号发现和统一收尾归位。维护入口见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 实施范围

主类从 1,784 行缩减到 1,376 行，新增 `Shared/Accounts/ViewModels/QuotaViewModel+QuotaRefresh.swift`（454 行）。扩展仍属于原 `QuotaViewModel`，不增加 Service、状态容器、获取器实例、Task 持有者或编译 Target。

| 方法组 | 原方法 | 保留边界 |
|---|---|---|
| 目录读取 | `loadDirectAuthFiles`、`refreshAuthDirectorySnapshot`、`refreshAuthDirectoryForTesting`、`refreshData` | 原本地扫描、CPA 目录去重、账号／模式／客户端／运行会话校验、目录后 API Key 串行读取、目录变化时间戳及错误处理不变 |
| 手动操作 | `manualRefresh` | 继续使用主类唯一的 `ManualRefreshState`，重复点击合并，逐步骤来源校验和原刷新计划不变 |
| 批量刷新 | `refreshAllQuotas`、`refreshQuotasUnified` | 原槽位等待、来源复核、上下文采样、两条时间写入顺序、`async let` 并发及 IDE／菜单收尾不变 |
| 单提供商／单账号 | 两个 `refreshQuota(for:)` 重载、`refreshQuotaForProvider` | 原槽位互斥、精确凭据与唯一旧键映射、CPA 优先、失败保留、Codex 别名归一及提交检查不变 |
| 发现与收尾 | `discoverMonitorAccounts`、`finishScopedRefresh`、`persistMonitorAccountIssues`、`refreshAutoDetectedProviders` | 原发现与发布校验、失败持久化、成功时间、通知、菜单及显式 IDE 导入边界不变 |

共迁移 14 个原方法，其中 13 个生产方法和一个 `#if DEBUG` 目录读取包装方法。包装随目录事务辅助迁移，使 `refreshAuthDirectorySnapshot` 继续保持 `private`；`persistMonitorAccountIssues` 也继续私有。所有 Debug 存储仍在主类，生产构建不会增加测试入口。

## 私有节流与必要访问范围

本批保留 `lastQuotaRefresh`、`quotaRefreshInterval` 和原刷新设置的私有访问范围，在主类仅新增两个同步方法：

- `isQuotaRefreshDueForPolling()`：承接 `refreshData` 原到期判断。没有记录时仍立即到期；已有记录时仍使用当次 `Date()` 与当前设置的原间隔比较，不缓存或推进时间。
- `recordQuotaRefreshStart()`：仅执行原 `lastQuotaRefresh = Date()`。调用位置仍在取得槽位和来源复核之后；`refreshAllQuotas` 仍先记录私有时间再更新可见时间，`refreshQuotasUnified` 仍先更新可见时间再记录私有时间，不合并两次取时。

三个调用点只做上述同步替换，不增加 `await`、调度、节流状态副本或配置键。原 250 个成员均保留，新增两个方法后总计 252 个成员；其余 247 个原成员完整正文与属性保持一致，仅归一以下四项必要访问调整。

| 由 `private` 调整为内部可见的原方法 | 跨文件需要与保留边界 |
|---|---|
| `canUseRefreshSource` | 刷新扩展在原位置复核来源；主类仍读取原取消、模式世代和代理会话 |
| `beginScopedRefresh` | 扩展经原同步方法申请槽位，原 active 集合与 `private(set)` 集合只在主类写入 |
| `endScopedRefresh` | 原 `defer` 成对释放同一槽位，释放与通知顺序不变 |
| `checkAccountStatusChanges` | 目录刷新复用原冷却通知与去重流程，私有字典和通知管理器不开放 |

没有将可变私有属性、私有 setter 或节流间隔开放给扩展；没有新增 `public` API。

## 状态、任务与提交顺序

- 84 个原存储属性及其顺序、全部可变私有属性、七个 `private(set)`、四个 Task 句柄和 Debug 钩子保留在主类；原九个扩展保持逐字节一致。
- 主类继续负责刷新上下文、账号／模式／运行会话校验、槽位集合写入、私有节流和后台任务句柄；手动状态仍由同一实例持有。
- 原 `refreshData` 中触发额度批次的后台 `Task` 随同名方法迁移，声明、捕获、时点和调用保持原样，仍作用于同一 ViewModel，没有新增任务或任务持有者。
- 目录读取仍在挂起后检查上下文和当前来源，旧目录不能覆盖删除后目录；API Key 仍在目录请求后串行读取，并在发布前复核原客户端及运行会话。
- 槽位申请、成功后的 `defer`、来源复核与上下文采样不重排；取消或未取得槽位不能释放其他刷新持有的槽位，也不能提前记录节流时间。
- 两个批量路径继续使用各自原提供商集合、取数入口和参数；不合并模式分支、空结果规则或失败回退。
- 单账号失败继续保留旧额度，并按原监控路径只持久化失败；成功后的 Codex 身份归一、套餐提交与收尾顺序不变。
- 统一收尾仍依次完成原身份归一、监控发现、提交校验、连续状态发布、错误恢复与禁用清理、持久化、再次校验、可见时间及通知／菜单同步，不增加挂起点。
- 原类型名称、配置键、数据路径、布局和交互保持不变；代理生命周期与预热调度的后续批次未提前实施。

## 定向验证

本批新增 `QuotioTests/Shared/Accounts/QuotaRefreshCoordinationTests.swift`（81 行、两个测试方法）。使用独立偏好、空目录及关闭后台服务的 ViewModel，预先占用真实冲突槽位，分别调用两条原批量入口，验证后台冲突退出和手动等待取消都不消耗节流、不更新可见时间、不释放其他刷新持有的槽位。测试不增加生产测试钩子，不读取用户凭据或发起外部额度请求。原 104 个测试文件保持不变。

- 应用构建：`QuotioPlus`／Debug／macOS，`CODE_SIGNING_ALLOWED=NO`，结果 **BUILD SUCCEEDED**，无编译器警告。日志 `/tmp/quotio-quota-viewmodel-sixth-build-20261015.log`。
- 相关定向回归：**16 项通过，0 失败，0 跳过**。全部通过 `-only-testing` 指定，没有运行全量测试。

| 定向范围 | 数量 | 验证内容 |
|---|---:|---|
| `QuotaRefreshCoordinationTests` | 2 | 两条真实批量路径在槽位冲突／等待取消时不消耗节流、不释放其他刷新槽位 |
| `MenuBarAccountSyncTests` 指定方法 | 6 | 手动合并、模式切换停止后续步骤、跨模式槽位等待、GLM 删除与 Claude 同键重加的迟到额度、CPA 删除后的迟到目录 |
| `IDEQuotaRefreshReentrancyTests` 指定方法 | 2 | IDE 读取在途时单提供商／单账号互斥、取消后不提交旧额度 |
| `MonitorUpstreamCompletionTests` 指定方法 | 2 | 发现挂起时删除不恢复目录、禁用清理孤立套餐与错误并按原收尾 |
| `RefreshInteractionTests` 指定方法 | 4 | 原手动进度、重复操作合并、取消释放、批次等待与后台合并 |

精确的 `-only-testing` 方法名保存在本批测试日志的完整命令行中。测试结果包 `/tmp/quotio-quota-viewmodel-sixth-targeted-20261015.xcresult`，日志为同名 `.log`；`xcresulttool` 汇总为 `Passed`，无失败、跳过或运行时警告。未将上述离线验证表述为全部提供商的真实网络端到端覆盖。

## 完整性与维护记录

- 起始精确快照 `/tmp/quotio-quota-viewmodel-sixth-before-20261015`，覆盖 654 个原文件。
- 原方法映射、访问白名单、三个同步替换的前后文本：`/tmp/quotio-quota-viewmodel-sixth-map-20261015.json`。
- 完整性验证：`/tmp/quotio-quota-viewmodel-sixth-verification-20261015.json`。对照全部原成员，精确还原三个同步替换后正文一致，并独立核对新增两个同步方法的完整实现；原状态、属性标注、任务、私有 setter、前九个扩展及原测试文件保持不变。
- 独立只读审查：复审者直接对比精确基线，未依赖映射或完整性报告；14 个迁移方法在展开三个同步调用后与原方法一致，主类其余代码和九个旧扩展保持一致。独立确认 84 个存储、四个 Task、七个私有 setter、四项必要可见性、两个同步入口、条件编译、原并发和收尾顺序；未发现本批引入的可行动问题。
- 已同步现行维护索引，第三至五批历史实施报告不改写。
- 同期外部任务更新的架构规范入口保留原样，未覆盖 `CLAUDE.md` 或 `docs/STANDARDS.md`；`AGENTS.md` 和 `docs/PROJECT.md` 在保留外部新增入口的基础上追加本批说明。
