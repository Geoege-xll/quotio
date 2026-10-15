# 独立视图拆分：第二轮第二批

日期：2026-10-15。本批承接[公共模型与纯规则拆分](public-model-split-2026-10-15.md)，只拆分 `SettingsScreen`、`QuotaScreen`、`StatusBarMenuBuilder` 中已有的完整视图及其专属辅助声明。当前维护入口见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 范围与结果

保留三个原入口，新增 34 个 Swift 文件；原有 85 个顶层声明各保留一份。视图声明体、类型名称、布局、交互、功能、配置键和运行时数据路径保持原样，新增中文职责及状态边界说明。

| 原文件 | 拆分前／后行数 | 新增文件 | 保留职责 |
|---|---:|---:|---|
| `Settings/Views/SettingsScreen.swift` | 1,826 → 52 | 15 | 根导航、搜索与模式定位状态 |
| `Accounts/Views/QuotaScreen.swift` | 1,385 → 15 | 7 | 旧额度导航兼容壳及原 Preview |
| `App/MenuBar/StatusBarMenuBuilder.swift` | 2,731 → 418 | 12 | 原生菜单装配、客户端检测缓存、筛选引用及原回调连接 |

这些目录仍属于同一应用 Target，没有新增模块、适配层、ViewModel 或状态存储。

## 设置视图

目录以 `Quotio/BusinessModules/Settings/Views` 为基准：

- `Sections/OperatingModeSection.swift`
- `Sections/ProxySettingsSection.swift`
- `Sections/LocalProxyServerSection.swift`，包含原 `NetworkAccessSection`。
- `Sections/LocalPathsSection.swift`，包含原 `PathLabel`。
- `Sections/NotificationSettingsSection.swift`
- `Sections/QuotaDisplaySettingsSection.swift`
- `Sections/RefreshCadenceSettingsSection.swift`
- `Sections/MenuBarSettingsSection.swift`
- `Sections/AppearanceSettingsSection.swift`
- `Sections/PrivacySettingsSection.swift`
- `Sections/YubiKeySettingsSection.swift`
- `Sections/UsageDisplaySettingsSection.swift`
- `Components/ManagementKeyRow.swift`
- `Components/LaunchAtLoginToggle.swift`
- `Sheets/ProxyVersionManagerSheet.swift`，包含原两个私有版本身份模型与两个私有版本行。

原 22 个完整顶层声明正文一致；不需要改变可见性。设置导航的 `NavigationPath`、搜索与定位请求继续归根页面；CPA 草稿、读取抑制、保存基线和锁继续归原 `ProxySettingsSection`。版本维护和 YubiKey 的异步操作、菜单栏／Dock 保护、密钥复制反馈及确认流程保留原宿主。

## 额度视图

目录以 `Quotio/BusinessModules/Accounts` 为基准：

- `Models/AccountQuotaPresentation.swift`
- `Views/AccountQuotaContent.swift`
- `Views/AccountPlanBadge.swift`
- `Views/AntigravityQuotaLayouts.swift`
- `Views/StandardQuotaLayouts.swift`
- `Views/AntigravityModelsDetailSheet.swift`
- `Views/QuotaDisplayHelper.swift`

原 19 个顶层声明正文和 Preview 保留。11 个被其他新文件调用的顶层类型由文件私有改为应用 Target 内部可见，其成员和实现不变；其余辅助继续保持私有。账号展示、预热状态及详情弹窗绑定仍属于原类型，原 `QuotaScreen` 只保留既有兼容入口。

## 菜单栏视图

目录以 `Quotio/App/MenuBar` 为基准：

- `StatusBarProviderFilterController.swift`
- `MenuItemHostingView.swift`
- `MenuActionHandler.swift`
- `Views/MenuBasicViews.swift`
- `Views/MenuProviderFilterViews.swift`
- `Views/ProviderIconMono.swift`
- `Views/MenuNetworkInfoView.swift`
- `Views/MenuAccountCardView.swift`
- `Views/MenuQuotaLayouts.swift`
- `Views/MenuAnalyticsDetailView.swift`
- `Views/MenuAnalyticsTrendView.swift`
- `Views/MenuNativeTooltip.swift`

