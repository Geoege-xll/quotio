# 统计存储统一：SQLite

## 决策与范围

CPA 仪表盘、客户端用量统计、调用分析统一使用系统 SQLite，不引入 SwiftData，也不因此提高 macOS 最低版本。选择依据是本项目的数据形态：持续导入日志、稳定身份去重、事务提交扫描进度、历史统计保留，以及 CPA 的组合筛选、分页和聚合查询。

生产数据库位于 `~/Library/Application Support/Quotio/Analytics/analytics.sqlite`。`AnalyticsDatabase` 统一连接参数、事务、路径校验和分模块迁移标记，各业务 actor 持有独立连接；不同模块使用独立表名，不将 CPA 请求与客户端用量相加。WAL 的 `-wal`、`-shm` 是同一数据库的工作文件，不是第二套应用缓存。

该决策只涉及这三个统计模块。客户端原始日志与上游 OpenCode 数据库仍是只读输入，应用偏好与配置文件仍保留原职责。

## 持久化边界

| 模块 | SQLite 中保存的数据 | 展示与扫描行为 |
| --- | --- | --- |
| CPA | 请求事件、日桶、无法恢复明细的历史基线、去重身份、采集时间、模型价格 | 事件与日桶同事务写入；筛选、分页和明细聚合在 SQL 执行 |
| 用量统计 | 脱敏记录、Codex 累计检查点、来源状态、文件指纹与游标、OpenCode 消息版本 | 日志追加继续复用既有增量读取；常驻扫描 actor 复用已加载索引 |
| 调用分析 | 日汇总、代理调用日汇总、工具清单、来源状态、成功扫描指纹、归档统计时区 | 未变化来源跳过日志正文解析；有变化来源重新扫描后合并历史高水位 |

客户端扫描输入与展示投影使用同一库内不同 scope。扫描游标与其对应的已解析事实先原子提交，展示投影可幂等重放，因此在扫描完成、投影尚未完成时退出也不会只留下无法恢复数据的游标。业务字段按行列存储，不把完整旧 JSON 改放到一个 BLOB 中。

内存中的快照、索引字典、日桶和筛选报表都是可重建结果，不构成第二个持久化数据源。筛选报表使用有界缓存，新快照发布后失效。

## 旧数据迁移

旧 CPA 日账本与 `usage-events.sqlite`、客户端用量账本与各来源 `ScanCache`、调用分析日摘要只在对应迁移标记尚未提交时读取。迁移标记和数据同事务写入，失败时可以重试。原文件保留为旧版本备份，不再日常读写，不自动删除用户历史。

CPA 迁移将已存在的明细从旧日桶中扣除，余量作为历史基线保存，避免合并时双计。没有明细的旧历史不伪造来源、密钥、请求时间等字段，其筛选覆盖限制沿用既有 UI 语义。

调用分析保留 Schema 6/7 的未知日期代理余量与历史高水位。由于旧归档只有日摘要，不能在系统时区变化后把同一历史事件再次分配到另一天；SQL 归档固定统计时区，筛选使用相同日历，页面显示该时区。旧 JSON 没有原时区信息，首次迁移按首次运行时区接续，无法重新推断其原始事件日期。

## 页面生命周期与性能边界

应用层持有用量统计和调用分析模型，语言切换和窗口重开也复用同一实例。切换侧栏不再销毁引擎或快照，离开用量页面只暂停定时刷新，已开始的采集继续完成；用户仍可明确取消。自动进入检查 60 秒新鲜度，并发刷新合并成同一轮任务；手动刷新可立即检查来源。

来源和日期筛选只派生当前快照，不触发扫描。用量总览、趋势和模型排行的聚合结果构造一次后复用，调用分析的多张卡片共享筛选报表。

本次调用分析采用来源级变化检测，不宣称实现四个解析器的逐事件追加处理。变化来源仍可能扫描完整历史，未变化来源仍需枚举文件属性；首次旧数据导入和大历史首次读取也存在成本。性能效果应以正文读取次数、扫描调用次数及后续实际性能测量为依据，不能仅凭采用 SQLite 宣称瞬时刷新。

## 验证

验证环境：Xcode 26.6、macOS 26.5.2、arm64；项目最低部署版本仍为 macOS 14.0。

- Debug 全应用构建通过，日志：`/tmp/quotio-sqlite-unification-build.log`。
- 最终统计模块定向回归 **161 项通过、0 失败**，包含公共事务/权限、三模块旧数据迁移、失败重试、孤儿索引、去重、取消、未变化跳扫、筛选/页面生命周期、跨时区日桶重建。日志：`/tmp/quotio-sqlite-unification-targeted.log`；Xcode 报告：`build/DebugDerivedData/Logs/Test/Test-Quotio-2026.09.07_21-34-05-+0800.xcresult`。
- 第二轮全量运行 **569 项通过、3 项失败**。失败均为未在本轮修改的 `MenuBarQuotaPairTests`：`testClaudeUsesFiveHourAndLowestWeeklyLimit`、`testCodexUsesLowestStandardOrSparkLimitForEachWindow`、`testUnknownValuesDoNotOverrideKnownMinimum`。这些断言仍要求混合附加限额，与工作区已有“主额度与附加额度分开”的实现及 `codex-statistics-menubar-audit-2026-09-07.md` 冲突；本轮保留结果，没有修改菜单栏口径或将这三项排除以宣称全量通过。日志：`/tmp/quotio-sqlite-unification-tests-final.log`。
- 全量命令沿用前轮约束，显式排除两项已知语言环境基线失败：`AmpQuotaFetcherTests/testParserMapsSubscriptionOtherUsageAndRenewalSuffix`、`MonitorRuntimeTests/testCountMetricUnitsUseEnglishSingularAndPluralForms`。上述 572 项不包含这两个排除项；最终新增的 VM 日历回归在 161 项定向运行中验证。
- 独立交叉审查完成，发现的旧索引错误后误标迁移、日历缓存、语言重建生命周期均已修复并复审关闭；额外修复 CPA 空心跳写盘频率与 SQL-only 旧库最后采集时间恢复。没有剩余阻断发现。
- `git diff --check` 通过。回归全部使用隔离临时路径，没有运行新版本迁移用户正在使用的真实统计库；迁移会在新版本首次访问对应统计模块时执行。

复现构建的公共参数：

```sh
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DebugDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO build
```

定向测试使用同样参数，将最后的 `build` 改为 `test`，并以 `-only-testing:QuotioTests/<测试类>` 选择 `AnalyticsDatabaseTests`、`AnalyticsLifecycleTests`、`CPAUsageSQLiteMigrationTests`、`CPAUsageDashboardTests`、`UsageStatisticsTests`、`UsageStatisticsStoreTests`、`UsageStatisticsPresentationTests`、`UsageStatisticsDistributionTests`、`UsageHeatmapPresentationTests`、`ClientUsageTests`、`ClientUsageRefreshTests`、`ClientUsageSQLiteMigrationTests`、`ClaudeClientUsageIncrementalTests`、`CodexClientUsageTests`、`CodexClientUsagePerformanceTests`、`OpenCodeClientUsageTests`、`CallAnalyticsMigrationTests`、`CallAnalyticsReplicaTests`、`CallAnalyticsLifecycleTests`。
