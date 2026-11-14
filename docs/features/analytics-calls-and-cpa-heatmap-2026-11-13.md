# 客户端调用去 Token 化与 CPA 用量趋势热力图（2026-11-13）

## 1. 背景与目标

- **客户端分析（客户端调用）**：删除所有本地会话 Token 统计（顶部 6 张 Token 与模型数指标卡、每日趋势中的 Token 折线图与 Token 明细列、底部 52 周本地 Token 热力图、本地模型 Token 分布环图与模型表、采集详情中的本地 Token 采集状态，以及进入客户端分析 Tab 时的后台 `ClientUsageViewModel` 扫描触发），仅保留纯粹的工具调用（Tool / MCP / Skill / Subagent）统计。
- **用量分析（CPA 用量统计）**：将「用量趋势」卡片由原折线图（`CPAUsageTrendChart`）替换为 52 周方块热力图样式（`UsageStatisticsHeatmap`），数据源完全采用 CPA 网关统计自身的账本（受提供商、模型、来源、API Key、状态筛选联动），并支持随顶部「Tokens / 请求数」指标切换同步展示 Token 热力分布或请求数热力分布（含总计、活跃天数、峰值日、四分位色阶及单日各模型明细）。

## 2. 详细范围与契约

### 2.1 客户端调用（`Quotio/BusinessModules/Analytics/ClientCalls` & `StatisticsAnalyticsScreen.swift`）
- `ClientAnalyticsOverview.swift`：
  - 移除 `client: ClientUsageViewModel.Presentation?` 及 6 项 `usage.*` Token/模型指标卡，仅保留 5 项调用指标（`callReplica.total`、`callReplica.mcpCalls`、`callReplica.skillCalls`、`callReplica.activeMCP`、`callReplica.unusedSkills`）。
- `ClientAnalyticsDailyTrendData.swift` & `ClientAnalyticsDailyTrend.swift`：
  - 移除每日趋势卡片中的 `.tokens` 折线图层及悬停/展开明细中的 Token 读数，仅保留每日工具调用柱状趋势图（`.tools`）与工具调用次数明细。
- `CallAnalyticsScreen.swift` & `StatisticsAnalyticsScreen.swift`：
  - `CallAnalyticsScreen` 移除本地 Token 热力图（`heatmaps`）、模型 Token 分布与明细表（`UsageStatisticsInsights`）、本地 Token 采集详情与错误提示，以及刷新/时区/生命周期中对 `clientUsage` 的联动调用。
  - `StatisticsAnalyticsScreen` 在 `.calls` Tab 激活时仅驱动 `callAnalytics.setPageActive(_:)`，不再启动 `clientUsage` 扫描。

### 2.2 CPA 用量趋势热力图（`Quotio/Shared/Analytics` & `Quotio/BusinessModules/Analytics/CPAUsage`）
- `UsageHeatmapPresentation.swift` & `UsageStatisticsHeatmap.swift`：
  - 支持 `metric: CPAUsageChartMetric = .tokens`（`.tokens` 与 `.requests`）：
    - 当 `metric == .tokens` 时，按每日 `totalTokens` 计算正值四分位阈值、活跃天数、峰值日、底部汇总及单日各模型占比与输入/输出/缓存拆分。
    - 当 `metric == .requests` 时，按每日 `requests` 计算正值四分位阈值、活跃天数、峰值日、底部总请求数及单日各模型请求数与占比。
- `CPAUsageDashboardReport.swift`、`CPAUsageEventStore.swift`、`CPAUsageHistoricalReport.swift`：
  - `CPAUsageDashboardReport` 新增 `heatmapBuckets: [UsageBucket]`，在 `CPAUsageEventStore.dashboard(...)` 中按当前非时间筛选条件（`provider`、`model`、`source_id`、`key_id`、`outcome`）聚合最近 52 周日级 `(day, provider, model)` 桶，并在 `CPAUsageHistoricalReport.merging(...)` 中合并满足筛选条件的历史日桶。
- `CPAUsageStatisticsView.swift`：
  - 将「用量趋势」区域的 `CPAUsageTrendChart` 替换为基于 `result.heatmapBuckets`、`result.summary.collectionStartedAt` 和 `model.metric` 的 52 周热力图卡片（标题显示「用量趋势」，副标题显示「最近 52 周」及当前指标口径）。

## 3. 验证计划

- `xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/ClientAnalyticsOverviewTests -only-testing:QuotioPlusTests/ClientAnalyticsDailyTrendTests -only-testing:QuotioPlusTests/UsageHeatmapPresentationTests -only-testing:QuotioPlusTests/CPAUsageDashboardTests -only-testing:QuotioPlusTests/CPAUsageTrendTests 2>&1 | tail -n 30`
