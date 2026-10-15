# 代理生命周期分文件维护：第二轮第七批

日期：2026-10-15。本批承接[刷新协调拆分](quota-viewmodel-refresh-coordination-split-2026-10-15.md)，完整迁移适合独立维护的代理启动及附属流程。当前入口见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 实施范围

主类从 1,376 行缩减到 1,253 行，新增 `Quotio/Shared/Accounts/ViewModels/QuotaViewModel+ProxyLifecycle.swift`（154 行、七个原方法）。新增文件头和详细中文职责注释，不修改方法正文，不增加状态、任务、辅助方法或服务实例。

| 迁移的原方法 | 维护内容与保留边界 |
|---|---|
| `observeUsageLifecycle` | 真实代理会话驱动原唯一 `usageMonitor` 启停；原 `withObservationTracking`、弱引用、MainActor Task 与一次性回调重订阅保持原样 |
| `updateProxyConfiguration` | 原十六个获取器依次更新代理配置，调用顺序、实例与等待方式不变 |
| `initializeFullMode` | 原完整模式先直读额度，再按原偏好启动代理或停服直读定时器；模式选择入口留在主类 |
| `syncDisabledStatesToBackend` | 读取同一禁用偏好和目录，请求前继续复核取消、客户端身份、运行会话与状态；仍为私有辅助 |
| `checkForProxyUpgrade` | 保留原非阻塞升级检查的调用目标，启动流程中的 Task 与会话检查不变；仍为私有辅助 |
| `startProxy` | 原启动事务完整迁移，启动协调器、取消检查、两次目录读取、禁用同步、预热、升级及隧道顺序不变 |
| `toggleProxy` | 按真实运行状态复用同一实例的原停止或启动入口 |

主类与全部扩展仍有 252 个原成员，各保留一份。本批是同一应用 Target 内的分文件维护，不表示已完成状态所有权或编译依赖隔离。

## 留在原状态宿主的流程

以下方法直接写入私有客户端或任务句柄，继续完整留在主类，不拆成额外辅助或转移所有权：

- `stopProxy`：原顺序取消启动、恢复和轮询，按原位置请求停止隧道、取消授权及代理、归一身份、恢复直读与预热调度，最后清空并异步失效旧客户端。
- `setupAPIClient`：在原启动时点建立客户端，私有 `_apiClient` 指针及其 Observation 行为不变。
- `startQuotaOnlyAutoRefresh`、`startQuotaAutoRefreshWithoutProxy`、`startAutoRefresh`：继续复用同一 `refreshTask`，保留取消旧任务、频率、睡眠、令牌刷新、额度读取、失败计数及恢复阈值。
- `attemptProxyRecovery`：先按原方式停止，采样新运行会话，再创建并保存独立恢复 Task；不把已取消轮询的状态传给新启动。
- `initialize`、`initializeQuotaOnlyMode` 及原初始化注册：保留模式选择、监控模式客户端失效与指针清空、bootstrap、挂起后校验和回调注册。
- 原 `stopQuotaAutoRefresh`、预热调度及周期：继续由主类取消、持有任务和维护私有状态；本批仅为启动扩展开放原必要调用入口。

## 必需的跨文件访问白名单

八项由 `private` 调整为应用 Target 内部可见；不增加 `public` API，不开放可变私有属性或私有 setter。

| 声明 | 调整原因及保留边界 |
|---|---|
| `proxyStartFlow` | 扩展复用原启动协调器，仍为主类唯一创建的 `@ObservationIgnored let`；停止仍取消同一实例 |
| `observeUsageLifecycle` | 原主类初始化调用迁移后的观察方法，注册次数与生命周期不变 |
| `initializeFullMode` | 原主类模式入口调用迁移后的完整模式初始化 |
| `startQuotaAutoRefreshWithoutProxy` | 完整模式初始化调用原停服刷新循环；任务句柄和写入仍在主类 |
| `setupAPIClient` | 启动扩展调用原客户端建立入口；私有指针不开放 |
| `startAutoRefresh` | 启动扩展启用原 CPA 轮询；Task、失败计数及恢复实现不迁移 |
| `restartWarmupScheduler` | 启动扩展在原位置重启预热计划，私有计划与任务仍在主类 |
| `runWarmupCycle` | 启动扩展等待原预热周期，防重、账号执行与状态写入仍在主类 |

