# Monitor 运行类型按完整声明归位：第三轮第一批

日期：2026-10-15。本批拆分原 `Quotio/Shared/Accounts/Monitor/MonitorRuntime.swift`，按现有模型、保险库、世代、存储、发现和协调器的完整类型归位。当前维护入口见[源码目录规范](../SOURCE_LAYOUT.md)。

## 实施结果

原 1,110 行合集文件已移除，16 个现有类型分别位于原 `Shared/Accounts/Monitor` 目录的同名文件。协议默认实现与协议放在同一文件；不留下空兼容壳或复制声明。

| 类型与文件 | 原职责与保留边界 |
|---|---|
| [MonitorAccountSource](../../Quotio/Shared/Accounts/Monitor/MonitorAccountSource.swift)、[MonitorAccount](../../Quotio/Shared/Accounts/Monitor/MonitorAccount.swift) | 原账号来源、优先级、本地化键、稳定身份、权限、禁用状态和显示回退 |
| [MonitorRefreshIssue](../../Quotio/Shared/Accounts/Monitor/MonitorRefreshIssue.swift)、[MonitorRefreshBatch](../../Quotio/Shared/Accounts/Monitor/MonitorRefreshBatch.swift) | 原失败观察与批次传递值，编码、时间及精确账号错误不变 |
| [MonitorCredentialStore](../../Quotio/Shared/Accounts/Monitor/MonitorCredentialStore.swift)、[MonitorOAuthCredential](../../Quotio/Shared/Accounts/Monitor/MonitorOAuthCredential.swift) | 原凭据协议、默认拒绝 CAS 实现和凭据值，保留完整签名与相等性比较 |
| [MonitorCredentialVault](../../Quotio/Shared/Accounts/Monitor/MonitorCredentialVault.swift) | 原 actor、共享实例、同步后端、读取世代和嵌套 Backend；CAS 不增加挂起点 |
| [MonitorStateRevision](../../Quotio/Shared/Accounts/Monitor/MonitorStateRevision.swift) | 原锁、全局世代与逐账号版本，校验和提交仍处于原同步临界段 |
| [MonitorMetadataStore](../../Quotio/Shared/Accounts/Monitor/MonitorMetadataStore.swift) | 原私有 Payload、默认路径、旧 Gemini 条目迁移、禁用和删除持久化 |
| [MonitorSnapshotStore](../../Quotio/Shared/Accounts/Monitor/MonitorSnapshotStore.swift) | 原嵌套 Payload／Snapshot、旧快照兼容、额度与错误共同原子提交、精确账号删除 |
| [MonitorAccountDiscovery](../../Quotio/Shared/Accounts/Monitor/MonitorAccountDiscovery.swift) | 原依赖、发现顺序、来源优先级、Codex 分组和禁用状态回填，原挂起点不重排 |
| [MonitorRefreshCoordinator](../../Quotio/Shared/Accounts/Monitor/MonitorRefreshCoordinator.swift) | 原 revision、Flight、Task、共享等待、失败退避、完成版本、快照收尾与 Debug 钩子 |
| [MonitorCredentialAvailability](../../Quotio/Shared/Accounts/Monitor/MonitorCredentialAvailability.swift)、[MonitorRuntimeError](../../Quotio/Shared/Accounts/Monitor/MonitorRuntimeError.swift) | 原可用性语义及错误 case／文案，不把取数失败等同于凭据删除 |
| [SecureAtomicFileWriter](../../Quotio/Shared/Accounts/Monitor/SecureAtomicFileWriter.swift)、[MonitorIdentity](../../Quotio/Shared/Accounts/Monitor/MonitorIdentity.swift) | 原文件权限、符号链接拒绝、临时替换，以及指纹、路径、JSON／JWT 辅助规则 |

新增文件均补充中文职责与边界说明，总计 1,250 行（包含文件头、注释及必要辅助适配），最大文件为 `MonitorAccountDiscovery.swift`，297 行。分文件没有增加新的服务实例、状态容器或任务，也没有隔离编译模块；应用继续使用原单一 Target。

## 唯一辅助适配

原文件末尾的私有 `String.nilIfBlank` 同时服务账号模型和发现逻辑，迁移后不能直接跨文件使用。将同一规则等价归入既有 `MonitorIdentity.nilIfBlank(_:)`：

- 原可选链的 `nil` 输入仍返回 `nil`。
- 非空输入仍按 `.whitespacesAndNewlines` 裁剪，裁剪后为空返回 `nil`，否则返回裁剪结果。
- 仅替换 `MonitorAccount` 和 `MonitorAccountDiscovery` 六处调用；保留原 `??` 与 `||` 的短路顺序及回退值。
- 不新增全局 String 扩展，不改变稳定身份、路径或凭据发现策略，不开放任何原可变私有存储或 setter。

