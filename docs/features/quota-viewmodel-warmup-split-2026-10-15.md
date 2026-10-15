# 预热流程分文件维护：第二轮第八批

日期：2026-10-15。本批承接[代理生命周期拆分](quota-viewmodel-proxy-lifecycle-split-2026-10-15.md)，归位预热设置、选择与执行方法，保留原状态及任务所有权。当前入口见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 实施范围

主类从 1,253 行缩减到 1,127 行，新增 `Quotio/Shared/Accounts/ViewModels/QuotaViewModel+Warmup.swift`（166 行、八个原方法），并补充详细中文边界说明。

| 迁移方法 | 内容与保留边界 |
|---|---|
| `isWarmupEnabled`、`toggleWarmup`、`setWarmupEnabled` | 原设置读取与持久化、Antigravity 限制、重复值直接返回和回调规则不变 |
| `nextDailyRunDate` | 原 `Calendar.current` 和严格晚于当前时间判定不变，相同／已过时刻继续安排到明天 |
| `warmupAccount` 的逐模型执行重载 | 原所选与可用模型交集、串行请求、取消检查、进度、逐模型状态及失败保留不变 |
| `warmupAvailableModels` | 精确账号认证查找、原模型缓存入口和返回列表排序不变 |
| `warmupAuthInfo` | 仍按提供商和精确 `quotaLookupKey` 匹配，保留非空 `authIndex` 与文件名检查，不增加邮箱回退 |
| `warmupTargets` | 原启用标识解析、Antigravity 过滤及稳定排序不变 |

以下方法与全部私有状态继续留在主类，完整正文不改：

- `restartWarmupScheduler`：原任务取消、重建计划、状态发布和等待循环。
- `runWarmupCycle`：原整轮防重、停服延期、到期筛选、逐账号调用、取消和下一次时间写入。
- 私有 `warmupAccount(provider:accountKey:)`：原账号运行集合占用与 `defer` 释放，再依次检查服务、客户端、凭据和模型后调用执行重载。
- `fetchWarmupModels`：原账号缓存、28,800 秒 TTL、成功后取时和失败返回空列表。
- `updateWarmupStatus`、`warmupStatus`、`warmupNextRunDate`：原可观察状态字典的读改写及读取。
- 原设置回调注册、停止／启动联动、全部 Task 句柄与生命周期。

## 访问范围与隔离验证入口

主类八项必要访问调整为内部可见：

| 声明 | 原因与保留边界 |
|---|---|
| `warmupSettings`、`warmupService` | 扩展只读取原依赖，仍为主类持有的 `@ObservationIgnored let`；服务实例数量不变 |
| `nextDailyRunDate`、`warmupAuthInfo`、`warmupTargets` | 主类调度和单账号入口调用迁移后的原计算／选择方法 |
| `warmupAccount` 的逐模型执行重载 | 主类在原防重入口通过后调用，私有防重入口自身不开放 |
| `fetchWarmupModels` | 展示模型选择继续经过主类原缓存读取，不复制缓存 |
| `updateWarmupStatus` | 执行扩展经主类原同步方法读改写状态，不开放私有字典或 setter |

审计时没有直接预热测试，原设置仅能读取共享标准偏好。为补充离线回归，增加以下最小测试支持：

- 既有 `warmupSettings` 只读字段改为构造注入，默认仍为 `.shared`，依赖名称、类型、所有者及实例默认值不变。没有新增存储属性或 manager。
- `WarmupSettingsManager` 构造允许注入 `UserDefaults`，默认仍为 `.standard`；共享实例继续使用默认构造。全部八个偏好键、旧格式解码、缺省值、范围限制、持久化与回调正文不变。
- 新增一个 `#if DEBUG` 缓存样本方法 `setWarmupModelCacheForTesting`，只向原缓存放入给定样本和时间，验证仍经过原生产 TTL 分支。没有新增测试存储或生产取数替代分支，Release 不含该入口。

原 252 个成员均保留；仅原设置字段与 ViewModel 初始化有上述依赖注入调整，原预热方法正文除访问权限外完全一致。新增 Debug 方法后逻辑成员为 253 个。83 个存储名称、类型、顺序及所有权、四个 Task 句柄、七个 `private(set)` 和全部可变私有存储保持原样。

## 保持的运行规则