所有跨文件方法继续属于同一个 `@MainActor`／`@Observable` 类型。84 个存储属性及其顺序、四个 Task 句柄、七个 `private(set)`、可变私有存储及 Debug 钩子保持原样。之前十个扩展与 105 个测试源码保持逐字节一致。

## 行为与配置保持

- 启动仍经过同一 `ProxyStartFlow` 合并重复操作；原 `[self]`、弱引用、原 Task 创建位置与捕获不变。
- 保留“代理启动 → 客户端建立 → CPA 轮询及预热调度 → 首次读取 → 同步禁用 → 再次读取 → 预热周期 → 升级检查 Task → 可选隧道”的原顺序，每次挂起后的取消和运行会话检查不移动。
- 停止与恢复保留原强事务顺序；旧客户端捕获后先清空指针再异步失效，旧启动完成不能清除新启动协调器状态。
- 用量采集继续由原 `usageMonitor` 唯一消费队列；观察注册仍由原初始化控制，不新增采集器、重复订阅或第二个队列消费者。
- `autoStartProxy`、`autoStartTunnel`、`proxyURL`、刷新和预热设置、禁用偏好及运行时数据位置不变；原类型名称、功能、布局及交互保留。

## 验证记录

以下结果均来自本批实际快照、构建与测试产物。

- 起始精确快照 `/tmp/quotio-quota-viewmodel-seventh-before-20261015`，覆盖 657 个原文件。
- 原方法映射与访问白名单 `/tmp/quotio-quota-viewmodel-seventh-map-20261015.json`。
- 完整性验证 `/tmp/quotio-quota-viewmodel-seventh-verification-20261015.json`：逐成员对照全部 252 个原声明，仅归一八项访问差异后，完整正文与属性一致。原存储顺序、可变私有存储、四个 Task、七个私有 setter、十个既有扩展及 105 个测试源码保留。
- 独立只读审查：复审者直接比较精确起始快照，未依赖映射或完整性报告；独立确认七个迁移声明完整一致、主类其余代码及十个旧扩展保持原样，八项访问开放都有真实跨文件调用。MainActor／Observation、唯一用量消费者、客户端指针归属及启动／停止／轮询／恢复的原顺序未发现本批引入的可行动问题。
- 应用构建：`QuotioPlus`／Debug／macOS，`CODE_SIGNING_ALLOWED=NO`，结果 **BUILD SUCCEEDED**，无编译器警告。日志 `/tmp/quotio-quota-viewmodel-seventh-build-20261015.log`。
- 相关定向回归：**9 项通过，0 失败，0 跳过**。仅通过 `-only-testing` 执行下列范围，没有运行全量测试，没有新增、删除或修改测试源码。

| 定向范围 | 数量 | 主要验证内容 |
|---|---:|---|
| `ProxyStartFlowTests` | 3 | 旧初始化挂起时停止后可重启、重复启动不重复初始化、调用者取消向初始化传播 |
| `ManagementAPIClientLifecycleTests` 指定方法 | 4 | 旧请求停机取消与新客户端可用、单任务取消、失效或取消后不继续重试 |
| `MenuBarAccountSyncTests/testStoppedModeSchedulesQuotaTimerAndManualCadenceCancelsIt` | 1 | 停服额度刷新仍调度，切换手动频率后取消原定时任务 |
| `UsageStatisticsStoreTests/testConcurrentRefreshDoesNotCreateAnotherQueueConsumer` | 1 | 并发刷新不新增消费者，停止后已消费响应仍提交且不恢复 live 状态 |

`ManagementAPIClientLifecycleTests` 只执行 `testStoppingCancelsPendingRequestAndNewClientCanStart`、`testTaskCancellationAbortsRequestWithoutInvalidatingClient`、`testInvalidationDuringRetryCannotCreateAnotherTask`、`testCancellingRetryDoesNotWaitForFurtherRequests`。

测试结果包 `/tmp/quotio-quota-viewmodel-seventh-targeted-20261015.xcresult`，日志为同名 `.log`；`xcresulttool` 汇总为 `Passed`，无失败、跳过或运行时警告。上述用例验证原生命周期协作者及局部 ViewModel 调度，结合完整方法等价核对覆盖本次迁移，没有将其表述为真实 CPA、隧道及预热的全链路端到端验证。

现行维护索引与本批新增链接同步更新，第三至六批历史报告保留原样。
