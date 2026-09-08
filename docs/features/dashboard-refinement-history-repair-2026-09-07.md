# 仪表板筛选、总览与历史明细/价格修复

2026-09-07，按用户确认的方案完成。比较基线为本轮开始时保存的 `/tmp/quotio-dashboard-refinement-before-20260907`，保留工作区此前的 SQLite 统一及其它修改。

## 页面变化

- CPA 卡片下方常驻时间范围、分组、提供商，统一使用项目胶囊分段控件。宽窗口将分组和提供商并排；每列不足 390 pt 时拆行。自定义起止日期位于时间胶囊后方，初次进入已选择的自定义范围也会滚到日期字段。
- 固定“更多筛选”入口打开原生 Sheet，包含时间、提供商、模型、来源、API Key、请求结果、分组、图表指标全部八项。草稿重置和取消不提交，应用同步提交完整状态。入口数字只统计隐藏的五类附加条件。
- Sheet 打开时读取一次 SQLite 全时间选项目录，避免从短时间范围改成全部后找不到旧模型。读取只返回选项，不聚合统计、不解码事件 payload、不触发队列采集；失败显示重试，关闭取消任务，加载完成不改草稿。
- 总览删除“更多指标”。四个主指标内嵌卡默认使用蓝、紫、绿、橙图标，数值保持系统主文本色。十三项次级指标分为 Token 与缓存（6）、性能与吞吐（4）、请求结果（3），全部常显，无重复指标。
- 不完整覆盖的已知正数显示 `≥`，无法确定的值显示 `—`；缺少总体分母时不显示精确比率。延迟、TTFT、TPS 继续按各自已报告样本计算，不能作为总体均值的下界。

## 空数据根因与修复

本机只读核对发现：旧 `ledger-v1.json` 和统一后的历史表均保存 11 条日汇总，共 2,823 次请求、212,259,220 Tokens；旧事件库和统一库的真实事件表均为 0 条，模型单价也未配置。

仪表板已经合并历史日汇总，但请求页与价格页此前仅查询真实事件，因此总览有数、两个子页为空。没有证据可以从这些日桶恢复逐条请求。

请求查询现在返回独立的历史日桶、历史覆盖信息和真实事件存在标记。页面使用“请求明细 / 历史日汇总”胶囊切换；只有历史时首次自动选择日汇总。日表展示日期、提供商、模型、请求数和 Tokens，不生成单次时间、状态或详情。事件指标和分页继续只统计真实事件；刷新和筛选尊重用户已经选择的列表。

价格查询合并真实事件与筛选可覆盖的历史模型。即使未定价，模型行仍然可见并能设置单价；编辑入口位于模型列内，窄窗口不必滚到最右侧。估算费用列优先于单价参数显示，历史覆盖、部分估算及错误说明位于固定筛选滚动区外。

计价边界：

- 未配置价格或完全没有可估分量时，费用为 `nil`，界面显示 `—`；显式零价保留真实零金额。
- 历史普通输入按输入减已保存缓存总量计算，输出按保存值计算。缺少缓存读写拆分时不估缓存费用，结果只能作为已知费用下界，也不计入完整计价请求数。
- 缓存为零、总量等于输入与输出之和且价格已配置时，历史日桶才可计入完整覆盖。
- 总量大于已知分量时可估已知部分；输入与输出超过总量、或缓存超过输入时，分量彼此矛盾，费用保持未知。
- 历史筛选、选项、排行和价格合并遵守 SQLite ASCII `NOCASE` 身份规则，保留非 ASCII 模型各自的请求和单价，避免 Unicode 转小写导致丢行或串价。
- 部分日、来源、密钥及结果筛选不能可靠匹配的历史单独报告遗漏；价格覆盖率此时显示 `—`，不会误报 100%。

当前持久化继续统一使用 SQLite，没有新增文件缓存。调查只读生产库；历史迁移和单价写入验证全部在临时隔离库执行。

## 验证结果

- 最终 Debug 完整构建通过：Xcode 26.6、macOS 26.5.2 arm64，部署目标保持 macOS 14。
- 本轮 12 个测试类共 **74 项定向回归全部通过，0 失败、0 跳过**。其中新增筛选草稿 5 项、总览展示 6 项、历史明细与价格 12 项；其余覆盖 SQLite、采集生命周期、CPA 仪表板、统计呈现与分布。
- 使用真实旧 JSON 的隔离副本验证：日桶 11、请求 2,823、Tokens 212,259,220、真实事件 0、历史价格模型 6。未定价时金额未知；临时配置构造单价后能够重新估算并标记部分覆盖。验证未把 2,823 次日汇总请求转换成虚构事件。
- 独立交叉审查及修复复审完成，没有剩余阻断项。已关闭完整筛选目录、遗漏历史的费用覆盖率、非 ASCII 模型身份、矛盾 Token 费用下界及价格入口可见性问题。
- 离屏预览使用生产 SwiftUI 组件，覆盖仪表板 1000/780/520/400 pt 深浅色、完整筛选面板 640/520 pt 深浅色、请求与价格页面 1000/780 pt 深浅色。子页使用生产 ViewModel 和无网络、无磁盘的构造数据服务。没有操控或截图用户正在运行的 Quotio，也未验证真实窗口中的鼠标/键盘交互。
- 本轮未重复运行无关业务的全量测试；上轮全量基线中的菜单栏与语言测试情况见 SQLite 统一文档。

验证记录：

- 最终构建日志：`/tmp/quotio-dashboard-refinement-final-build.log`
- 测试日志：`/tmp/quotio-dashboard-refinement-tests.log`
- 测试结果：`/tmp/quotio-dashboard-refinement-tests.xcresult`
- [隔离历史验证输出](../../work/dashboard-refinement-2026-09-07/history-verification.txt)
- [界面预览与说明](../../work/ui-design/dashboard-refinement-2026-09-07/README.md)

构建命令：

```sh
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DebugDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO build
```

定向测试使用相同参数加 `test`，限定以下测试类：`AnalyticsDatabaseTests`、`AnalyticsLifecycleTests`、`CPAUsageSQLiteMigrationTests`、`CPAUsageDashboardTests`、`UsageStatisticsTests`、`UsageStatisticsStoreTests`、`UsageStatisticsPresentationTests`、`UsageStatisticsDistributionTests`、`UsageHeatmapPresentationTests`、`CPAUsageFilterDraftTests`、`CPAUsageOverviewPresentationTests`、`CPAUsageHistoricalDetailTests`。
