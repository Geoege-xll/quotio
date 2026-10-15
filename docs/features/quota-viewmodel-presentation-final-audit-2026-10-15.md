# 只读展示与账号切换归位、流程收尾审计：第二轮第九批

日期：2026-10-15。本批承接[预热流程拆分](quota-viewmodel-warmup-split-2026-10-15.md)，完成剩余只读展示与 Antigravity 切换入口归位，审计仪表盘、API Key 和通知流程。当前维护入口见[源码目录规范](../SOURCE_LAYOUT.md)。

## 实施范围与兼容边界

主类从 1,127 行缩减到 1,037 行。新增 [QuotaViewModel+Presentation.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+Presentation.swift)（89 行）；在现有 [QuotaViewModel+AccountMutations.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+AccountMutations.swift) 尾部归入切换门面（文件由 311 行增至 349 行）。

| 归属 | 完整迁移的原成员 | 保留规则 |
|---|---|---|
| 只读展示 | `isLoadingQuotas`、两个 `isRefreshing` 重载、`supportsScopedRefresh` | 即时读取原刷新集合，原能力限制与账号／提供商刷新含义不变 |
| 只读展示 | `monitorStatus`、`monitorLastUpdated` | 原账号错误优先级、成功时间比较、实时频率与手动模式 600 秒缺省值不变；静态方法保持 `nonisolated`，不借其他账号时间 |
| 只读展示 | `authFilesByProvider`、`totalAccounts`、`readyAccounts` | 原目录分组顺序、未知提供商过滤、计数及 `AuthFile.isReady` 兼容语义不变 |
| 账号变更 | `isAntigravityAccountActive`、`switchAntigravityAccount`、`beginAntigravitySwitch`、`cancelAntigravitySwitch`、`dismissAntigravitySwitchResult` | 委托同一主类持有的切换器；仅成功后调用原不重新检测活跃账号的额度刷新，确认／取消／结果关闭语义不变 |

唯一访问调整为主类原 `@ObservationIgnored private let refreshSettings` 改为 `@ObservationIgnored let`，供迁移后的监控展示实时读取。实例仍由主类持有，没有新增设置对象或改变构造默认值。其余 14 个迁移成员原签名和方法正文均不变。

以下入口继续留在 [QuotaViewModel.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift)，避免为拆文件开放私有字段或转移写入所有权：

- `isRefreshBlocked` 直接读取私有占用集合；`apiClient` 读取私有客户端指针。
- `agentSetupViewModel` 首次读取包含懒加载写入；预热状态／时间、刷新间隔及菜单设置读取关联原私有字段。
- 刷新槽位申请／释放、目录事务、私有节流、启动停止、自动刷新、独立恢复、预热调度／防重／缓存及回调注册。
- 仪表盘模型目录、手动刷新标记／时间、API Key 互斥和列表回写、通知状态去重与发送。新增职责中文注释，执行逻辑完整保留。

这仍是同一个 `@MainActor @Observable QuotaViewModel`，同一应用 Target；分文件维护没有隔离编译依赖或拆分运行时状态宿主。

## 收尾审计结论

本批审计覆盖主类上述入口，并追踪其直接协作者：`DashboardModelCatalogLoader`、`ModelCatalogState`、`UsageStatisticsStore`、`ManagementAPIClient`、`APIKeysScreen`、`NotificationManager` 和 Antigravity 切换器。以下三项均在本批开始前的快照中存在。本批按保留行为和状态／任务所有权的要求，仅迁移声明及记录审计结果，没有混入以下行为修复；构建和定向回归通过不等于这些问题已消除。

### 1. API Key 回写缺少来源与读写世代保护（P2，待修复）

位置：主类 `fetchAPIKeys`、`addAPIKey`、`updateAPIKey`、`deleteAPIKey`；[管理客户端](../../Quotio/Infrastructure/CPA/API/ManagementAPIClient.swift) 的 `editClientKeys`；[密钥页面](../../Quotio/BusinessModules/APIKeys/Views/APIKeysScreen.swift)。