原 44 个顶层声明保留；16 个跨文件使用的类型及一个 `View` 扩展方法改为应用 Target 内部可见，原方法体与成员保持不变。尺寸桥接对象、原生 Tooltip 实现及专属辅助继续保持私有。原生 `NSMenu` 跟踪、菜单项与 HostingView 的身份、目标动作对象的持有、筛选回调、图表状态和 Tooltip 生命周期保留原实现，不新增计时器或 Task。

## 状态与兼容约束

- 原 `@State`、`@Binding`、`@Environment`、`@AppStorage` 及 `Task` 原位保留在同名类型中，完整类型搬迁不改变状态所有权。
- 单例、manager、菜单缓存、预热任务和应用级账号状态不复制，不新建第二份队列消费者或刷新协调器。
- 只开放跨文件编译必需的内部访问，不新增 `public` API，不把私有桥接对象变为通用公共组件。
- 原用户配置、序列化字段、偏好键、历史兼容入口及旧导航处理保持原样。
- 测试类、测试目录及断言保持不变，只按修改范围执行定向验证，禁止全量测试。
- 第一轮与第二轮第一批文档保留当时的范围和实际验证事实，本页记录第二批。

## 验证记录

以下结果均来自本批源码、构建日志及两份定向测试结果包，没有沿用前一批结果。

- 起始快照：`/tmp/quotio-view-split-before-20261015`。
- 设置声明映射与正文哈希：`/tmp/quotio-settings-view-split-map-20261015.json`，22 个原顶层声明保持一致且唯一。
- 额度声明映射与可见性白名单：`/tmp/quotio-quota-view-split-map-20261015.json`，19 个原声明正文及 Preview 保留。
- 菜单栏声明映射与可见性白名单：`/tmp/quotio-menu-view-split-map-20261015.json`，44 个原顶层声明归位。
- 本地维护索引、目录归属和本批新增文档链接已同步；文档检查仅针对本批修改，不重写历史报告。
- 从实际新文件重新读取声明并对照起始快照：85 个声明正文及顶层属性标注一致；只有上述跨文件访问白名单发生变化。原 Preview 一致，104 个测试文件、工程文件、资源和其余源码均未改动。汇总记录：`/tmp/quotio-view-split-verification-20261015.json`。
- 独立只读复审：按本批快照核对状态宿主、视图树、Task、菜单项身份、桥接弱引用、RunLoop 及 Tooltip 生命周期，未发现本批引入的可行动问题。
- 应用构建：`QuotioPlus` / Debug / macOS，`CODE_SIGNING_ALLOWED=NO`，结果 **BUILD SUCCEEDED**；日志 `/tmp/quotio-view-split-build-20261015.log`。
- 相关定向验证：**62 项通过，0 失败，0 跳过**。每次使用 `-only-testing`，未运行全量测试，未新增或删除测试。

| 定向范围 | 已运行用例 | 数量 |
|---|---|---:|
| 设置字段、草稿与绑定交互 | `CPARequestSettingsTests`、`CPASettingsInteractionTests` | 15 |
| 账号融合、真实窗口渲染、三种额度样式和百分比 | `AccountPageFusionTests`、`AccountPageRenderingTests`、`QuotaDisplayModeTests`、`QuotaPercentagePresentationTests` | 30 |
| 账号及菜单排序 | `AccountSortingTests` | 10 |
| 菜单筛选和监控账号入口 | 下列 5 个指定方法 | 5 |
| 原生菜单跟踪、实时端口、动态高度及菜单项身份 | 单独执行 `MenuProxyStateRenderingTests` | 2 |

5 个指定方法为 `UpstreamRegressionTests/testProviderSelectionHidesItemsWithoutRebuildingMenu`、`testProviderFilterCanRebindAfterMenuItemsMove`，`MonitorRuntimeTests/testStatusBarIncludesEnabledMonitorAccountsWithoutQuota`、`testMonitorProvidersDoNotRequireInstalledCLI`，以及 `MenuBarAccountSyncTests/testNativeMultiKeyAndSingleKeyControlsRenderWithIsolatedSelection`；未执行这些类中其余无关方法。

前 60 项结果包为 `/tmp/quotio-view-split-targeted-20261015.xcresult`，日志为同名 `.log`；原生菜单 2 项单独执行，结果包 `/tmp/quotio-view-split-native-menu-20261015.xcresult`，日志为同名 `.log`。两份 `xcresult` 汇总均为 `Passed` 且无失败、跳过；原生菜单用例的定时状态断言实际完成。
