# 存储维护应用装配归位：第三轮第六批

日期：2026-10-15。实施依据：[业务边界审计与后续方案](business-boundary-audit-third-round-plan-2026-10-15.md)。本批纠正跨客户端统计、调用分析、CPA 和缓存的应用维护装配归属；按实际依赖方向组织，不以减少代码行数拆分事务。

## 业务归属与调用方向

原 Settings 的 StorageDataDestination.swift 同时包含应用级 AnalyticsMaintenanceCoordinator 和读取多个业务环境的目的地。它们一起归位到 [App/Composition/AnalyticsMaintenanceComposition.swift](../../Quotio/App/Composition/AnalyticsMaintenanceComposition.swift)，继续成组维护，两个类型的声明、成员及正文保持原样，仅增加中文职责说明。

| 入口 | 当前职责及保留边界 |
|---|---|
| [QuotioApp.swift](../../Quotio/App/QuotioApp.swift) | 继续通过原 State 唯一持有协调器，窗口环境注入及统计实例不变；普通设置和日志兼容入口均提供原维护目的地 |
| [SettingsScreen.swift](../../Quotio/BusinessModules/Settings/Views/SettingsScreen.swift) | 保留原导航栈、path、search、modeFocusRequest 及日志定位行为；只在原 storageData 分支调用 App 注入的延迟目的地 |
| AnalyticsMaintenanceCoordinator | 原 MainActor／Observable、private(set) service、幂等 configure 和四组维护闭包完整保留 |
| StorageDataDestination | 原四个环境读取、等待视图、服务视图及 task 配置完整保留，作为 App 目的地装配壳 |
| [StorageMaintenanceService.swift](../../Quotio/BusinessModules/Settings/Storage/Services/StorageMaintenanceService.swift) | 仍归设置维护业务，接收原应用回调、持有原 busy 和五个私有 setter，不创建其他统计对象 |
| [StorageMaintenanceStore.swift](../../Quotio/BusinessModules/Settings/Storage/Services/StorageMaintenanceStore.swift) | 原同库清理、墓碑、配置保留及空间整理事务不变，不因使用 SQL 下沉为通用存储 |
| [StorageDataScreen.swift](../../Quotio/BusinessModules/Settings/Storage/Views/StorageDataScreen.swift) | 原设置页面，只消费同一服务，保留确认、按钮、返回保护和异步操作入口 |

SettingsScreen 新增一个私有目的地闭包及接收 ViewBuilder 的初始化器；类型本身保持非泛型，所有原 State 仍归原类型。只在这个固定、低频的导航边界用 AnyView 包装目的地，不在列表项中扩散类型擦除。两个实际调用点已由 App 明确注入；没有提供会另造服务的默认实现，后续新增设置入口同样必须由 App 提供目的地。

设置业务不再引用 App 协调器或两个统计 ViewModel，也不负责跨业务维护装配。闭包只构造原 App 目的地；目的地继续从原窗口环境读取同一协调器、QuotaViewModel 和统计实例。配置仍在首次进入目的地的原 task 执行，没有提前到 App 启动、设置根页初始化或 body，也没有新增环境键、状态容器或后台任务。

## 所有权与维护顺序

- QuotioApp 的协调器 State、窗口 environment、两个统计模型及任务所有权保持原样。原 configure 的 service == nil 守卫保留，目的地关闭、重建或语言切换不能产生第二个服务或维护锁。
- 原服务的 snapshot、isBusy、errorKey、messageKey、lastClearResult 五个 private(set) 和协调器 service 的 private(set) 均保留；没有放宽任何访问权限。
- 准备仍依次暂停客户端用量、调用分析和 CPA；CPA 仍等待已经消费的在途响应入库，保留原维护屏障及取消规则。
- 原服务仍先等待准备、检查取消，再执行 Store 原事务；清理选定模块和迁移标记在同一事务中提交，失败整体回滚。
- 删除提交后，仍依次尝试所有选定模块的失效和重读；一个模块失败不能跳过其余模块。首个错误在全部尝试后报告，提交后刷新失败继续明确显示“数据已清除”。
- 原 defer 仍恢复三个采集宿主，再释放 busy；缓存清理与空间整理的暂停、读取概况和恢复顺序也不变。原页面任务、取消传播、后台循环和唯一 CPA 消费器没有迁移。

