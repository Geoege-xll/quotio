# CPA 筛选与总览 UI 规范对齐

## 依据

- `docs/standards/DESIGN_FOUNDATIONS.md`：原生控件优先、语义颜色、外层结构卡与内嵌表面、数字等宽和无障碍。
- `docs/standards/DESIGN_COMPONENTS.md`：系统按钮与选择器保持自身样式，卡片复用项目令牌，微型状态标签使用胶囊几何。

## 页面调整

- 筛选标题、已选条件数量、重置和说明集中在标题行。
- 时间、提供商、模型、账号来源、API 密钥、结果完整展示，采用等宽三列／两列布局；极窄容器回退单列。
- 字段标签独立置于原生控件上方，搜索入口使用原生按钮和输入框，选择菜单继续由系统 Menu、Picker 管理。
- 共用菜单明确为内部 Picker 指定 `inline` 样式，提供商、结果、图表分组与指标直接展示选项，避免原生样式推断产生多余的子菜单；系统选中标记与键盘交互继续保留。
- 图表分组与指标继续位于同一筛选卡底部，用量分布没有重新引入分段选择。
- macOS 26 使用系统 `buttonSizing(.flexible)` 填满字段宽度；较早系统保留原生控件的尺寸和行为。
- 总览归为一张结构卡，主要指标使用 `quotioInsetCard`；辅助指标与主要指标共享列宽和阅读顺序。
- 主要数字使用系统主文本色和等宽数字，不再以多种浅色填充数字；大窗口四列，小窗口两列。
- “更多指标与统计口径”使用有文字的原生按钮，替代辅助指标旁的省略号入口。
- 历史覆盖范围在卡片底部保留简短摘要，详细说明可点击展开；不完整范围的 `≥`、未知指标的 `—` 继续保留。
- 精确数值增加复制、悬停提示和无障碍朗读支持。新增字符串包含英文、简体中文、繁体中文。

## 实现范围

- `CPAUsageFilterBar.swift`：筛选和图表控件。
- `CPAUsageAdaptiveGrid.swift`：不复制控件树、不回写几何状态的等宽布局，以及原生字段组合。
- `CPAUsageOverviewSection.swift`：从原统计组件分离的总览、辅助指标与范围说明。
- `CPAUsageStatisticsView.swift`：组合以上独立组件。

## 筛选卡折叠优化

- 仪表盘使用原生 `DisclosureGroup`，六项筛选和两项图表设置统一展开、收起。
- `dashboard.cpaFiltersExpanded` 通过 `AppStorage` 保存展开偏好，首次默认展开；重置条件、刷新及重新进入页面不会修改该偏好。
- 标题行始终保留已选数量、重置及说明；重置只恢复数据查询范围，不修改展开状态。
- 收起时保留时间范围及最多两项主要条件，其他条件独立显示“另 N 项”；完整条件可通过悬停提示和无障碍朗读获取。
- 自定义日期摘要与展开字段共用精确到时刻的文案，后台更新缺少选项时仍保留当前选择。
- 旧版累计接口始终保留不支持筛选的说明，禁用条件与重置操作，展开箭头仍可使用。
- 仅仪表盘保存折叠偏好；请求明细和费用页面继续复用完整筛选栏。
- 新增 `CPAUsageFilterCard.swift` 负责卡片、共享标题及条件摘要；没有新增统计请求或改变统计计算。

### 折叠优化验证

- 最终 Debug 构建成功，新增文案包含英文、简体中文和繁体中文。
- 离屏渲染检查了 780、520、400 pt 内容宽度、深浅色及展开／收起状态，并补充无筛选与旧版接口状态，共 16 份预览。
- 780 pt 样例收起后总览上移 142 pt；400 pt 长名称与自定义日期样例没有挤掉其他条件数量提示。
- 检查了状态绑定：展开偏好不进入统计查询键；重置操作只修改 `selection`，不会覆盖展开偏好。
- 预览使用生产 SwiftUI 组件和构造数据，不读取用户的应用窗口；未在运行中的 Quotio 内进行点击或重启验收。
- 预览及脚本：`work/ui-design/dashboard-filter-collapse-2026-09-07/`。

## 验证

- Debug 构建成功，构建时关闭自动字符串提取，已有文案没有被重新整理或改写。
- 使用生产 SwiftUI 组件、项目颜色令牌与字符串目录，在离屏 NSHostingView 中生成六份 PNG。
- 验证 780、520、400 pt 内容宽度及深浅色模式。400 pt 样例包含自定义日期、长提供商与模型名、五个已选条件、覆盖不完整及未知指标。
- 已逐一检查预览，无控件越界、数字裁切或孤立的指标末行。
- 预览使用构造数据，不读取或操作用户的 Quotio 窗口；此次未执行实际点击验收。
- 预览及渲染脚本保存在 `work/ui-design/dashboard-cpa-ui-2026-09-07/`。

```sh
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DebugDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO build
```
