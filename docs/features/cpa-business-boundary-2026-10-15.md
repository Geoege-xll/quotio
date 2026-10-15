# CPA 公共业务能力归位：第三轮第三批

日期：2026-10-15。实施依据：[业务边界审计与后续方案](business-boundary-audit-third-round-plan-2026-10-15.md)。本批纠正已确认的依赖方向，以真实使用方和业务契约为边界，不以文件行数或一类型一文件作为目标。

## 实施结果与维护入口

| 能力 | 当前维护入口 | 业务边界 |
|---|---|---|
| 账号权重与兼容错误 | [CPAAccountRoutingRules.swift](../../Quotio/Infrastructure/CPA/Configuration/CPAAccountRoutingRules.swift) | `CPAAccountWeight` 与 `CPASettingsValidationError` 成组维护，供管理 API、共享提供商与账号编辑使用；不依赖设置草稿或 View／Binding |
| 路由策略规范化与展示 | [CPARoutingPolicy.swift](../../Quotio/Shared/UI/CPA/CPARoutingPolicy.swift) | 完整保留 `CPARoutingStrategy`；Settings 与 Dashboard 实际共用，选项、别名与显示属于同一能力，不添加转发层 |
| 路由公共查询结果 | [CPAUsageRoutingReport.swift](../../Quotio/Shared/Analytics/CPA/Models/CPAUsageRoutingReport.swift) | 完整保留 `CPARoutingSnapshot`，共享事件库、账本和消费服务不再使用定义在 Dashboard 的类型 |
| 文本数值输入 | [CPASettingsNumberRow.swift](../../Quotio/Shared/UI/Controls/CPASettingsNumberRow.swift) | 原控件整体迁入已有共享控件目录，继续供设置高级选项与账号权重编辑使用 |

原 Settings 控件文件已移除。原 [CPARequestSettings.swift](../../Quotio/BusinessModules/Settings/Models/CPARequestSettings.swift) 仅保留设置专用草稿及其精确补丁规则；原 [CPARoutingPresentation.swift](../../Quotio/BusinessModules/Dashboard/Routing/Models/CPARoutingPresentation.swift) 保留活动与展示类型。

策略的当前生产使用方只有设置与路由页面，不必把规范化和展示人为再拆成两个层级。错误类型名称虽保留 Settings 字样，但它已经是管理客户端和共享提供商共同使用的兼容契约；保留全部 case 与本地化行为，避免改名或另建错误映射。`localizedStatic()` 位于既有 Infrastructure/System/LanguageManager，不引入 Shared 或设置页面依赖。

## 保留的行为与所有权

- 五个迁移声明正文逐字一致，访问级别、类型名称、协议符合与 nonisolated 保持原样。新增详细中文注释解释职责、实际使用方及边界。
- `CPAAdvancedSettingsDraft`、`CPARoutingActivity`、`CPARoutingPresentation` 正文逐字一致；全部原调用方无需改名或增加适配。
- 账号权重的 nil、非正数、最大值、精确 Key 身份和旧配置编码不变；保留原错误 case 及本地化反馈。
- 路由策略的原始值、选项顺序、别名、规范化、未知值回退和本地化键不变；归位不写配置。
- 设置草稿、请求／日志 scope 的独立基线、读取抑制、保存锁、冻结客户端及提交完成后的确认继续留在原视图。没有修改 `ProxySettingsSection` 或账号编辑 Sheet。
- 查询按日边界、完整执行计数、有界明细与入库候选、失败与取消分类、迟到慢请求处理均由原查询实现执行，没有改写 SQL 或时间规则。
- 共享输入仍只编辑调用方的 Binding；布局、标签、帮助、可访问性标识和文本保留不变，没有新本地草稿、解析或保存。
- 路由 VM、账号卡片位置、光流身份、时钟和绘制代码均未改动；CPA 唯一消费者、账本、private(set)、状态与 Task 所有权保持原样。

