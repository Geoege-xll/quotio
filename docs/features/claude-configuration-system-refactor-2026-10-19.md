# Claude Code 配置协议与事务统一重构

## 业务边界与所有权

本批按配置业务共同变化原因实施四组重构，解决审计确认的八类问题。没有按代码行数拆文件，没有新增精选列表、名称输入框、内部 Tab 或后台轮询。现有类型、配置键、未知字段、私有 setter 和兼容入口保持；用户真实 Claude 配置、账号、应用安装及发布产物不属于本批写入范围。

| 组别 | 业务归属与原耦合 | 本批统一边界 | 保留的所有权 |
| --- | --- | --- | --- |
| 模型语义 | 候选、角色、特殊指令、上下文与请求身份各自解析 | `ClaudeModelReference` 分类及 wire ID 规则，由原配置计划消费 | 草稿与目录仍属原 VM；纯值不持有 Task |
| 配置存储 | 代理保存、官方恢复、路径和标记有分叉 | 原配置 actor 共用位置、归属、严格快照、CAS 提交及回滚回执 | JSON 文件事务仍属原 actor；Shell 仍属原管理器 |
| 页面操作 | 手动／自动、恢复／应用的有效操作不一致 | 同一有效操作规则、原操作令牌和预览输入 | 状态与 Task 继续留原 VM，视图只持折叠状态 |
| 端到端证据 | 单次请求无法证明 `/model` 保存后的后续行为 | 临时目录、真实交互式 CLI、独立白名单假网关 | 不接管真实进程，不读取真实登录，不改写 HOME |

## 八项修复与兼容规则

1. **管理标记持久性**：新的磁盘凭证位于根 `quotioClaudeCatalog`，包含 `managed=true`、`version=1` 和连接指纹 `source`，不存明文密钥。本机 CLI 正常 `/model` 保存会规范化嵌套 `modelPicker`，所以新写入不再依赖其未知扩展。完整旧嵌套标记仍可读取，下一次合法保存迁到根。根协议优先；未来、残缺或错误类型不能借旧嵌套标记重新夺取归属。未知根成员和归属命名空间扩展继续保留。
2. **官方恢复事务**：原 actor 严格读取对象及 `[String: Any]` env，撤下已知代理键并保留任意未知 JSON 类型。非对象、损坏文件及不支持的 env 结构拒绝写入。代理保存与官方恢复共用原字节备份、CAS、原子替换、回读及回滚回执；Shell 第二阶段失败可回滚所有 Claude JSON 提交，包含非目录接管保存。没有 JSON 的历史仅 Shell 配置也明确返回清理动作。
3. **来源识别**：已保存的隧道、远程和局域网服务均回填代理模式，只有明确 `api.anthropic.com` 官方端点归为官方。来源地址与对应 key 成组读取；只有同一当前 CPA 才保留调用入口的新客户端 key，外部服务不借用 CPA key。
4. **唯一模型身份语义**：角色、特殊指令、字面 ID、末尾 `[1m]` 和旧角色链共用纯规则。实际模型槽拒绝新输入角色／特殊指令及其后缀变体；旧值保留并标注，不猜替代型号。目录必须确认最终真正发出的裸 wire ID，只有 `x[1m]` 的目录不能证明 `x` 可用。合法前缀、精确大小写与各槽独立上下文声明保留。
5. **子代理 FORCE 独立回显**：`nil`、`inherit` 与 FORCE 是独立维度。无指定默认模型时仍显示已有强制摘要；实际开关始终在默认收起的高级区，可显式关闭。旧未知 FORCE 原值不在只读回填时改写。仅 Shell 冲突判断继续复用子代理和整数领域语义，等价的旧写法不会被原始字符串比较再次否定。
6. **恢复互斥完整覆盖**：原 VM 的 `isConfiguring`、读取世代及操作 ID 覆盖文件恢复、回填和目录获取。应用、再次恢复与删除不能插入其中，旧会话的收尾不能释放新操作。Claude 完整回填模型槽，备份中缺失的槽不会从前一草稿复活。
7. **手动操作一致**：`ClaudeConfigurationOperation` 把手动模式的有效存储统一为 JSON，隐藏的自动 Shell-only 选项不再阻止预览或应用。原自动选择没有被改写；JSON 与可复制 Shell 继续提供，存在 JSON 覆盖时明确提示依赖。预览复用原 `previewTask`，完整配置、目录、历史引用、Shell 和会话作为同一输入，避免字段 watcher 遗漏。
8. **配置位置一致**：`ClaudeConfigurationLocation` 按显式注入、`CLAUDE_CONFIG_DIR`、原默认目录定位，读取、保存、备份发现／删除、恢复、回滚、后台同步和安装状态检测共同使用。路径保留空白、大小写及原始 Unicode，不传播凭据哈希专用的 NFC 规则。

