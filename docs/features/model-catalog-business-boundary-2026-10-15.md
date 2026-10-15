# 模型目录读取与 Pi 路径归位：第三轮第五批

日期：2026-10-15。实施依据：[业务边界审计与后续方案](business-boundary-audit-third-round-plan-2026-10-15.md)。本批围绕仪表盘、客户端配置与 Pi 实际共用的模型读取能力，消除为只读目录构造配置写入服务的绕行；将 Pi 本地路径契约归客户端接入。按业务边界验收，不以文件行数或类型数量作为拆分收益。

## 业务归属与调用入口

| 能力 | 当前维护位置 | 保留边界 |
|---|---|---|
| 模型请求传输 | [ModelCatalogClient.swift](../../Quotio/Infrastructure/Networking/ModelCatalogClient.swift) | 只构造并发送原 `/models` 请求，保留 Bearer、十秒超时及现有代理工厂；不解析、筛选、补模型、缓存或重试 |
| 实时目录、候选与连接探测 | [AgentModelCatalogService.swift](../../Quotio/Shared/ModelManagement/Services/AgentModelCatalogService.swift) | 三种读取语义成组维护；输入为明确端点与客户端密钥，不持有配置写入服务、页面状态或 Task |
| 目录单次加载事务 | [DashboardModelCatalogLoader.swift](../../Quotio/Shared/ModelManagement/Services/DashboardModelCatalogLoader.swift) | 完整 Loader 归共享模型目录，继续先取得本轮客户端 key，检查取消后读取模型；世代和提交仍归 QuotaViewModel |
| 配置服务兼容入口 | [AgentConfigurationService.swift](../../Quotio/Infrastructure/AgentClients/AgentConfigurationService.swift) | 原三个读取方法名称及签名不变，转发共享读取业务；原配置解析、格式规则、写入、备份、私有依赖和 actor 不迁移 |
| 配置页调用 | [AgentSetupViewModel.swift](../../Quotio/BusinessModules/AgentConfiguration/ViewModels/AgentSetupViewModel.swift) | 三个读取入口直接使用共享业务；原表单状态、Task、互斥、回填、失败兜底和保存调用仍在原宿主 |
| Pi 保存前目录查证 | [PiAgentConfigurationService.swift](../../Quotio/Infrastructure/AgentClients/PiAgentConfigurationService.swift) | 只替换目录读取入口；原安装、备份、安装后重读和双文件写入回滚不变 |
| Pi 本地路径契约 | [PiSessionPaths.swift](../../Quotio/Infrastructure/AgentClients/PiSessionPaths.swift) | 原路径展开、agent 目录和会话根三方法整体迁移；不创建目录、不扩大扫描、不读取凭据 |
| Pi 统计时间解释 | [PiClientUsageSource.swift](../../Quotio/BusinessModules/Analytics/ClientCalls/Services/ClientUsage/PiClientUsageSource.swift) | timestamp 同名扩展留 Analytics，继续使用原 CallAnalyticsClock；显式 nonisolated 保留同步后台读取边界 |

原 Dashboard Loader 文件位置已移除，原类型名和调用方不变；其两个闭包没有另拆服务。新增读取能力为无存储类型，不引入共享会话、后台任务或第二份模型缓存。工程仍为单一应用 Target，文件系统同步组自动纳入新位置，不修改工程设置或依赖锁定。

## 三种读取语义和所有权

- **实时目录**：仍仅接受 HTTP 200 与合法目录正文；空列表如实返回，不补内置模型，不修改提供商，不排序或去重。传输及解析错误继续抛给原调用方。
- **配置候选**：先成功解析目录，再使用原 ModelCatalog 投影；缺少 owned_by 时继续按原规则映射为 openai。逐次查询 Copilot 可用模型，只有非空证据才过滤 github-copilot 候选；空证据保留原候选，其他提供商、响应顺序和重复项不变。静态兜底仍在原 ViewModel，不进入实时读取业务。
- **连接测试**：仍以 HTTP 200 判断连接成功；正文不是模型目录时也可以成功，只不填 modelResponded。非 200 优先呈现原 error.message，否则保留 HTTP 状态文案；传输失败和取消继续返回原失败结果及 nil 延迟，不改成向页面抛出目录解析错误。

读取方法显式 `@concurrent`，无状态传输及解析在通用执行器执行；配置 actor 与原 ViewModel 继续提交配置和页面状态。原方法没有依赖 actor 串行区的读取共享可变状态，本批不新增可变存储或 Task，不放宽 private(set) 或其他访问权限。旧 testConnection 的 agent 参数保留兼容，原实现本来没有使用该值；页面仍保留 selectedAgent 非空保护。

Loader 保留三处取消屏障、原管理客户端释放及客户端 key 选择；未配置客户端 key 时继续传空认证值，管理密钥不能作为模型认证回退。原 QuotaViewModel、所有扩展及 API Key 会话提交不变。

Pi 自动配置仍在原位置重新读取候选并验证所选模型；不能以其他客户端静态兜底列表证明 Pi 模型可用。安装前备份、安装后重读、settings.json 与 models.json 的共同提交和失败恢复全部保留。三个路径方法正文逐字迁移，环境变量优先级、波浪线／相对路径处理、去重排序、默认目录以及各业务原扫描范围不变；工作区 Pi Provider 没有纳入这次改动。

