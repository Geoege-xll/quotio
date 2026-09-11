# CPA 用量分析增加 Token 分量曲线

仪表盘原先只绘制当前指标的单条趋势线。Token 模式现在默认同时显示总量、输入、输出和缓存四条曲线，便于比较请求用量的组成与变化。

- 图例可显示或隐藏系列，至少保留一条；颜色、线型及系列次序保持固定。
- 纵轴按当前可见系列缩放，可以隐藏较大的输入和总量，单独观察输出走势。
- 悬停同一时间点时显示所有可见系列的完整数值。悬停状态仍位于独立覆盖层，不参与坐标范围计算。
- 请求数模式继续使用请求数系列；Token 分量不与请求数共用纵轴。
- 缓存使用账本已经记录的缓存总量，可能与输入重叠。曲线不堆叠，也不把缓存再次加进总 Token。

SQL 在同一次时间分桶查询中读取所有分量，复用现有筛选。补零、旧日汇总合并以及最多 240 个区间的长历史压缩均逐分量处理，曲线合计与同范围总览一致。图例切换只改变显示，不查询网络或写入统计库。

实现位于 `CPAUsageDashboardReport.swift`、`CPAUsageEventStore.swift`、`CPAUsageHistoricalReport.swift` 和独立的 `CPAUsageTrendChart.swift`。新增代码包含中文注释，说明缓存重叠、系列身份和图表更新边界。

定向验证覆盖：小时筛选与空时段、缓存不重复计数、481 日事件压缩、旧历史合并后重启、迁移与原总览统计，以及紧凑窗口的浅色／深色、多系列／单系列、单点和空态渲染。

```sh
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/ClaudeDefaultRowDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  -only-testing:QuotioTests/CPAUsageTrendTests \
  -only-testing:QuotioTests/CPAUsageTrendRenderingTests \
  -only-testing:QuotioTests/CPAUsageDashboardTests \
  -only-testing:QuotioTests/CPAUsageSQLiteMigrationTests \
  -only-testing:QuotioTests/CPAUsageOverviewPresentationTests test
```

最终定向测试共 26 项通过，0 失败、0 跳过。界面核验图片使用合成数据，输出到 `build/CPATrendReview/`。
