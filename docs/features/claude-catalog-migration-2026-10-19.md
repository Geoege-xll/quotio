# Claude Code 目录菜单统一迁移

## 当前行为与业务边界

本轮接替此前“只筛选候选、仍保留旧菜单”的行为。配置页统一使用“应用”保存，备份与旧配置迁移在原保存事务内自动完成：当前服务确认的模型进入生效菜单，未确认旧引用退出生效配置，原文件完整保存在备份中。没有增加精选卡片、名称输入框、内部 Tab 或后台轮询。

- `Shared/AgentClients/Models/Claude/ClaudeConfigurationPlan.swift` 是唯一纯值计划，处理角色、默认、子代理、菜单、后台模型、模型设置与能力关联、已有 fallback 和 advisor 引用，并提供迁移报告。
- 原 `AgentSetupViewModel` 继续持有配置、目录来源、请求世代及任务；原 `AgentConfigurationService` 继续持有最新文件读取、备份、原子提交及恢复事务。`ShellProfileManager` 仍唯一负责 Shell 管理段。
- `AgentConfiguration.claudeCatalogManaged` 是原草稿中的可选兼容字段，旧 Codable 缺省为 false。生产 Claude 配置入口明确开启本轮治理；旧草稿解码、非代理恢复、其他客户端和未接管的底层兼容调用不自动清理文件。磁盘根 `quotioClaudeCatalog` 使用版本 1 和服务指纹标记；完整旧菜单嵌套标记兼容读取并在合法保存时迁到根。账号联动只同步已接管且来源匹配的文件，详见[系统重构](claude-configuration-system-refactor-2026-10-19.md)。
- 未迁移的真实配置不会因为启动应用或读取目录而被擅自重写；第一次应用需在新版配置页保存。现有类型名称、私有 setter、状态、单例和 Task 所有权保持不变。

## 统一迁移与菜单输出

1. 完整 ID 优先且大小写敏感；只对已知旧 `codex/`、`antigravity/`、`zhipu/` 命名，在去前缀后的 ID 精确存在当前目录时迁移。合法完整前缀不剥离，不替换缺失版本。
2. 角色必须最终解析到已确认具体 ID；循环角色与未映射角色不能当成可用模型。Default、已启用角色和指定子代理不满足该条件时，在原表单重选后才能提交。可选 Fable 清空后，旧映射及已知名称／说明也退出生效 env。
3. 菜单设置 `replaceBuiltInOptions=true`，依次提供已确认的角色、有效旧条目与尚未覆盖的当前目录模型。CLI 原生 Default 保留，其回退变量写入明确确认的实际目标；不能只设置顶层 `model` 就假定 Default 相同。
4. 有效旧条目保留标题、顺序及未知字段。固定角色的说明始终按当前已确认请求重新生成，包含该角色的 `[1m]` 声明，避免旧说明与实际请求错配；具体模型的账号说明继续保留。同 ID 不同账号说明继续保留，只有内容完全相同的行合并。未确认条目完整保存在原始备份中，不再进入生成菜单。详见[角色说明与 1M 回显修复](claude-role-menu-synchronization-2026-10-19.md)。
5. `[1m]` 声明独立于基础 ID，保留原角色引用和上下文声明。目录确认只证明身份，不宣称已验证真实上游的 1M 能力。
6. `modelSettings`／能力关联的当前 ID 设置优先，旧冲突键撤下并进入原始备份，避免下次读取继续制造同一冲突。未识别的能力片段与有效对象内部未知值保留。已有 fallback／advisor 的失效引用同样收敛；确认有效的原生角色引用保持继承，不固定为本轮型号。
7. Default、inherit、best、opusplan 等 CLI 保留指令不作为普通网关型号自动追加。未知菜单结构、已知模型字段出现不支持的类型、失败／空目录都禁止覆盖，不视为所有模型退役。
8. 严格菜单统一关闭网关发现，原发现控件不再在该模式显示。没有写入会影响命令行、技能和子代理的 `availableModels` 强制列表，不触碰管理策略。

