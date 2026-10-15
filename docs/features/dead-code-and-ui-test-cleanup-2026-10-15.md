# 已确认死代码与 UI 测试清理（2026-10-15）

## 范围与依据

本轮以开始清理时的工作区快照为基线，核对声明、全仓引用、实际页面入口和相关测试，再删除没有生产消费者的闭合依赖。已有未提交功能与并行终端功能全部保留；没有提交、重置仓库或清理构建目录。

Swift 源码与测试合计删除 3,627 行、新增 350 行，净减少 **3,277 行**；包含删除 6 个生产文件、4 个旧测试文件，以及新增 2 个保留有效断言的行为测试文件。该统计不含文档，也不包含同一工作区另一任务新增的终端设置、启动与升级能力。

## 删除的生产代码

| 范围 | 清理内容 | 依据及保留边界 |
| --- | --- | --- |
| 旧账号界面 | `QuotaCard`、`ProviderAccountsGroup`／`AllAccountsSection`、`ProviderConnectionSummary`、旧 `QuotaAccountCount`、孤立 `ProviderChip` 与分组标题按钮样式 | 当前融合账号页已有真实入口；删除项仅自引用或被其自身预览引用。保留 `AccountProviderGroups`、`ProviderDisclosureGroup`、融合账号计数和额度展示。 |
| 旧设置与统计组件 | `GeneralSettingsTab`、旧更新设置分区、`CPAUsageStatisticsPresentation`、`CPAUsageChartControls`、`AnalyticsSegmentedControl`、空 `SidebarView` | 新页面不调用这些声明。保留实际使用的 `ProxyVersionManagerSheet`、统一分段控件及现行统计数据链。 |
| 孤立声明及状态 | 无消费者的旧配置／用量模型、别名样式与分区、菜单视图、旧协议、错误枚举、主题辅助方法、只写状态与多余参数 | 按声明及其私有依赖一起清理。旧导航的归一与兼容页面壳保留。 |
| 服务与 ViewModel | 无调用的 CLI／PTY 包装、CLI 检测包装、Antigravity 旧批量入口、设置切换与剪贴板包装、无消费者的更新入口和代理配置实例状态 | 保留实际执行器、当前 Antigravity 数据链、CPA 更新源、Sparkle、启动停止、备份恢复与静态代理配置工厂。 |
| 自定义提供商旧 YAML 写入 | `generateYAMLConfig`、`syncToConfigFile`、整段剥除／重写 helper、`toYAMLBlock`／`toYAMLSections` 及其专属转义逻辑 | 当前保存使用 CPA 8 局部配置同步。保留 `makeV8ProviderPatch`、字段归属摘要、权重、`legacyOwnedProviderIDs`／`legacyOwnedKeys`、`yamlSectionKey` 以及已有提供商的 Codable 兼容。`Yams` 仍用于配置解析，继续保留。 |

旧代码的存在时间不作为删除依据：旧配置迁移、历史统计解码、备份恢复和旧导航入口仍有生产职责，均未删除。自定义请求头的说明已同步改为当前 v8 PATCH、连接测试与模型目录共用规范化请求头的职责。

## UI 测试处理

删除的是纯人工截图导出、PNG 大小、无意义的视图宽度断言，以及只验证已删除旧算法或 YAML 生成器的测试。保留真正验证交互、状态副作用、位置与动画的断言。

| 原测试 | 本轮处理 |
| --- | --- |
| `ClaudeConfigurationVisualTests` | 替换为 `ClaudeConfigurationViewTests`。挂载真实 Claude 配置组件，检查已有菜单、原生菜单和旧三槽配置在显示前后完整数据相等；不导出图片或临时 CLI 配置，不修改语言偏好。 |
| `CPASettingsRenderingTests` | 替换为 `CPASettingsInteractionTests`。保留展开不改草稿、不触发保存、关闭会话固定不清除已有值，以及账号权重读取失败只发 GET 的验证。菜单栏分类与搜索断言归入 `CPARequestSettingsTests`。删除仅检查宽度或不可变局部数组的测试。 |
| `CPARoutingRenderingTests` | 删除主题与窗口宽度截图验收；将真实路由卡片挂载、隐私切换不改账号与事实事件的断言迁入 `CPARoutingTests`。 |
| `QuotaAccountCountTests` | 随无调用的旧计数算法删除。现行防重复、缓存保留、多 Key 和账号模式由融合账号及身份测试覆盖。 |
| 统计概览与刷新入口 | 删除纯 PNG 导出或宽度大于零的用例；保留未知值与零值语义、刷新归属、合并重复刷新和数据状态不变的测试。 |
| 其他原生交互与动画 | 去除默认 PNG 落盘；继续保留账号列表滚动、分析页滚动位置、图表日期联动／悬停读数／逐日明细、原生菜单、Canvas 定点像素、Timeline，以及双账号实际锚点与双向光流匹配。 |

`RoutingLiveRequestsView` 的一次性截图初始展开参数同时移除，实际展开状态仍由列表交互维护，首次进入保持收起。

## 验证结果

仅运行与本轮清理相关的 **15 个测试类，136 项全部通过，0 失败**。没有运行全量测试。HTTP 验证使用离线夹具；没有启动真实 CPA、执行真实账号授权或修改用户配置。

| 测试类 | 通过项数 |
| --- | ---: |
| `AccountPageFusionTests` | 18 |
| `AccountPageRenderingTests` | 2 |
| `AnalyticsScreenRenderingTests` | 1 |
| `CPA8ProviderPatchTests` | 15 |
| `CPARequestSettingsTests` | 12 |
| `CPARoutingTests` | 23 |
| `CPASettingsInteractionTests` | 3 |
| `ClaudeConfigurationViewTests` | 1 |
| `ClientAnalyticsDailyTrendTests` | 4 |
| `ClientAnalyticsOverviewTests` | 1 |
| `CustomProviderHeaderTests` | 19 |
| `MenuBarAccountSyncTests` | 22 |
| `RefreshInteractionTests` | 7 |
| `RoutingAccountPositionTests` | 1 |
| `RoutingFlowAnimationTests` | 7 |

定向测试发现的一个未使用变量编译警告已清除，随后只重跑 `RoutingAccountPositionTests`，1 项通过；这是上述用例的复跑，不另计不同用例数量。最后删除孤立按钮样式并更新说明后，Debug 应用构建通过，最终构建日志无编译 warning／error。只读复核未发现误删生产入口或必须恢复的独有断言。

本机验证材料：

- 起始源码快照：`/tmp/quotio-cleanup-before-20261015`
- 本轮独立 Swift 差异：`/tmp/quotio-code-cleanup-20261015.diff`
- 范围与统计：`/tmp/quotio-cleanup-scope-20261015.json`
- 定向回归：`/tmp/quotio-cleanup-targeted-20261015.xcresult`
- 定向回归日志：`/tmp/quotio-cleanup-targeted-20261015.log`
- 单类复跑：`/tmp/quotio-cleanup-final-targeted-20261015.xcresult`
- 最终构建日志：`/tmp/quotio-cleanup-final-build-20261015.log`

临时目录是本机核查材料，不作为需要长期保存的测试基准或项目依赖。
