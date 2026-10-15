# 第九批后收尾专项修复：API Key、通知与仪表盘

日期：2026-10-15。本次按用户授权处理[第九批收尾审计](quota-viewmodel-presentation-final-audit-2026-10-15.md)中的三项问题。原审计报告保留当时的发现和验证事实，本页记录后续修复结果。当前入口见[源码目录规范](../SOURCE_LAYOUT.md)。

## API Key：统一来源与读写提交

维护入口仍为 [QuotaViewModel.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift)，列表、错误、互斥与提交令牌均由原主类持有。

- 页面读取和后台目录读取统一经过 `refreshAPIKeySnapshot(using:clearingErrorOnSuccess:)`，不再在刷新扩展直接提交列表。最新读取或有效编辑开始时更换私有请求令牌，使旧列表、旧错误失效。
- 编辑仍先裁剪／校验输入，再占用原 `isMutatingAPIKeys`；编辑期间不另发列表读取，也不让读取废弃编辑所有权。增加、编辑、删除在成功和失败提交前都检查取消、同一客户端身份、模式世代、代理运行会话和请求令牌。
- 管理客户端指针替换时，在主类同步废弃旧令牌并释放旧编辑互斥，允许新客户端操作；旧请求返回后不能提交，旧 `defer` 也只能释放属于自身令牌的互斥。
- 只有当前操作的服务端成功确认才返回 `true` 并更新本地值，页面关闭草稿的约定不变。旧会话、取消或过期编辑返回 `false`；真实当前失败仍反馈原错误。
- 原 v8 客户端的列表替换、同客户端修改互斥、网络取消与失效行为不变；不扩展为跨应用／服务端事务。远端可能已接受一个随后过期的写入，但该旧写入不会被当作当前页面成功。

[QuotaViewModel+QuotaRefresh.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+QuotaRefresh.swift) 的 `refreshData` 明确返回 `Bool`，已有调用可继续忽略返回值；OAuth 的无返回值回调显式忽略结果。目录先读、密钥后读、通知／固定项清理／额度调度的顺序保持原样；过期、编辑中、取消或失败不能标记该轮成功。没有新增轮询或读写 Task。

## 通知：稳定身份与原显示文案分开

[NotificationManager.swift](../../Quotio/Infrastructure/System/NotificationManager.swift) 继续持有去重集合，主类继续比较账号状态并触发原提醒。

- 主类发送额度／冷却通知时显式传入提供商 `rawValue` 作为身份，原 `displayName` 仍用于通知文案；账号字符串不裁剪或转换大小写。
- 旧调用签名仍可使用，新增可选 `providerID` 默认值保持兼容。已知提供商按稳定身份去重，未知提供商保留原字符串，不擅自合并命名空间。
- 去重判断兼容当前稳定键与原显示名键，恢复清理同时删除匹配账号、提供商及通知类别的两种键；恢复后再次不足或冷却可以再次提醒，重复同轮提醒仍被抑制。
- 保留原通知阈值、启用偏好、未知比例过滤、原生 `active` 与旧 `ready` 恢复语义。升级、崩溃等其他通知仍经相同系统出口投递。

为验证真实通知对象生成而不向系统发送通知，管理器允许内部构造注入偏好与投递出口；私有正常构造仍使用 `.standard` 并请求原系统授权，原共享实例不变。仅 Debug 构造可使用临时偏好、内存接收器和旧去重标记样本，不开放 `isAuthorized` 的 setter。VM 仍以私有 `let` 持有原通知管理器依赖，默认 `.shared`。

## 仪表盘：只提交当前会话的真实完成时间

主类 `refreshDashboard` 继续持有刷新序号、互斥及完成时间，`defer` 仍负责原收尾。外部等待步骤经同一个主类私有协调方法执行，未建立第二个仪表盘状态宿主。

- 开始时捕获客户端、模式与代理会话；目录返回后、用量返回后均检查取消、同一来源及代理仍在运行。旧轮次不得刷新新会话的时间，也不得在来源变化后继续下一步。
- 完成时间同时要求本轮目录结果、用量结果成功及原当前错误检查通过，不再只依赖可能被其他操作清空的全局错误。
- 用量复用 [UsageStatisticsStore.swift](../../Quotio/Shared/Analytics/CPA/Services/UsageStatisticsStore.swift) 的唯一消费者及原 `drainWaiters` 屏障。新增 `refreshForDashboard(sessionID:)`：消费者尚未接入目标代理会话时拒绝；忙碌时等待正在消费的这一轮，不额外弹出队列；完成后复核同会话、同存储世代、取消、维护和忙状态。
- Store 在每轮真正开始时清除私有完成证据，仅成功采集并落盘，或已确认关闭采集时置为成功。接口不支持、存储／网络失败、取消、停止或未完成均不成功；不能用上一轮残留的 `live` 状态代替本轮结果。
- 已确认关闭采集的 `disabled` 视为有效状态刷新，不消费队列；`unsupported` 不记录成功时间。已有历史快照、待落盘批次和统计页面手动刷新行为保留。