原生菜单替换、网关发现及缓存规则参见 [Claude 官方网关契约](https://code.claude.com/docs/en/llm-gateway-protocol#model-discovery)；Default 与顶层 model 的差异参见[官方模型说明](https://code.claude.com/docs/en/model-config#set-a-default-model-for-new-sessions)。不支持 `modelPicker` 的已知旧 CLI 明确要求升级，不降级成包含旧条目的原生列表。

## 保存、回滚与后续同步

- 保存前通过原加载入口重新取目录。模型集合变化时更新预览并停下，不在用户未核对新结果时继续写入。地址、key、页面身份或请求世代变化后的迟到结果不能提交。
- 原配置 actor 在最终同步段重读磁盘，按最新对象局部合并；提交前比较原字节，防止旧计划覆盖外部新配置。备份成功后才原子写入，并回读核对。符号链接配置写入真实目标，原链接关系保留。
- 备份以原字节保存为独立普通文件，沿用原 `.backup.<timestamp>` 入口，同秒重名顺延，权限限制为当前用户。保留根字段、任意未知 env 值及大整数；未确认节点的完整原始内容在备份中可恢复。
- 每次实际迁移关联 `.migration.json` 报告，记录模型引用、目录及来源指纹、备份路径和 prepared／committed／rolledBack 状态，不复制密钥、env 或 hooks 正文。报告更新失败也回滚本事务输出。
- JSON 后续 Shell 修改失败时，原 VM 把事务收据交回原配置服务；仅当磁盘仍是本事务输出才回滚。外部已改写时拒绝覆盖，提示使用保留备份恢复，不能显示整体成功。
- JSON 单独保存时撤下本应用旧 Shell 管理段，避免高优先级旧变量继续覆盖 JSON；同时保存则更新管理段。区间外命令和换行保留，重复旧段统一清理；标记不完整时停止，原配置可恢复。每次修改前备份 Shell。只有 Shell 无法治理菜单，明确要求 JSON 或 JSON＋Shell。
- 恢复先验证真实备份及归属，成功备份当前文件后再原子替换。已移除“忽略备份失败、先删除当前文件”的旧路径。
- OAuth 账号启停、API Key 连接 v8 同步成功后，继续走原账号目录联动。配置页关闭时，同一原 VM 读取已接管文件及当前目录，通过来源指纹和原请求世代校验再同步；字节无变化时不重复备份。目录失败、来源不同或默认／角色失效时保留原文件并提示。
- 配置页打开期间保留未保存草稿，账号变更先更新目录与预览，待现有保存按钮提交，避免自动同步和编辑交错。恢复为旧版本备份后不自动重新接管，需要再次在配置页点击“应用”。

菜单保证以最近一次成功同步为准。已有 CLI 会话可能保留启动时状态，保存后需重开；管理策略、额外 `--settings`、用户手工环境变量及外部程序后续改写仍可能覆盖用户配置，本轮不修改这些来源或宣称可强制控制。目录可见性不等于真实额度或推理能力可用。

## 页面与定向证据

页面显示“已确认／将适配／退出菜单”的一行摘要，详情默认收起；旧 ID 不再常驻撑高页面。中文、英文、法文、越南文均有打包资源。原草稿在展示期间不被改写。

所有自动验证只使用临时 home、离线目录和本地假网关，合计覆盖 **66 个不同的相关用例**，没有运行全量测试：

- 原兼容、会话及账号启停与首轮迁移的定向组：`/tmp/quotio-claude-catalog-r4-20261019.xcresult`，43 项通过。
- 最终迁移、候选与子代理专项：`/tmp/quotio-claude-catalog-verification-20261019.xcresult`，37 项通过（迁移 18、候选 10、子代理 9）。覆盖失败不写、原字节备份、报告失败回滚、外部修改拒绝、符号链接、重复管理段、来源路径、默认／角色失效及旧响应隔离。此前两次构建被工作区其他改动的账号纯模型本地化隔离错误阻塞，已仅将两处调用改为原有 nonisolated 本地化入口，保留账号逻辑。
- 真实 UI 与 CLI 请求专项：`/tmp/quotio-claude-catalog-ui-wire-20261019.xcresult`，2 项通过。真实 CLI 2.1.292 使用生产生成配置，七组请求验证启动默认、原生 Default、角色、合法前缀、追加项和 1M；请求全部到 loopback，无真实推理。
- 独立交互式伪终端实际打开 `/model`：Default、Opus、Sonnet、Haiku、Catalog Long Context 与 legal/custom-model 可见，retired-catalog-model 不可见；选择后请求均为已确认 ID。证据：`/var/folders/w9/cgyn8nj14fs91j8rrc220l3w0000gn/T/quotio-catalog-panel-suxsfq4l/evidence.json`。
- UI 截图与脱敏请求：`/tmp/quotio-claude-catalog-ui-evidence-20261019`；最终独立 Debug 构建 **BUILD SUCCEEDED**，使用 `CODE_SIGNING_ALLOWED=NO`，日志：`/tmp/quotio-claude-catalog-final-build-20261019.log`。

本轮不发布或安装应用，不改写用户真实 Claude 配置。迁移在用户使用新版配置页保存后生效；备份包含原配置的认证信息，应按原敏感配置妥善保管，诊断报告不包含认证。

## 保存入口与首次弹窗修复

按用户后续要求，新旧配置都使用普通“应用”，不再提供“备份并迁移”的特殊按钮文案。原备份、目录核对、迁移报告、未知字段保留和失败回滚仍在同一保存事务内完成，不增加确认或额外操作。

原 `AgentSetupScreen` 分别以客户端与 UUID 两个 `@State` 传递呈现信息；首次 `sheet` 闭包可能捕获旧 UUID，导致真实保存按钮被会话保护拒绝，界面没有结果。现用与 `AgentConfigSheet` 成组的只读 `AgentConfigurationPresentation` 同时携带客户端和本轮 UUID，作为唯一 `sheet(item:)` 数据；客户端列表和仪表盘快捷配置均实际复用，两个页面分别持有自己的呈现状态。按钮及消失回调继续使用冻结的本轮身份。草稿、请求世代、任务、状态提交和校验仍归原 `AgentSetupViewModel`，没有弱化旧页面隔离。

新增 `AgentConfigurationApplyInteractionTests` 从生产列表点击真实配置与应用按钮，首次保存后再关闭重开保存另一模型，读取临时 JSON 核对槽位、未知字段和原字节备份。检测通过原 VM 的可选只读注入隔离；生产默认仍使用原检测 actor。修复前复现首次点击无响应，修复后该用例及原会话／迁移回归共 **33 项通过**，未跑全量测试，结果见 `/tmp/quotio-claude-apply-interaction-after-20261019.xcresult`。

补齐仪表盘快捷入口并复用呈现契约后，同一原生交互用例再次通过，结果为 `/tmp/quotio-claude-apply-final-interaction-20261019.xcresult`。该用例实际点击客户端列表入口；仪表盘对应改动通过代码复核与构建核对，没有宣称在真实运行中的仪表盘执行过授权或配置写入。

最终 Debug 构建 **BUILD SUCCEEDED**，日志为 `/tmp/quotio-claude-apply-final-build-20261019.log`。没有新增编译警告；定向测试构建中显示的 `QuotioCapsuleControls.hide(from:)` MainActor 警告在修复前已存在，本轮没有修改该公共控件。
