# 工作区会话 Provider 按完整类型归位：第三轮第二批

日期：2026-10-15。本批拆分 `Quotio/BusinessModules/Workspace/Sessions/Services/WorkspaceSessionService.swift` 中的协议、IO 辅助和五个客户端 Provider；原 actor 门面继续作为会话服务入口。当前维护映射见[源码目录规范](../SOURCE_LAYOUT.md)。

## 实施结果

原文件 1,542 行，迁移后门面为 102 行；在原 `Services` 目录新增七个同名文件。八个完整声明的正文逐字一致，不按方法切开原类型，也不复制声明。

| 类型与文件 | 行数（包含说明与文件头） | 原职责与保留边界 |
|---|---:|---|
| [WorkspaceSessionService](../../Quotio/BusinessModules/Workspace/Sessions/Services/WorkspaceSessionService.swift) | 102 | 原 actor、共享实例、私有依赖和 Provider 装配；并发扫描汇总、排序、消息／删除分发及终端恢复 |
| [AgentSessionProviderProtocol](../../Quotio/BusinessModules/Workspace/Sessions/Services/AgentSessionProviderProtocol.swift) | 19 | 原 public、nonisolated、Sendable 与三个 @concurrent 异步方法契约 |
| [SessionIOUtils](../../Quotio/BusinessModules/Workspace/Sessions/Services/SessionIOUtils.swift) | 78 | 原 SQLite 列探测白名单、头尾完整行读取、UTF-8 边界、日期与 UUID 解析 |
| [ClaudeSessionProvider](../../Quotio/BusinessModules/Workspace/Sessions/Services/ClaudeSessionProvider.swift) | 269 | 原主会话与 subagents 目录、历史副本合并、消息解析及安全删除 |
| [CodexSessionProvider](../../Quotio/BusinessModules/Workspace/Sessions/Services/CodexSessionProvider.swift) | 389 | 原当前数据库优先、rollout／archive／index 补全、关系与消息读取及级联删除 |
| [OpenCodeSessionProvider](../../Quotio/BusinessModules/Workspace/Sessions/Services/OpenCodeSessionProvider.swift) | 213 | 原数据库优先、旧 JSON 回退、消息顺序、关系读取及必要重扫 |
| [PiSessionProvider](../../Quotio/BusinessModules/Workspace/Sessions/Services/PiSessionProvider.swift) | 120 | 原双目录扫描、消息父关系与会话父关系区分、显式父路径归一及删除 |
| [AGYSessionProvider](../../Quotio/BusinessModules/Workspace/Sessions/Services/AGYSessionProvider.swift) | 409 | 原摘要库、JSON、brain 与旧缓存合并，WAL 兼容、transcript 与数据库正文回退 |

八个文件合计 1,599 行，增加的是文件头、必要导入和详细中文职责／边界说明；最大文件为 AGY Provider，409 行。本批缩小单文件维护范围，没有声称总源码行数减少，也没有拆成独立编译模块。

各文件保留 Foundation；只有直接调用 SQLite API 的 IO 辅助和 Codex／OpenCode／AGY Provider 导入 SQLite3。原门面不再导入没有直接使用的 AppKit／SQLite3。没有新增依赖或工程手工引用。

## 不变约束与完整性核对

本批基线为 `/tmp/quotio-workspace-session-split-before-20261015`，包含 674 个文件哈希及原始副本。工作区此前已有未提交改动，本批以该快照核对自身增量，没有回退、暂存或提交历史改动。