已保留的保护：编辑参数先裁剪与校验，VM 互斥标记在有效编辑开始后设置并由 `defer` 释放；客户端串行保护自身的读后写，使用 v8 `access/api-keys` 整表替换且不修改上游凭据；只有服务端确认后 VM 才更新列表并返回 `true`，页面据此关闭草稿。失败返回 `false` 并保留列表。客户端失效会取消请求，数据返回前也检查取消／失效。

缺口：VM 的成功与失败提交没有在 `await` 后复核捕获的客户端身份、运行会话或读取／编辑世代。若旧操作已经从客户端返回、在 MainActor 回写前发生来源替换，旧密钥、旧错误或成功返回仍可能落到新会话。失效取消后产生的旧错误同样可能写入当前页面。同一客户端的慢列表读取也不受编辑世代约束，可能覆盖随后已确认的编辑列表。客户端的失效检查不能覆盖客户端返回至 VM 提交之间的间隔。

专项建议：在主类保留列表、互斥和草稿返回值所有权，捕获来源与操作世代，对成功及失败统一验证；列表读取还要拒绝编辑前发起的旧快照。补充切换会话、旧失败迟到及慢读覆盖新写的定向用例。

### 2. 仪表盘手动刷新完成时间缺少末尾会话复核（P3，待修复）

位置：主类 `refreshDashboard`。原顺序为设置互斥／刷新 ID、等待 `refreshData`、等待唯一 `usageMonitor.refresh`、在全局 `errorMessage == nil` 时记完成时间，最后 `defer` 释放互斥。

模型目录自身已有运行会话和请求令牌双重保护：先等当前客户端密钥，再查询模型，返回后检查取消、运行状态及会话，`ModelCatalogState` 再拒绝旧请求令牌。唯一用量消费者也保留自身忙状态和会话检查。它们的保护不覆盖手动刷新的外层完成时间。

触发：某次手动刷新在等待期间停止／重启代理或被取消，内部请求丢弃了旧数据，但外层没有末尾来源检查；若当时全局错误为空，仍可能给已停止或新会话写入成功时间。该时间还依赖共享错误，不能独立证明本轮各步骤成功。

专项建议：捕获手动刷新对应的会话并在挂起后和提交时间前复核，明确本轮成功条件；继续让互斥标记、序号、时间及 `defer` 收尾由主类维护，不创建第二个用量消费者。

### 3. 通知发送与恢复清理使用不同提供商身份（P2，待修复）

位置：主类 `checkQuotaNotifications`、`checkAccountStatusChanges`，以及 [NotificationManager.swift](../../Quotio/Infrastructure/System/NotificationManager.swift) 的发送与清理方法。

额度提醒发送使用 `provider.displayName`，恢复清理使用 `provider.rawValue`；冷却发送使用 `providerType?.displayName ?? file.provider`，恢复清理使用 `file.provider`。管理器把参数原文拼入大小写敏感的 `quota_<provider>_<account>` 或 `cooling_<provider>_<account>` 去重集合，没有归一化。

例如发送时的 `Claude` 与恢复时的 `claude` 不能命中同一个去重键。满足通知授权及启用条件、经历不足／冷却 → 恢复 → 再次不足／冷却后，恢复清理可能未移除原键，后续提醒会被原标记抑制。该集合在本次应用进程内保存，不是跨重启持久化配置。

专项建议：将稳定提供商身份与显示文案分开；同一稳定身份用于发送和清理，兼容清理已生成的旧键。使用可隔离通知发送的测试替身验证恢复后再次提醒，不在回归中向真实系统发送通知。保留阈值、未知比例过滤、冷却状态比较和私有状态表所有权。

## 完整性核对

本轮基线为 `/tmp/quotio-quota-viewmodel-ninth-before-20261015`，记录 662 个文件的原始哈希。由于工作区包含此前未提交的目录规整，本轮以这份快照核对增量，未回退、暂存或提交已有改动。