- 调度仍先取消旧任务，间隔模式立即计划、每日模式计算下一次时间；等待最少一秒和原取消处理不变。
- 整轮和单账号防重、集合插入／移除、`defer` 及状态门槛都继续由原主类执行，不在扩展建立第二套运行标记。
- 模型缓存仍使用 `WarmupAccountKey` 隔离账号，命中条件保持 `age <= 28800`；成功后缓存原模型及元数据，失败不写入空缓存，也不增加陈旧缓存回退。
- 所选模型继续按原顺序与可用模型求交集，逐模型串行执行。单模型失败继续记录错误并执行后续模型，后续成功不会清除同轮失败；更新计划不会清除最近一次失败。
- 取消继续沿原管理请求传播，执行循环在原位置停止后续模型，并按原规则完成状态收尾；没有增加额外的会话校验、重试或取消策略。
- 原 `WarmupService` 和 Antigravity 请求体、端点回退、模型别名映射完整不变；预热仍使用显式传入的管理客户端及精确认证索引。
- 原功能、类型名称、设置共享实例、配置键、存储格式、运行时路径及 UI 布局保持原样。前十一个扩展、原服务文件及 105 个测试文件逐字节不变。

## 定向验证

新增 `QuotioTests/Shared/Accounts/QuotaWarmupTests.swift`（280 行、12 项测试）。所有预热设置使用独立 suite，客户端通过原 `LifecycleHTTPProtocol` 夹具返回人工响应，不启停真实 CPA，不使用真实预热账号，也不将预热请求发送到上游。

ViewModel 仍沿用既有 `CLIProxyManager.shared` 等基础设施构造；该原构造会读取本机管理 Keychain／端口并检查配置。因此这里隔离的是预热偏好、账号和请求，不将测试表述为整个 ViewModel 完全不触及本机基础设施。

| 新增定向范围 | 数量 | 验证内容 |
|---|---:|---|
| 旧设置与开关 | 2 | 八个旧键恢复、每账号覆盖、原范围限制、提供商限制、重复设置不重复回调 |
| 时间、目标与停服计划 | 4 | 每日严格边界、标识解析与排序、停服延期保留失败、重启调度计划与取消等待任务 |
| 精确凭据 | 1 | 同邮箱不同凭据不串号、认证索引非空及文件名 trim |
| 模型缓存 | 2 | 新鲜缓存复用、账号隔离、八小时后重新请求、元数据保留、失败与客户端取消不污染缓存 |
| 执行与取消 | 3 | 所选交集、串行端点回退、失败保留、请求挂起后取消与状态收尾、无交集不擦除旧错误 |

应用构建：`QuotioPlus`／Debug／macOS，`CODE_SIGNING_ALLOWED=NO`，结果 **BUILD SUCCEEDED**，无编译器警告。日志 `/tmp/quotio-quota-viewmodel-eighth-build-20261015.log`。

本批仅运行 **16 项定向回归，全部通过，0 失败、0 跳过**：

- `QuotaWarmupTests`：12 项。
- `ProxyStartFlowTests`：3 项，覆盖旧初始化挂起时停止重启、重复启动合并及取消传播。
- `ManagementAPIClientLifecycleTests/testStoppingCancelsPendingRequestAndNewClientCanStart`：1 项，覆盖失效旧请求和新客户端可用。

全部通过 `-only-testing` 指定，没有运行全量测试。结果包 `/tmp/quotio-quota-viewmodel-eighth-targeted-20261015.xcresult`，日志为同名 `.log`；`xcresulttool` 汇总为 `Passed`，无失败、跳过或运行时警告。

运行中的整轮／单账号防重和真实 CPA 全链路未通过本批离线用例动态触发；对应生产方法完整保留并与精确基线逐字核对，不将设置、停服和逐模型执行的测试表述为该范围的端到端覆盖。

## 完整性与维护记录

- 起始精确快照 `/tmp/quotio-quota-viewmodel-eighth-before-20261015`，覆盖 659 个原文件。
- 原方法映射与访问白名单 `/tmp/quotio-quota-viewmodel-eighth-map-20261015.json`。
- 完整性验证 `/tmp/quotio-quota-viewmodel-eighth-verification-20261015.json`：对照全部原成员，单独归一设置字段和初始化注入后正文一致；设置文件只允许声明类型、构造参数与赋值的指定调整，原键和其余全文保持一致。
- 独立只读审查：复审者直接比较精确基线，确认八个迁移方法完整正文一致、调度／防重／缓存／状态方法保持原样，18 个可变私有声明、七个私有 setter、四个 Task 句柄及所有存储的顺序不变；原服务、十一个旧扩展和原测试源码逐字节一致。生产默认设置、Debug 边界和隔离测试范围未发现本批引入的可行动问题；复审指出的存储计数和动态覆盖表述已核正。
- 存储计数核正：旧脚本将含 `!=` 的 Debug 计算属性误判为赋值，历史“84”应为 83 个原存储声明；本批没有删除状态。当前验证排除该计算属性，现行索引同步纠正，旧报告不改写。
- 现行维护索引与新增链接同步更新，第三至七批历史实施报告保留原样。