- 八个顶层完整声明各保留一份，正文 SHA-256 与基线对应声明一致；没有新增适配方法或跨文件访问权限调整。
- 原 public／private／nonisolated、Sendable、嵌套类型、私有解析方法和 @concurrent 均随所属类型迁移；不扩大私有 setter，不迁移任何状态或 Task 所有权。
- 原 actor 保留 `shared`、`homeDir`、`fileManager`、Provider 字典、TaskGroup 并发和按活动时间排序。门面等待 Provider 时仍可重入，不作为全局删除锁。
- 各客户端的来源优先级、去重、父子关系识别、旧格式兼容、读取上限和失败回退全部保持原样。
- Provider 删除入口保留原重扫条件；门面的受约束删除继续依次扫描、验证观察结果、调用统一引擎，没有插入额外挂起点。
- `WorkspaceSessionSafety.swift`、关系适配、模型、ViewModel 和存储服务均未改动。原事务引擎仍执行 BEGIN IMMEDIATE、完整计划预检、同卷暂存、再次校验、SQL 修改、COMMIT 和暂存清理；失败仍执行数据库回滚及文件恢复。
- 既有配置、默认 home、客户端磁盘路径、数据库格式、恢复命令规则和错误行为不变。原 112 个测试文件不变，没有为文件迁移增加镜像测试或删除行为覆盖。
- 既有文件中仅原服务和当前维护索引（AGENTS、PROJECT、SOURCE_LAYOUT、SECONDARY_DEVELOPMENT）变化；其他生产源码、资源、工程与 SwiftPM 锁定文件均保持基线哈希。历史实施／审计报告不改动。

独立只读复审按同一快照核对声明、跨文件作用域、隔离边界及项目自动纳入，未发现本批引入的可行动问题。复审不替代对全部既有会话业务的重新审计。

## 构建与必要定向回归

构建使用 `QuotioPlus`、Debug、macOS、`CODE_SIGNING_ALLOWED=NO`，结果 `BUILD SUCCEEDED`。工程已使用文件系统同步目录，七个新文件自动纳入应用 Target，无需修改 `project.pbxproj`。

测试逐方法指定 `-only-testing:QuotioPlusTests/<Class>/<Method>`，没有整类执行混有技能测试的 `WorkspaceTests`，也没有运行全量测试。

| 选定范围 | 用例数 | 验证重点 |
|---|---:|---|
| `WorkspaceTests` 的会话相关方法 | 8 | Claude／Codex／AGY 扫描和消息、真实格式 Codex rollout 解析、OpenCode SQLite 发现及删除、Claude sidecar 和 subagents、AGY WAL 与正文回退 |
| `WorkspaceSessionRelationshipTests` 的相关方法 | 7 | 来源身份、普通 fork、旧数据库列兼容、rollout 关系补全、Claude 路径冲突、AGY 多来源去重及跨来源级联 |
| `WorkspaceSessionSafetyTests` 的相关方法 | 12 | Pi 消息与会话父关系、冻结约束后新后代、SQLite 锁与 SQL 失败回滚、不安全后代、路径／符号链接／数据库边界、中文大 JSONL、OpenCode 与 AGY 三级删除 |
| `WorkspaceSessionPerformanceTests` 的删除方法 | 1 | Provider 等待 SQLite 写锁期间 MainActor 心跳仍能响应，覆盖 @concurrent 未丢失 |
| `WorkspaceStorageSafetyTests` 的真实会话集成方法 | 2 | AGY 预览与清理逻辑身份一致、最终扫描后插入子节点仍保留真实数据库树 |
| 合计 | 30 | 全部通过，0 失败、0 跳过、0 预期失败 |

测试实际执行标识与选择清单逐一核对，未混入其他用例。构建和测试无编译器 warning，结果包无运行时 warning；宿主的 App Intents／linkd 系统服务连接提示不属于测试失败。

所选行为用例使用显式临时 home、人工会话文件及临时 SQLite 数据库，删除和回滚只以这些夹具为验证对象。没有调用终端恢复，也未以真实账号／客户端数据或 CPA 启停作为验证依据；本次结论限于 Debug 构建、所选离线回归及源码完整性，不涵盖真实客户端端到端或 Release 配置。

验证材料：

- `/tmp/quotio-workspace-session-split-build-20261015.log`
- `/tmp/quotio-workspace-session-split-targeted-20261015.log`
- `/tmp/quotio-workspace-session-split-targeted-20261015.xcresult`
- `/tmp/quotio-workspace-session-split-test-summary-20261015.json`
- `/tmp/quotio-workspace-session-split-test-tree-20261015.json`
- `/tmp/quotio-workspace-session-split-test-selection-20261015.json`
- `/tmp/quotio-workspace-session-split-map-20261015.json`
- `/tmp/quotio-workspace-session-split-verification-20261015.json`

后续按客户端类型维护 Provider，公共 IO 规则仍限于工作区业务；不要重新集中到合集，也不因分文件改变关系来源或将删除事务拆成多个异步提交段。
