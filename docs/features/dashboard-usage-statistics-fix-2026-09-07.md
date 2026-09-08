# 仪表盘统计修复与上游口径核对

## 对照来源与根因

对照 EasyCLIProxyAPI 的本地源码 `/tmp/quotio-easycpa-reference`，提交
`75fac192bd9695cfbd726ad1c66a8d800638c9c9`。主要依据为
`src-tauri/src/usage.rs` 中的 `normalize_usage_record`、`load_usage_overview`、
`load_usage_analysis`、`query_window_minutes`，以及 `src/pages/UsageRecordsPage.tsx`。

修复前，现有日账本保存 2,823 次请求、212,259,220 Tokens，而 SQLite 事件表为空。
仪表盘只查询新事件索引，将已有用量显示成零。构造测试另发现 SQLite 的
`SQLITE_OPEN_NOFOLLOW` 拒绝 macOS `/tmp`、`/var` 系统别名，导致合法临时目录无法打开数据库。

## 修复行为

- 日账本先减去已入事件索引的用量，剩余部分作为旧历史基线；在新批次累加前固定基线。
- 总览、趋势和排行合并相同历史集合，排行完成合并后再截断。首页初始时间为“全部”。
- 新事件保存写入时的 `ledger_day`，切换时区不改变所属日桶；旧事件回退匹配也最多扣减一次。
- SQLite 自动补充可空日桶列，保留旧事件。路径校验后使用 POSIX `realpath` 的物理路径打开数据库。
- 同名模型跨提供商合并；点击模型排行不会额外加入提供商条件。
- 缓存旧别名取最大值，显式读取字段优先；原始队列未报告缓存读写时按上游缺省零处理。
- 缓存总量保留上游已报告值，输入归一仅使用缓存读写分量，序列化再读取不重复归一。
- 成功率排除取消；TPS 保持成功生成样本的加权公式，RPM/TPM 的起止边界分别回退首末事件。
- CPA 卡片下集中展示六项筛选和两个图表设置菜单，趋势及用量分布共用指标状态。
- 移除用量分布中的分段选择，来源、API 密钥及结果条件也不再隐藏于“更多”浮层。

## 历史数据的精度

旧数据只有日桶，无法恢复请求时间、来源、密钥、取消分类、缓存读写拆分或生成性能。
只有完整覆盖的日桶可以纳入精确范围；无法确定的部分会显示覆盖提示，已知请求和 Token
使用下界标记。旧归档中存在未分类非成功请求时，不显示伪造的成功率、失败数和取消数。

纳入旧历史时趋势使用日级粒度。请求明细与价格统计仍仅查询已保存事件，不伪造请求或账单。
“全部”范围若含日归档，无法还原首末请求精确跨度，RPM/TPM 留空；有完整起止条件时按选定窗口计算。

## 验证

- Debug 构建成功。
- `CPAUsageDashboardTests` 10 项、`UsageStatisticsTests` 11 项、`UsageStatisticsStoreTests` 3 项，合计 24 项通过。
- 覆盖旧历史恢复、事件与历史合并、重启去重、时区重叠、旧 SQLite 升级、精确筛选覆盖、
  六维过滤、取消与 TPS、缓存别名与序列化、模型排行下钻等行为。
- 将实际旧账本复制到隔离临时目录，直接运行生产统计代码：总览恢复 2,823 次请求；
  总览、趋势、模型排行的 Tokens 均为 212,259,220；请求明细保持 0，未制造历史事件。
- 自动化界面工具未获准访问 Quotio，本次未做实际点击或截图验收。

```sh
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DebugDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  -only-testing:QuotioTests/CPAUsageDashboardTests \
  -only-testing:QuotioTests/UsageStatisticsTests \
  -only-testing:QuotioTests/UsageStatisticsStoreTests test
```
