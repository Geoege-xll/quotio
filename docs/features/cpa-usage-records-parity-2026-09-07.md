# CPA 使用记录：细粒度筛选与独立请求索引

## 上游对照

参考 /tmp/quotio-easycpa-reference：

- src/pages/UsageRecordsPage.tsx：rangeQuery、buildQueries、筛选项、分页。
- src-tauri/src/usage.rs：UsageQuery、UsageRecord、build_usage_filter、usage_failure_is_canceled、load_usage_overview。
- src/services/usageMetrics.ts：生成速度与缓存读取比例。

新入口位于仪表盘 CPA 标题旁的“使用记录”，使用独立 Sheet，不改动本地用量分析页面。

## 已接入

- 时间：4 小时、24 小时、今日、7 天、30 天、全部、自定义日期和时分。
- 条件：模型、提供方、账号来源、API 密钥、成功/失败/取消；支持未提供来源/密钥。
- 选项只受时间范围影响，类别筛选不导致其他选项消失。
- 每页 25/50/100/200 条；筛选变化回到第一页；按请求时间倒序、ID 次序稳定排序。
- 请求详情：模型、别名、思考强度、路由、结果、失败状态码、Token、缓存读取/创建、延迟、TTFT、TPS。
- 汇总按完整筛选结果计算，不仅汇总当前页。

## 口径

取消信号：failed 且状态 499，或错误正文包含 context canceled / client closed request，兼容显式 canceled 标记。
成功率：成功 / (成功 + 失败)，排除取消。
RPM/TPM：所选窗口平均，最短一分钟；全部记录按首末事件跨度。
TPS：成功生成、输出非零、有正 TTFT 且总延迟大于 TTFT 的有效样本，合计输出 / 合计生成耗时。
缓存读取比例：缓存读取 / 已归一输入；不完整字段不显示成确定零。
缺失延迟、TTFT、缓存分项保留未知；不补猜模型价格、实际费用。

## 数据与兼容

原日账本继续保留。新增请求索引 usage-events.sqlite 与日账本位于同一私有目录，长期保存脱敏事件。
View -> CPAUsageRecordsViewModel -> UsageStatisticsStore -> UsageLedger -> CPAUsageEventStore。
没有新增 CPA 队列消费者，也不会读取真实账号配置来推断缺失事件。

日汇总与 pendingEvents 先共同原子提交；随后 SQLite 事务插入。
明细同步失败时保留 pendingEvents，采集状态转为存储错误并暂停后续出队。
下轮只重放已提交明细；稳定 ID + INSERT OR IGNORE 防止重放重复插入。
无 request_id 的并发请求使用独立 UUID，不按相同 Token/时间误合并。
旧账本没有请求级数据，不能伪造旧明细；弹窗标明明细采集起始时间。

## 隐私

账号来源只保存 SHA-256 标识，密钥只保存散列及掩码。失败正文仅用于提取取消信号，不保存。
不保存原始密钥、账号来源、IP、请求正文或工具参数；路由删除查询串和主机信息。

## 未包含与验证状态

未迁移上游的价格维护、费用估算、数据清理/导入导出模块。
本轮未运行编译或测试，也未查询生产 CPA、扫描真实用户日志或更改真实配置。
后续应验证：记录解码、取消分类、脱敏、SQL 参数绑定、时间边界、分页、待同步区重放与失败恢复、旧账本兼容。
