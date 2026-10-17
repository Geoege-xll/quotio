# Project — Quotio

## Current project

Quotio 是原生 macOS 菜单栏与窗口应用，用于管理本机 CLIProxyAPI、提供商账号、配额和 CLI 代理配置。使用 Swift 6、SwiftUI，最低支持 macOS 15，仅维护 Apple Silicon（arm64）；通过 Xcode 的 `QuotioPlus` scheme 构建。源码按业务聚合，跨业务能力和外部系统接入分别放入 `Shared` 与 `Infrastructure`；完整入口见[源码目录与归属规范](SOURCE_LAYOUT.md)。

## Active features

| Feature | Current summary | Detail |
|---|---|---|
| usage-statistics-and-call-analytics | 独立 CPA 仪表盘账本，Claude Code／Codex／OpenCode 客户端 Token 统计，以及 MCP／技能／工具和代理会话调用分析 | [用量统计与调用分析](features/usage-statistics-and-call-analytics.md) |
| cpa-detail-layout | 请求明细与价格统计整页滚动、固定每页 20 条，保持窗口尺寸并统一表格卡片 | [明细页面布局](features/cpa-detail-layout-2026-09-08.md) |
| client-usage-chart-responsiveness | 客户端用量统计隔离悬停更新、限制趋势绘制点数，简化圆环及模型行图表布局 | [用量图表响应修复](features/client-usage-chart-hang-2026-09-08.md) |
| antigravity-models-sheet | 全模型弹窗显式注入展示偏好，保持空列表和加载期间的呈现，验证不同窗口尺寸及滚动关闭 | [PR #558 适配与布局回归](features/antigravity-models-sheet-layout-2026-10-15.md) |
| upstream-followup-audit | AppKit 重入取证、Copilot 与 CLI 兼容收尾、菜单历史来源和期限修复 | [近期同步改动专项复审](features/appkit-layout-reentry-and-followup-audit-2026-10-15.md) |
| menubar-native-cascade | 真实三级菜单刷新与模式隔离、Codex 悬停及库存滚动、Antigravity Gemini 汇总主机修复 | [级联审计与额度修复](features/menubar-native-cascade-and-antigravity-quota-2026-10-16.md) |
| antigravity-hub-quota | 本地与 CPA 共用 Hub 周期汇总契约，保留精确账号与原任务边界，取消跨环境周期拼接 | [周额度根因与取数重构](features/antigravity-hub-quota-contract-2026-10-17.md) |
| built-in-model-candidates | 历史静态候选清理记录；默认行为已由下方动态目录方案替代 | [候选与默认值清理](features/built-in-model-candidates-2026-10-16.md) |
| dynamic-model-defaults | 动态目录、首次配置与失败重试、旧配置合并、认证与会话隔离、并发提交 | [实施记录](features/dynamic-model-defaults-2026-10-16.md) |

## Controlled documents

- 代码架构标准体系：[ARCHITECTURE_STANDARDS](ARCHITECTURE_STANDARDS.md)
- 源码目录、业务归属与测试镜像：[SOURCE_LAYOUT](SOURCE_LAYOUT.md)
- 二次开发与上游合并：[维护指南](SECONDARY_DEVELOPMENT.md)
- 首轮目录规整：[实施记录](features/source-directory-organization-2026-10-15.md)
- 第二轮第一批公共模型与纯规则拆分：[实施记录](features/public-model-split-2026-10-15.md)
- 第二轮第二批设置、额度与菜单栏独立视图拆分：[实施记录](features/independent-view-split-2026-10-15.md)
- 第二轮第三批 QuotaViewModel 模型、菜单投影、凭据传输及 OAuth 分文件维护：[实施记录](features/quota-viewmodel-split-2026-10-15.md)
- 第二轮第四批 IDE 额度与账号变更分文件维护：[实施记录](features/quota-viewmodel-ide-account-split-2026-10-15.md)
- 第二轮第五批本地、CPA 与监控提供商取数分文件维护：[实施记录](features/quota-viewmodel-provider-fetching-split-2026-10-15.md)
- 第二轮第六批刷新协调、目录读取及各粒度刷新分文件维护：[实施记录](features/quota-viewmodel-refresh-coordination-split-2026-10-15.md)
- 第二轮第七批代理启动及附属生命周期流程分文件维护：[实施记录](features/quota-viewmodel-proxy-lifecycle-split-2026-10-15.md)
- 第二轮第八批预热设置、选择与执行分文件维护：[实施记录](features/quota-viewmodel-warmup-split-2026-10-15.md)
- 第二轮第九批只读展示、Antigravity 切换归位及仪表盘、API Key、通知收尾审计：[实施与审计记录](features/quota-viewmodel-presentation-final-audit-2026-10-15.md)
- 第九批后 API Key 会话与读写隔离、通知去重、仪表盘完成时间修复：[专项修复记录](features/quota-viewmodel-finalization-fixes-2026-10-15.md)
- 第三轮第一批 Monitor 现有模型、保险库、世代、存储、发现及协调器按完整类型归位：[实施记录](features/monitor-runtime-type-split-2026-10-15.md)
- 第三轮第二批 Workspace 会话协议、IO 辅助和五个客户端 Provider 按完整类型归位：[实施记录](features/workspace-session-provider-split-2026-10-15.md)
- 第三轮第三批 CPA 路由策略、账号权重、公共查询契约和复用输入组件的业务归属纠正：[实施记录](features/cpa-business-boundary-2026-10-15.md)
- 第三轮第四批账号身份、IDE 扫描契约、OAuth 协调及共享弹窗、运行模式与导航归属纠正：[实施记录](features/account-business-boundary-2026-10-15.md)
- 第三轮第五批模型目录读取与客户端配置写入解耦、Pi 本地路径契约归位：[实施记录](features/model-catalog-business-boundary-2026-10-15.md)
- 第三轮第六批存储维护协调器与目的地的应用装配归属纠正：[实施记录](features/storage-maintenance-composition-2026-10-15.md)
- 整理后监控模式 Claude 手动授权取消、迟到响应及新旧会话隔离：[专项修复](features/monitor-claude-oauth-session-isolation-2026-10-15.md)
- 第三轮后续业务边界审计、历史拆分纠偏及实施顺序：[审计与方案](features/business-boundary-audit-third-round-plan-2026-10-15.md)（六批已完成，后置候选未自动实施）

- 功能与架构说明：`docs/features/`
- 需求与实施计划：`docs/plans/`
- 工程与设计规范索引：[STANDARDS](STANDARDS.md)
- 现有原型：`docs/standards/prototype/`
- 第三方代码来源：[AIUsage](licenses/AIUsage-attribution.md)