恢复官方时还在删除受管菜单前收集其已知字面模型证据，统一比较 wire ID。这样 CLI 追加菜单保存的具体型号或 `live-model[1m]` 不会在撤下代理后残留为官方请求默认；不属于受管 env／菜单的独立默认选择继续保留。受管菜单的已知行为字段撤下，未知菜单扩展保留，完整旧条目仍在原字节备份中。

Shell 输出直接按冻结的目标 Shell 生成赋值与撤销语句，POSIX 使用 `export/unset`，fish 使用 `set -gx/set -e`，不依赖字符串替换。所有已知可选受管键在目标缺失时显式撤销，避免旧 Fable、压缩或子代理 export 残留；管理段以外命令不动。

## 文件维护入口

- 纯规则：`Shared/AgentClients/Models/Claude/ClaudeModelReference.swift`、`ClaudeCatalogOwnership.swift`、`ClaudeConfigurationOperation.swift`、`ClaudeConfigurationSource.swift`；原 `ClaudeConfigurationPlan`、`AgentConfiguration` 和菜单类型继续消费同一规则。
- 文件位置与事务：`Infrastructure/AgentClients/ClaudeConfigurationLocation.swift`、原 `AgentConfigurationService` 和 `AgentDetectionService`；原 `Infrastructure/Process/ShellType.swift` 与 `ShellProfileManager.swift`。
- 状态与页面：原 `AgentSetupViewModel`、`AgentConfigSheet`、`ClaudeModelPickerSection`、候选策略及默认模型选择器；菜单预览继续独立于高级配置。
- 测试镜像配置业务；真正复用的网关及 PTY 夹具位于 `QuotioTests/Support/AgentConfiguration/ClaudeCLIWorkflowFixture.swift`。

## 定向验证

只运行与改动直接相关的 `-only-testing:QuotioPlusTests/<Class>`，不跑全量测试。事务回归全部使用临时用户目录、独立偏好或离线夹具；真实 CLI 流程使用 `CLAUDE_CONFIG_DIR` 和临时 cwd，沙箱拒绝外网、真实 `.claude`／`.claude.json` 和用户 Keychain。

最终 **199 个不同的相关用例通过**，没有运行全量测试：

| 结果 | 范围 | 证据 |
| --- | --- | --- |
| 192 项通过 | 14 个明确选定的配置／模型／会话／原生交互／账号目录测试类 | `/tmp/quotio-claude-system-final-targeted-20261019.xcresult` |
| 6 项通过 | 真实 CLI 角色、同型号独立 1M、合法前缀、菜单、Default、子代理及 Shell 实际请求 | `/tmp/quotio-claude-system-cli-r3-20261019.xcresult` 中 `ClaudeCLIRequestCompatibilityTests`；同批首次交互流程曾失败，已单独修正并以下一行最终结果为准 |
| 1 项通过 | 配置应用 → 两次真实交互式 `/model` 保存 → 回读 → 账号目录变更同步 → 不传 `--model` 的新 CLI 实际请求 | `/tmp/quotio-claude-system-settings-only-final-20261019.xcresult` |
| BUILD SUCCEEDED | 独立 Debug 构建，`CODE_SIGNING_ALLOWED=NO` | `/tmp/quotio-claude-system-final-build-20261019.log` |

完整流程导出的脱敏证据位于 `/tmp/quotio-claude-system-evidence-20261019`：`model-save-receipts.txt` 保存两次真实 CLI 回执，`requests.txt` 记录实际模型及假 key 匹配结果，原附件和 `manifest.json` 一并保留。假网关采用独立白名单，未按被测计划反向生成期望。最终流程不向 CLI 额外注入 API key、AUTH_TOKEN 或 BASE_URL，连接完全来自应用生成的用户设置；并显式核对文件内连接字段，避免夹具环境掩盖配置应用错误。

该流程确认：CLI 自身会裁剪 `modelPicker` 未知嵌套字段，根未知字段与根管理凭证仍保留；因此应用不能再依赖嵌套扩展证明管理归属。应用写入保持未知字段与原字节备份，不宣称能阻止外部 CLI 的 schema 规范化。

独立只读复审发现并关闭两项边界回归：官方恢复遗漏追加菜单保存的具体默认型号，以及通用 Shell 原始字符串比较否定整数／子代理等价语义。最终复审无遗留实质问题。原生 FORCE 开关测试通过真实 `NSSwitch` bounds 交互；CLI 夹具修正了当前信任页短暂输入保护和不同页脚识别，未通过伪造 JSON、跳过信任或关闭网络隔离来替代真实流程。

fish 已核对生成语法；当前宿主没有 fish 二进制，因此没有宣称完成 fish 运行验证。zsh／bash 实际执行验证了引号字面量与撤销语句。所有写入均限定本轮临时夹具，没有替换正在运行的应用、改写真实 Claude 配置或发布安装包。