本批不修改数据库格式、偏好键、配置、缓存位置或用户数据，不将现有跨层债务扩展为新的模块化工程。

## 精确增量与测试归属

基线 `/tmp/quotio-storage-composition-before-20261015` 保存 699 个文件、完整副本和 SHA256；以该快照核对本批增量，不以 HEAD 上的历史未提交差异判断范围。没有回退、暂存或提交已有改动。

生产变更仅包括：两个原类型所在文件整体归位、SettingsScreen 的目的地注入，以及 App 两个现有调用点。原协调器与目的地正文逐字一致；App 原状态／环境区块以及设置原导航状态完整保留。Service、Store、Screen、统计 ViewModel、引擎、账本、CPA 消费器、资源、工程和依赖锁定文件均与本轮基线一致。

原 [AnalyticsMaintenanceLifecycleTests.swift](../../QuotioTests/App/Composition/AnalyticsMaintenanceLifecycleTests.swift) 整体归 `QuotioTests/App/Composition`，验证跨业务应用维护编排，类名、用例名和文件字节不变。全部 115 个原 Swift 测试文件保留内容，本批没有新增测试或生产测试钩子，不为目录移动编写镜像用例。

AGENTS、源码归属规范、项目入口、二开指南和第三轮计划同步更新；历史实施报告保留原事实。工程仍通过文件系统同步组纳入源码与测试，保持原单一应用 Target。

## 构建与必要定向回归

QuotioPlus、Debug、macOS、CODE_SIGNING_ALLOWED=NO 构建结果为 BUILD SUCCEEDED。仅逐方法指定 `-only-testing:QuotioPlusTests/<Class>/<Method>`；17 项实际执行标识与选择清单一致，全部通过，0 失败、0 跳过、0 预期失败。最终构建和测试没有编译器 warning，结果包没有运行时 warning。

| 定向范围 | 数量 | 实际验证 |
|---|---:|---|
| AnalyticsMaintenanceLifecycleTests 的维护方法 | 7 | 维护中进入／离开页面的恢复意图、协调器重复配置复用原服务、删除后一个重读失败仍失效其他模块、调用页恢复、挂起手动刷新、在途 CPA 响应正常入库后屏障才通过 |
| StorageMaintenanceTests 的清理与服务方法 | 10 | 三个模块范围与配置保留、迁移墓碑、整体回滚、空间整理、准备与提交／失效／恢复顺序、准备失败恢复、提交后错误反馈、busy 拒绝重入及缓存保留事实 |
| 合计 | 17 | 全部通过，未运行全量测试 |

使用原临时数据库、合成客户端数据和可控内存队列，不连接真实 CPA 或删除用户统计。协调器重建场景的原测试实际通过两次 configure 验证服务身份；没有新增导航自动化、实际窗口关闭／语言切换的运行测试或 Release 构建。目的地闭包与环境传递通过构建及静态复审核对，不把已有模型级生命周期测试描述成真实 UI 操作覆盖。

独立只读复审对照本轮副本检查依赖方向、延迟闭包、固定目的地类型、环境与状态身份、维护锁、配置时机及事务顺序，未发现本批新增可行动问题；复审未独立运行构建或测试。

验证材料：

- `/tmp/quotio-storage-composition-map-20261015.json`
- `/tmp/quotio-storage-composition-build-20261015.log`
- `/tmp/quotio-storage-composition-targeted-20261015.log`
- `/tmp/quotio-storage-composition-targeted-20261015.xcresult`
- `/tmp/quotio-storage-composition-test-selection-20261015.json`
- `/tmp/quotio-storage-composition-test-summary-20261015.json`
- `/tmp/quotio-storage-composition-test-results-20261015.json`
- `/tmp/quotio-storage-composition-verification-20261015.json`

第三轮计划中的六批均已完成。额度呈现、工作区模型等后置候选继续保持审计状态，不自动开始下一批改造。
