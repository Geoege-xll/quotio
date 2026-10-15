# QuotaViewModel 分文件维护：第二轮第三批

日期：2026-10-15。本批承接[独立视图拆分](independent-view-split-2026-10-15.md)，只实施已审计的前四项：模型、菜单投影、凭据传输和 OAuth。当前入口见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 实施范围

`QuotaViewModel.swift` 从 3,461 行缩减到 2,996 行，新增以下五个文件。它们仍在同一应用 Target 内，四个扩展继续作用于原实例，不新增协作者或状态所有者。

| 文件（相对 `Quotio/Shared/Accounts`） | 行数 | 维护内容 |
|---|---:|---|
| `Models/OAuthState.swift` | 44 | 原顶层授权状态与回调、设备流字段 |
| `ViewModels/QuotaViewModel+Models.swift` | 38 | 原嵌套 `OAuthLaunchMode`、`WarmupStatus`、`WarmupModelState`，完整类型名不变 |
| `ViewModels/QuotaViewModel+MenuBar.swift` | 94 | 身份归一、菜单候选、自动选择、裁剪及额度显示投影 |
| `ViewModels/QuotaViewModel+AuthFileTransfer.swift` | 130 | 上传、单次／批量导入、下载、导出及 Vertex 服务账号导入 |
| `ViewModels/QuotaViewModel+OAuth.swift` | 230 | CPA、Monitor、Copilot、Kiro 授权与轮询、手动回调和取消 |

原 250 个类成员均保留且唯一，其中 32 个移入扩展，另有原顶层 `OAuthState` 归位，共迁移 33 个声明。方法及类型正文、属性、默认值、调用顺序与条件编译保持原样，仅对必要访问范围作下述调整，并增加中文职责及边界说明。

## 必需的跨文件访问白名单

Swift 不允许另一文件中的同类型扩展访问原 `private` 成员。本批仅将以下 10 项改为应用 Target 内部可见，不新增 `public` API，原 `private(set)` 字段的写入权限保持不变。

| 声明 | 必需原因与边界 |
|---|---|
| `directAuthService` | 凭据传输扩展复用原注入的服务；仍为主类唯一持有的 `let` 依赖 |
| `modeManager` | 菜单投影、传输与授权继续检查同一模式和世代；不创建管理器副本 |
| `kiroFetcher` | OAuth 扩展调用原获取器，实例仍在主类初始化 |
| `cpaOAuthSession` | OAuth 扩展复用原授权协调器；会话所有权和取消关系不变 |
| `RefreshContext` | 跨文件调用 `beginAccountMutation` 所需的既有返回类型，字段与实现不变 |
| `beginAccountMutation` | Monitor 授权成功仍经原入口更新账号变更世代 |
| `notifyQuotaDataChanged` | 菜单扩展继续进入原通知合并入口，原 Task 仍由主类持有 |
| `reconcileAccountQuotaIdentities` | 主类刷新与目录提交继续调用已移到菜单扩展的原身份归一方法 |
| `autoSelectMenuBarItems` | 主类原调用点继续使用菜单扩展的自动选择逻辑 |
| `pruneMenuBarItems` | 主类原调用点继续使用菜单扩展的固定项裁剪逻辑 |

`menuBarSettings` 原 getter 留在主类，继续复用其私有 `menuSettings`。`AuthImportContext` 及传输来源固定、校验、读取、写入与成功后刷新等辅助同文件保留 `private`，不开放为外部传输入口。

## 状态与兼容边界

- 全部 84 个存储属性（含静态属性和 Debug 测试钩子）仍按原顺序留在主类；不通过扩展增加存储或复制状态。
- `quotaNotificationTask`、`refreshTask`、`warmupTask`、`proxyRecoveryTask` 四个 Task 句柄和原初始化保留。原方法内的局部 Task 原样迁移，不改变创建或取消时机。
- 七个 `private(set)` 字段保持原样：`refreshingProviders`、`refreshingAccounts`、`modelCatalog`、`dashboardRefreshID`、`isRefreshingDashboard`、`dashboardRefreshTime`、`isMutatingAPIKeys`。
- 刷新世代、代理启停恢复、预热、IDE、模型目录与 API key 状态及操作留在主类。本批不重组这些职责，不改变状态所有权。
- 凭据批次仍在首次挂起前固定管理客户端、模式世代及代理会话；失效后停止后续传输，保留逐文件容错与成功后一次刷新。
- OAuth 继续使用原 CPA 协调器及 Monitor／CLI 流程，保留手动回调、设备流、有效期、浏览器打开策略和会话隔离。
- 类型名称、配置键、编码结构、用户配置、运行时路径及历史兼容逻辑不变；104 个原测试文件保持原样。

这次完成的是按原类型分文件维护，主类仍为同一应用级状态和任务宿主，不能据此认定已完成职责所有权拆分或编译依赖隔离。前两批历史报告保留原范围和实际验证事实。

## 验证记录

以下结果来自本批快照、实际源文件、构建日志和定向测试结果包，没有沿用前批验证结果。

- 起始快照：`/tmp/quotio-quota-viewmodel-split-before-20261015`。
- 声明迁移及访问白名单映射：`/tmp/quotio-quota-viewmodel-split-map-20261015.json`。
- 完整性验证：`/tmp/quotio-quota-viewmodel-split-verification-20261015.json`。原 250 个类成员正文与属性保持一致；84 个存储属性、七个私有 setter、四个任务句柄和全部 104 个测试文件保留。
- 维护索引与本批新增链接同步，本地目标检查仅针对本批调整，不重写历史文档。
- 独立只读复审：直接对照本批快照，核对完整声明、MainActor 与 Observation、私有访问、任务与状态宿主、传输来源快照及菜单通知；未发现本轮引入的可行动问题。
- 应用构建：`QuotioPlus` / Debug / macOS，`CODE_SIGNING_ALLOWED=NO`，结果 **BUILD SUCCEEDED**；日志 `/tmp/quotio-quota-viewmodel-split-build-20261015.log`。
- 相关定向验证：**56 项通过，0 失败，0 跳过**。只通过 `-only-testing` 指定下列四个测试类，未运行全量测试，未新增或删除测试。

| 定向测试类 | 数量 | 主要覆盖 |
|---|---:|---|
| `MenuBarAccountSyncTests` | 22 | 当前模式目录、凭据身份、旧固定项兼容、删除／重加与迟到刷新、手动刷新合并和原生控件 |
| `AuthImportSessionTests` | 8 | 传输中换客户端、模式往返、取消及停服、逐文件容错、固定来源与成功后一次刷新 |
| `AuthFileTransferTests` | 6 | 安全文件名、私有写入与内容往返、JSON 校验、停服账号兼容和下载资格 |
| `CPAOAuthSessionCoordinatorTests` | 20 | 授权状态、设备流有效期、取消、迟到结果、回调身份及解析、浏览器 URL 和提供商映射 |

测试结果包为 `/tmp/quotio-quota-viewmodel-split-targeted-20261015.xcresult`，日志为同名 `.log`；`xcresulttool` 汇总为 `Passed`，无失败、跳过或运行时警告。