- 原 253 个逻辑成员仍各存在一份；除唯一访问调整外，正文、属性及 Actor 标注完全一致；14 个成员完整移动。
- 原 83 个存储声明的名称、类型、顺序和所有权不变；四个原 Task 句柄不变。
- 七个 `private(set)`：`refreshingProviders`、`refreshingAccounts`、`modelCatalog`、`dashboardRefreshID`、`isRefreshingDashboard`、`dashboardRefreshTime`、`isMutatingAPIKeys` 保持原声明。
- 全部可变私有存储与主类剩余成员顺序不变。未增加状态、Task、测试钩子或 manager。
- 账号变更扩展原十三个方法保持原样，其余十一个既有扩展字节不变；原 106 个测试文件不改动，新增一个定向测试文件后为 107 个。
- 原资源、配置键、数据格式、工程及 SwiftPM 锁定文件不改动。同步更新 `AGENTS.md`、项目索引、源码归属和二次开发维护入口，历史实施报告保持原样。

独立只读复审对照同一快照，未发现本轮新增回归；确认 14 个迁移声明逐字一致、原受保护写入及 Actor 边界保留，并独立确认以上三项既有发现。复审未覆盖此前历史改动和真实 IDE／通知端到端行为。

## 构建与定向验证

应用构建：`QuotioPlus`、Debug、macOS，`CODE_SIGNING_ALLOWED=NO`，结果 `BUILD SUCCEEDED`。不主动启停用户 CPA 或执行 IDE 切换。

新增 [QuotaFinalizationTests.swift](../../QuotioTests/Shared/Accounts/QuotaFinalizationTests.swift) 六项用例：实际刷新槽位与展示联动、当前目录更新、监控错误优先级与实时频率、原切换器确认／取消／结果关闭、无效密钥草稿拒绝、写失败及挂起时互斥／取消释放／后续成功。目录与刷新验证合并在同一状态序列用例中，不直接改写受保护集合。

| 定向选择 | 实际用例数 |
|---|---:|
| `QuotaFinalizationTests` | 6 |
| `DashboardModelCatalogLoaderTests` | 6 |
| `ModelCatalogTests`：失败保留原时间、停止清空两项 | 2 |
| `CPA8ManagementAPIContractTests`：客户端密钥列表替换、并发修改与取消两项 | 2 |
| `MonitorRuntimeTests/testMonitorStatusDoesNotBorrowSiblingTimestamp` | 1 |
| 合计 | 17 |

结果包确认：17 项通过，0 失败，0 跳过，0 预期失败；未运行全量测试。没有编译器 warning，结果包没有运行时 warning。测试宿主日志仍有系统 App Intents／linkd 服务连接提示，不属于测试失败。

隔离范围：使用临时偏好 suite、随机离线 HTTP 主机和现有 `LifecycleHTTPProtocol`。Antigravity 用例只暂时修改原切换器内存并在 `defer` 恢复，不调用真实切换或检测方法。VM 构造沿用原共享基础设施，已有 `CLIProxyManager.shared`／`NotificationManager.shared` 构造可能读取管理配置或检查通知授权；关闭后台服务不代表整个构造已完全脱离系统。新增测试不主动读取真实账号凭据、执行进程切换或发送业务通知。

验证材料：

- `/tmp/quotio-quota-viewmodel-ninth-build-20261015.log`
- `/tmp/quotio-quota-viewmodel-ninth-targeted-20261015.log`
- `/tmp/quotio-quota-viewmodel-ninth-targeted-20261015.xcresult`
- `/tmp/quotio-quota-viewmodel-ninth-test-summary-20261015.json`
- `/tmp/quotio-quota-viewmodel-ninth-verification-20261015.json`
- `/tmp/quotio-quota-viewmodel-ninth-map-20261015.json`

本次验证确认迁移前后行为与上述既有约定一致，不涵盖真实 IDE 切换、系统通知投递或全部运行时竞态。三项待修复发现仍应按独立行为改动补齐验证，优先处理 API Key 提交隔离，再处理仪表盘时间与通知去重身份。