本批以 `/tmp/quotio-cpa-business-boundary-before-20261015` 的 683 个文件快照为基线，不以 HEAD 上的历史未提交差异判断自身范围。已有源码只更新两个归属合集并移除一个旧控件位置；其他已有生产源码、资源、112 个测试文件、工程和 SwiftPM 锁定文件保持本轮基线内容。Xcode 继续通过文件系统同步目录自动纳入新路径；仍是同一个应用 Target，不宣称已完成编译模块隔离。

独立只读复审核对了声明正文、重复类型、真实调用方、跨文件作用域及工程纳入，未发现本批引入的可行动问题。复审范围限于本批归属调整，不替代其他业务或全部分层问题的重新审计。

## 构建与必要定向回归

构建使用 `QuotioPlus`、Debug、macOS、`CODE_SIGNING_ALLOWED=NO`，结果 `BUILD SUCCEEDED`。测试逐方法指定 `-only-testing:QuotioPlusTests/<Class>/<Method>`，未运行全量测试，没有为声明迁移添加镜像测试。

| 定向范围 | 用例数 | 验证内容 |
|---|---:|---|
| CPARequestSettingsTests 的相关方法 | 10 | 显式 false／0、旧配置与空节点、按 scope 精确 PATCH、独立基线、负值兼容、非法数字／TTL、策略别名与未知值、旧 Key 及权重编辑身份 |
| CPASettingsInteractionTests 的相关方法 | 3 | 高级选项默认收起、展开不保存、关闭会话固定不清草稿、权重读取失败不写默认值；实际渲染原控件 |
| CPA8ProviderPatchTests 的权重方法 | 3 | 外部权重不被无关编辑覆盖、显式恢复世代、重建 Key 权重、唯一身份观察和本地写入意图 |
| CPA8ManagementAPIContractTests 的权重方法 | 2 | v8 值和精确凭据字段、错误类型、读取与保存失败不误报成功 |
| CPARoutingTests 的相关方法 | 7 | 单日计数及明细上限、同一请求多次上游执行、空快照、旧请求不能覆盖新世代、慢执行候选、失败与空结果区分、真实策略及零重试 |
| RoutingAccountPositionTests 的交替方法 | 1 | A→B→A 时真实账号锚点固定，往返光流命中实际账号连线 |
| RoutingFlowAnimationTests 的生产 Canvas 方法 | 1 | 明暗两种模式下外送与返回中途帧可见，使用原绘制器 |
| 合计 | 27 | 全部通过，0 失败、0 跳过、0 预期失败 |

实际执行标识与选择清单逐一核对。构建与测试无编译器 warning，结果包无运行时 warning。

验证边界：HTTP 用例注入离线 URLProtocol，查询与配置补丁使用合成数据和临时文件／SQLite，动画使用内存账号与 NSHostingView。既有 `CPA8ProviderPatchTests` 调用 `CustomProviderService.shared` 的只读补丁／观察方法，初始化仍可能读取标准偏好；部分路由渲染构造关闭后台服务的 QuotaViewModel，也不能据此把整个测试宿主称为完全环境隔离。本批未增加测试注入或改变原服务所有权，未以真实 CPA 请求、账号写入或 Release 配置作为验证依据。

验证材料：

- `/tmp/quotio-cpa-business-boundary-build-20261015.log`
- `/tmp/quotio-cpa-business-boundary-targeted-20261015.log`
- `/tmp/quotio-cpa-business-boundary-targeted-20261015.xcresult`
- `/tmp/quotio-cpa-business-boundary-test-summary-20261015.json`
- `/tmp/quotio-cpa-business-boundary-test-tree-20261015.json`
- `/tmp/quotio-cpa-business-boundary-test-selection-20261015.json`
- `/tmp/quotio-cpa-business-boundary-map-20261015.json`
- `/tmp/quotio-cpa-business-boundary-verification-20261015.json`

AGENTS、项目索引、目录规范、二次开发维护指南及当前方案进度已同步；历史实施报告保留当时事实。下一批账号共享能力归位仍按原方案待实施，不混入本批。
