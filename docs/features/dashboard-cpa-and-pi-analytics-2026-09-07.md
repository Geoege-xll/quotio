# 仪表盘 CPA 用量与 Pi 本地分析

## 页面职责

- 仪表盘：展示 CPA 用量，不再展示可用模型目录。
- 智能体配置：页面底部完整复用 AvailableModelsSection，保留刷新、展开、复制、详情定位。
- 用量分析：仅展示本地客户端数据，保留客户端分段并新增 Pi，不加入 CPA/本地切换。
- 调用分析：仅展示本地工具调用，新增 Pi，扫描/取消移至系统导航工具栏。

## CPA 视图解耦

DashboardUsageSummary 仅从组合层注入唯一 UsageStatisticsStore 和账号概况。
CPAUsageStatisticsView 独立负责展示，CPAUsageStatisticsPresentation 负责纯筛选和汇总。
View 不创建 ManagementAPIClient，不新增消费式 usage-queue 读取器。
采集服务仍由应用生命周期启动，仪表盘导航刷新复用既有刷新入口。

## EasyCLIProxyAPI 对照

参考本地源码 /tmp/quotio-easycpa-reference：

- src-tauri/src/usage.rs：UsageOverview、UsageQuery、parse_usage_record、load_usage_overview。
- src/pages/UsageRecordsPage.tsx：概览、分析、请求事件、价格与数据管理页面。
- src/services/usageMetrics.ts：生成速度和缓存读取比例。

上游还统计取消数、分开的缓存读取/创建、RPM/TPM、首 Token 延迟、生成速度及价格表费用。
本轮展示现有账本可可靠提供的请求数、非成功请求数、成功请求占比、平均延迟、Token 和模型分布。
成功占比使用成功请求/全部请求，不冒充上游排除取消后的成功率。
未保存的取消分类、TTFT、价格等不推算；费用不是实际账单。

新增缓存字段兼容 cache_read_tokens、cache_creation_tokens、cached_tokens、cache_tokens。
参考上游证据规则归一 Claude 缓存输入；缓存与推理不重复计入总 Token。
历史账本仅保存日桶，无法补回过去被遗漏的缓存字段，不重写用户历史数字。
旧版 CPA 仅有进程累计值时禁用时间/提供方/模型筛选，并隐藏无法确定的 Token 明细。

## Pi 数据依据

- https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/types.ts
- https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/api/openai-completions.ts
- https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/session-manager.ts
- https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/config.ts

扫描默认 ~/.pi/agent/sessions，支持 PI_CODING_AGENT_DIR 和 PI_CODING_AGENT_SESSION_DIR。
任意命令行 --session-dir 或项目专属目录如果未出现在上述根目录内，不自动遍历磁盘寻找。

用量按 assistant usage 读取，也读取明确带 usage 的 compaction/branch_summary；后两者未报告模型时显示 unknown。
Pi 的 input 不含 cacheRead/cacheWrite，归一后输入包含缓存；reasoning 已属于 output，不重复加总。
消息条目 ID、时间和来源元数据形成散列身份，导出的分支不会重复累计。
缺失思考明细时不显示确定的思考小计。日志正文、工具参数和凭据不写入统计缓存。

调用使用 assistant content[].toolCall 与 toolResult 配对，声明与结果不重复计数。
返回中的 isError 用于已知结果；不从相邻消息时间猜测执行耗时。
读取 SKILL.md 作为启发式技能调用，只有明确的 MCP 命名才按服务器归类。
Pi 全局技能目录进入清单，不猜测扩展托管的技能或 MCP 配置。
损坏文件或超限行报告部分读取失败，仍保留其他有效事件。

## 验证状态

本轮未编译、未运行测试、未安装插件、未扫描真实用户日志。
需要后续验证：CPA 卡片与停止/旧版状态、模型目录迁移、Pi 用量归一与分支去重、工具结果配对、缓存整数边界。
此前菜单栏的三项旧口径测试预期不属于本轮修改，尚未同步。