## 精确增量与测试归属

本轮快照 `/tmp/quotio-model-catalog-boundary-before-20261015` 保存 694 个文件、完整副本与 SHA256。以快照核对本批增量，不将 HEAD 的历史未提交改动计入本批，没有回退、暂存或提交已有变更。

四个原源码文件只改必要读取入口、路径归属和中文边界注释；完整配置 actor 的其余成员、Pi 事务方法、ViewModel 字段与任务、PiClientUsageSource 结构正文保持原样。新增目录与传输能力没有状态宿主；Pi 时间解释仅显式恢复原 nonisolated 隔离。维护索引及第三轮计划同步更新，历史实施报告保留当时事实。

原 114 个 Swift 测试文件全部字节保留。其中 [DashboardModelCatalogLoaderTests.swift](../../QuotioTests/Shared/ModelManagement/DashboardModelCatalogLoaderTests.swift) 从 Dashboard 整体归共享模型业务；类名与用例名不变。仅新增 [AgentModelCatalogServiceTests.swift](../../QuotioTests/Shared/ModelManagement/AgentModelCatalogServiceTests.swift) 的九项离线行为回归，当前共 115 个 Swift 测试文件。

新增测试通过实际 URLSession 和已有 URLProtocol 夹具验证请求和响应策略；使用独立无效域名、临时会话及内存 Copilot 可用性，不查询真实 Copilot 账号，不写客户端配置。没有添加逐文件镜像测试或为 Pi 回滚新增生产测试钩子。

## 构建与必要定向回归

首轮构建发现 timestamp 移入跨文件扩展后，被模块默认 MainActor 隔离影响；已显式标注 nonisolated，恢复原非隔离枚举内的方法调用边界。解析正文和两类扫描规则不变。最终使用 QuotioPlus、Debug、macOS、CODE_SIGNING_ALLOWED=NO 构建，结果 BUILD SUCCEEDED；最终构建及测试无编译器 warning，结果包无运行时 warning。

仅逐方法指定 `-only-testing:QuotioPlusTests/<Class>/<Method>`，未运行全量测试。

| 定向范围 | 数量 | 验证重点 |
|---|---:|---|
| AgentModelCatalogServiceTests | 9 | 请求端点／认证／超时、原顺序与重复、空目录、Copilot 筛选、缺少证据、HTTP 200 非目录、HTTP／传输失败、取消、无效 URL |
| DashboardModelCatalogLoaderTests | 6 | 首次等 key、挂起时取消、旧会话迟到、空 key 与空目录、凭据失败、目录失败不自动重试 |
| ModelCatalogTests 的相关方法 | 8 | 原解析、空与错误正文、候选默认提供商和重复顺序、实时空列表、代理未运行时的错误 |
| PiCompatibilityTests 的相关方法 | 6 | 安装路径定位与环境覆盖、原生子会话、异常记录、忽略 transcript、两个读取器共用自定义目录 |
| ClientUsageIncrementalScanTests 的 Pi 方法 | 1 | Pi 原生用量来源与增量扫描不返回驻留账本记录 |
| 合计 | 30 | 全部通过，0 失败、0 跳过、0 预期失败 |

通过 xcresulttool 核对实际执行标识与选择清单完全一致。安装路径用例只验证临时目录中的二进制定位，不执行真实 Pi 安装；统计用例使用合成文件。部分原测试按生产初始化读取标准偏好或本地服务状态，不将整个定向集描述为完全隔离。

验证边界：默认代理工厂、真实 Copilot 查询和 Pi 事务按原正文／调用关系对照；没有连接真实 CPA、发起真实授权、执行 Pi 安装或写用户配置，也没有做双文件回滚故障注入或 Release 构建。双文件回滚结论是原实现完整保留，不能据此声称已实际执行失败恢复场景。

独立只读复审对照本轮副本核对传输、三种读取语义、取消、Actor 隔离、状态／任务所有权、Loader 事务及 Pi 路径和回滚，未发现本批新增可行动问题；复审没有独立运行测试，不代表整个客户端配置体系已无兼容债务。

验证材料：

- `/tmp/quotio-model-catalog-boundary-map-20261015.json`
- `/tmp/quotio-model-catalog-boundary-build-first-attempt-20261015.log`
- `/tmp/quotio-model-catalog-boundary-build-20261015.log`
- `/tmp/quotio-model-catalog-boundary-targeted-20261015.log`
- `/tmp/quotio-model-catalog-boundary-targeted-20261015.xcresult`
- `/tmp/quotio-model-catalog-boundary-test-selection-20261015.json`
- `/tmp/quotio-model-catalog-boundary-test-summary-20261015.json`
- `/tmp/quotio-model-catalog-boundary-test-results-20261015.json`
- `/tmp/quotio-model-catalog-boundary-verification-20261015.json`

第五批完成，第六批存储维护应用装配归位仍待后续实施。颜色等展示扩展没有实际混入本批模型读取与 Pi 路径范围。
