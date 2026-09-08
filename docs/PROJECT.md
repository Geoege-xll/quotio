# Project — Quotio

## Current project

Quotio 是原生 macOS 菜单栏与窗口应用，用于管理本机 CLIProxyAPI、提供商账号、配额和 CLI 代理配置。使用 Swift 6、SwiftUI，最低支持 macOS 15，仅维护 Apple Silicon（arm64）；通过 Xcode 的 Quotio scheme 构建。

## Active features

| Feature | Current summary | Detail |
|---|---|---|
| usage-statistics-and-call-analytics | 独立 CPA 仪表盘账本，Claude Code／Codex／OpenCode 客户端 Token 统计，以及 MCP／技能／工具和代理会话调用分析 | [用量统计与调用分析](features/usage-statistics-and-call-analytics.md) |
| cpa-detail-layout | 请求明细与价格统计整页滚动、固定每页 20 条，保持窗口尺寸并统一表格卡片 | [明细页面布局](features/cpa-detail-layout-2026-09-08.md) |
| client-usage-chart-responsiveness | 客户端用量统计隔离悬停更新、限制趋势绘制点数，简化圆环及模型行图表布局 | [用量图表响应修复](features/client-usage-chart-hang-2026-09-08.md) |

## Controlled documents

- 二次开发与上游合并：[维护指南](SECONDARY_DEVELOPMENT.md)

- 功能与架构说明：`docs/features/`
- 需求与实施计划：`docs/plans/`
- 工程与设计规范索引：[STANDARDS](STANDARDS.md)
- 现有原型：`docs/standards/prototype/`
- 第三方代码来源：[AIUsage](licenses/AIUsage-attribution.md)
