# AIUsage 代码来源

本项目调用分析模块及两个统计页面的原生 UI 改编自 [sylearn/AIUsage](https://github.com/sylearn/AIUsage)，参考提交 `bdb83bbe077879855c03e656cbc2fe5890bd27e9`。

Copyright 2026 AIUsage contributors.

原项目按 Apache License 2.0 发布，完整许可证见 [AIUsage-Apache-2.0.txt](AIUsage-Apache-2.0.txt)。移植文件保留来源及修改说明。

Quotio 的修改包括 Swift 6 隔离与 Observation 集成、本地存储路径、隐私字段裁剪、取消与错误处理、日志去重、原生页面及四语言文案。用量统计借鉴每日聚合、真实客户端来源筛选及客户端解析规则，使用 Quotio 独立客户端账本；仪表盘另用自有 CPA 队列消费者与账本，两者不混加。

本轮 UI 参考文件包括 `ProxyStatsView.swift`、`ProxyStatsView+Summary.swift`、`ProxyStatsView+Distribution.swift`、`DashboardView+Heatmap.swift`、`CallAnalyticsView.swift` 及其 Rankings/ZeroCall/Derived 部分、`AppSurfaceTokens.swift`。修改包括 Token-only 口径、Claude Code／Codex／OpenCode 客户端来源、完整模型分布、窄窗口滚动、四语文案和无障碍交互。

客户端采集与归档还参考 `StatsDataAdapter`、`ClaudeProvider+ProxyArchive`、`CodexCostProvider+FileParsing`、`CodexCostProvider+Tracks`、`OpenCodeCostProvider+Database` 与 `+Parsing`。Quotio 的适配包括 Claude 本地 message.usage、Codex 脱敏永久累计检查点、OpenCode 只读统计投影，以及调用分析按日会话次数与未知日期迁移。实际差异和边界见[功能源码对照表](../features/usage-statistics-and-call-analytics.md#aiusage-源码逐项对照与取舍)。