除此之外，类型方法、字段、隔离及流程正文完整迁移，没有将功能修复混入本批目录调整。

## 不变约束与完整性核对

本轮基线为 `/tmp/quotio-monitor-runtime-split-before-20261015`，记录 657 个文件哈希。工作区此前已有未提交改动，本批按该快照核对自身增量，没有回退、暂存或提交历史改动。

- 16 个原类型及一个凭据协议默认扩展各保留一份。13 个完整类型加协议默认扩展，共 14 个声明正文逐字一致；另外三个声明只涉及上述空白辅助适配。
- 全部 `actor`、`nonisolated`、`Sendable`、`Codable`、嵌套类型、共享实例、存储属性、Task 和 Debug 钩子随原类型完整保留。
- 协调器的 `issues private(set)` 保持原声明；没有为跨文件访问扩大原字段或方法权限。
- 保险库的原凭据比较、同步 CAS、读取世代更新保持同一 actor 临界段，没有插入 `await`；删除／重授权期间的拒绝旧刷新写回规则不变。
- `MonitorStateRevision` 的锁与逐账号排序、快照编码和安全原子写入、发现与禁用回填顺序均不变。
- 同提供商同世代的共享 Flight、各等待者的世代复核、旧任务不得清除新任务、失败退避及手动绕过退避保持原样。
- 所有既有配置路径、序列化字段、旧快照兼容、权限和错误文案保留。未修改其他生产源码、工程文件、资源或 SwiftPM 锁定文件。
- 原 111 个测试文件不改动；仅新增两项模型工厂回退测试。同步更新当前维护索引，历史实施与审计报告不改动。

独立只读复审使用同一快照，确认声明迁移、辅助等价性及工程自动纳入，没有发现本批引入的新回归。复审未扩大到历史功能及真实账号端到端行为。

## 构建与必要定向回归

构建：`QuotioPlus`、Debug、macOS、`CODE_SIGNING_ALLOWED=NO`，结果 `BUILD SUCCEEDED`。Xcode 使用文件系统同步目录，16 个新文件自动纳入应用 Target，不需要手动改工程引用。

| 定向范围 | 用例数 | 验证重点 |
|---|---:|---|
| `MonitorRuntimeTests` 中明确选出的相关方法 | 22 | 账号来源／身份／优先级、元数据与旧格式、快照／失败恢复、启动与刷新交错、精确账号删除、共享请求、退避和符号链接拒绝 |
| `MonitorUpstreamCompletionTests` 中明确选出的相关方法 | 5 | 独立账号命令排序、移除身份过滤、所有共享等待者拒绝旧世代、旧快照不能覆盖删除／重加、内存后端 CAS 不能复活已删凭据或覆盖重授权 |
| [MonitorAccountNormalizationTests](../../QuotioTests/Shared/Accounts/MonitorAccountNormalizationTests.swift) | 2 | 通过真实 `make`／`makeLegacy` 工厂验证空值、空串、空白、裁剪、显示回退与稳定身份 |
| 合计 | 29 | 全部通过，0 失败、0 跳过、0 预期失败 |

未运行全量测试，也没有整类执行含其他提供商、硬件保险库和回调服务测试的 `MonitorRuntimeTests`。结果包没有运行时 warning，构建与测试没有编译器 warning。测试宿主日志中的 App Intents／linkd 系统服务连接提示不属于本批测试失败。

隔离与验证边界：新增两项模型测试完全使用内存样本；CAS 用例注入原内存后端，存储用例使用临时文件。本批未执行真实 CPA／IDE 启停或真实账号授权。**部分既有 bootstrap 测试的 `makeIsolatedCoordinator` 只替换 vault 与 metadata，仍走默认账号发现，可能读取本机环境、账号文件及钥匙串来源，不能将全部 29 项表述为完全隔离。** 该夹具在本批快照中已存在，本批没有扩大测试钩子或改变发现行为；真实账号、平台网络和 Release 配置未作为本次回归结论。

验证材料：

- `/tmp/quotio-monitor-runtime-split-build-20261015.log`
- `/tmp/quotio-monitor-runtime-split-targeted-20261015.log`
- `/tmp/quotio-monitor-runtime-split-targeted-20261015.xcresult`
- `/tmp/quotio-monitor-runtime-split-test-summary-20261015.json`
- `/tmp/quotio-monitor-runtime-split-test-selection-20261015.json`
- `/tmp/quotio-monitor-runtime-split-map-20261015.json`
- `/tmp/quotio-monitor-runtime-split-verification-20261015.json`

后续维护应按类型定位，不重新集中到合集，也不借分文件新建保险库／协调器或改写 CAS、快照和共享等待协议。