私有完成证据仍属于原 Store，原 Task 句柄、消费者数量和消费／持久化顺序不变。仅 Debug 的 VM 包装替换两个外部等待步骤，真实互斥、来源校验和时间写入仍走生产实现；`CLIProxyManager` 的 Debug 内存样本入口仅由测试宿主设置并恢复运行状态，不启停真实进程或改变配置。

## 兼容性与改动边界

- 原七个 VM `private(set)` 声明、所有原存储与四个 Task 句柄保留；新增私有 API Key 令牌仍在主类，原受保护写入不移到扩展。通知及用量服务的私有 setter 不开放。
- 原类型名称、配置键、默认共享依赖、运行时路径、数据格式及历史兼容逻辑不变。没有增加 UI、导航或新的后台消费者。
- 本轮使用 `/tmp/quotio-finalization-fixes-before-20261015` 精确快照核对范围，没有以工作区全部历史未提交差异代替本轮变更。任务期间并发修改的 `AgentCard.swift` 保留，未纳入本次实现与审查。
- 新增四个定向测试文件；原行为测试不删除、不改名。共享离线 HTTP 夹具仅补充可释放响应门与取消后丢弃响应，原夹具路径和类型保留。
- 更新当前维护索引；第九批及此前历史实施报告保持原样。独立复审发现的用量成功判定缺口已补齐，修订后未发现本轮仍需修复的新问题。

## 构建和定向回归

`QuotioPlus`、Debug、macOS、关闭签名构建通过，最终日志为 `/tmp/quotio-finalization-fixes-delivery-build-20261015.log`。没有运行全量测试。

| 用例范围 | 不重复用例数 | 主要验证 |
|---|---:|---|
| [QuotaAPIKeyIsolationTests](../../QuotioTests/Shared/Accounts/QuotaAPIKeyIsolationTests.swift) | 7 | 新读取代旧读、慢读不覆盖新写、编辑期间不读、旧客户端不能提交／解锁新编辑、三种编辑的模式隔离、运行会话／取消、后台真实读取路径 |
| [NotificationIdentityTests](../../QuotioTests/Infrastructure/System/NotificationIdentityTests.swift) | 4 | 额度／冷却恢复后再提醒、原文案、旧键兼容、类别与账号隔离、阈值与偏好、未知提供商 |
| [DashboardRefreshSessionTests](../../QuotioTests/BusinessModules/Dashboard/DashboardRefreshSessionTests.swift) | 5 | 真实主类提交路径的互斥与刷新序号、两处等待后的停止／重启／客户端／模式隔离、取消及两步骤失败 |
| [UsageDashboardRefreshTests](../../QuotioTests/Shared/Analytics/UsageDashboardRefreshTests.swift) | 6 | 真实唯一消费者的忙时等待、目标会话绑定、401／404、关闭采集、磁盘失败、停止／维护、取消后残留 `live` |
| `QuotaFinalizationTests` | 6 | 保留原展示、切换门面、密钥校验／失败及取消互斥约定 |
| `DashboardModelCatalogLoaderTests` | 6 | 保留原目录凭据加载、取消和旧会话隔离 |
| `UsageStatisticsStoreTests` | 4 | 原唯一队列消费、手动等待、关闭采集及不支持接口语义 |
| `ManagementAPIClientLifecycleTests` | 11 | 原客户端失效、取消、重试与队列契约；兼顾共享夹具变更 |
| `CPA8ManagementAPIContractTests` 的客户端密钥两项 | 2 | 原 v8 列表替换及并发编辑／取消 |
| 合计 | 51 | 各项最终均通过 |

验证分批执行：首轮 41 项中 40 项通过，唯一失败为新增后台用例夹具错匹配旧 `/auth-files`，修正为实际 v8 `/credentials` 后仅重跑该项通过；复审补齐用量结果后，对改变的仪表盘、真实消费者及原 Store 共 15 项定向验证，全部通过。汇总为 51 个不同用例各自最终通过，57 次用例执行；结果包均无跳过、无预期失败或运行时 warning，构建无编译器 warning。没有把首轮失败包改写成全绿结果。

结果包与日志：

- `/tmp/quotio-finalization-fixes-targeted-20261015.xcresult` 及对应日志：首轮 41 项。
- `/tmp/quotio-finalization-fixes-targeted-recheck-20261015.xcresult` 及对应日志：夹具修正后一项。
- `/tmp/quotio-finalization-fixes-dashboard-final-20261015.xcresult` 及对应日志：最终相关 15 项。
- `/tmp/quotio-finalization-fixes-verification-20261015.json`：范围、受保护声明、原任务与测试结果汇总。

回归使用随机离线 HTTP 主机、临时偏好和临时账本；不操作真实账号或系统业务通知，不启停 CPA 或 IDE。VM 沿用原 `CLIProxyManager.shared` 构造，仍可能读取原管理配置；测试宿主里的内存运行样本不代表真实进程运行。真实系统通知投递与服务端多客户端同时改表不属于本次隔离验证范围。
