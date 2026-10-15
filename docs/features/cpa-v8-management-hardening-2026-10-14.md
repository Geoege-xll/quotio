# CPA v8 管理 API 适配与加固

## 支持范围与来源

最低 CPA 版本为 **8.0.0**，当前安装、激活与运行支持经验证的 **8.x** 系列。未来大版本需要核对管理契约后再纳入，不能仅因版本号更高就自动视为兼容。版本解析拒绝 v7、负主版本、8beta、不完整版本及 80.x 等错误声明。

本轮按用户提供的 [管理 API v8](https://help.router-for.me/cn/management/apiv8.html) 与 [配置选项](https://help.router-for.me/cn/configuration/options.html) 核对全部现有 CPA 管理调用，并查阅官方 `v8.0.0` 的路由注册、配置读写与加载源码。未新增官方所有端点的界面；插件商店等尚未使用的功能不属于本轮。

生产代码统一使用 `/v8/management`，不再请求 `/v0/management`，也不在失败时回退旧管理接口。OpenAI 兼容的 `/v1/models`、Claude 业务请求等属于独立协议，继续使用原有业务路径和客户端密钥。

Claude Code 的 Default 及此前完成的 Fable、模型菜单、账号融合功能保持。

## 已有功能的接口映射

| 功能 | v8 路径与格式 |
| --- | --- |
| 账号列表、导入、删除 | `/credentials`；上传支持原始 JSON，删除使用编码后的 `name` 或 `all=true` |
| 账号模型与文件导出 | `/credentials/models`、`/credentials/download`，保留响应元数据与原始文件内容 |
| 账号启用/禁用 | `PATCH /credentials/status`，原有 name/disabled 对象 |
| 配额与预热代理请求 | `POST /requests/api-call`，保留 auth_index 与 `$TOKEN$` 的服务器侧替换 |
| OAuth 登录、状态与取消 | `/oauth/auth-url?provider=...`、`/oauth/status?state=...`、`DELETE /oauth/session?state=...` |
| Vertex 服务账号导入 | `POST /oauth/import?provider=vertex`，multipart 的 file 字段 |
| 全量配置与 YAML 读取 | `/config`、`/config.yaml`；配置读取校验 config-version=8 |
| 日志配置 | `/config/observability/logs/{debug,logging-to-file,request-log}` |
| 统计开关与用量队列 | `/config/observability/usage/usage-statistics-enabled`、`/observability/usage/queue` |
| 日志读取/清理 | `/observability/logs`，保留 after/cursor/limit 语义 |
| 路由策略与重试 | `/config/routing/strategy`、`/config/routing/retry/{request-retry,max-retry-interval}` |
| 出站代理 | `/config/requests/proxy-url`，清空使用 DELETE |
| 客户端密钥 | `/config/access/api-keys`，整体替换字符串列表；不写入上游 api-keys 分组 |
| OAuth 模型别名 | `/config/oauth/model-alias`，局部 PUT |
| 提供商别名与推理参数 | `/config/api-keys/<provider>`、`/config/requests/payload/override`，保持局部更新与回滚 |
| 静态模型定义与版本信息 | `/routing/model-definitions/<channel>`、`/server/latest-version` |

配置节点的 GET 返回原始布尔、数字、字符串、列表或 null。PUT 正文也是原始值，不再使用旧版 value/items 包装。配置树路径不能替代数组索引，客户端密钥的增删改先读列表，再仅修改目标条目并整体替换。

`ProxyConfig` 从 observability、routing、requests 等嵌套节点读取界面需要的属性，保持 false 和 0 的优先级。旧扁平字段仅保留本地历史数据解码能力，不触发旧 API 网络请求。

## 错误、确认与重试

- 配置变更必须确认 status=ok 且 config-version=8；凭据及导入确认 status=ok；日志清理确认 success=true。HTTP 200、空对象、错误版本或明确失败确认不会被当成操作成功。
- 配置校验保留 HTTP 状态与有限的字段原因，不输出请求正文、密钥或完整配置。401、403、422、500 等失败不会自动回退到旧接口。
- 仅 GET 配置节点精确返回 error=not_found 时使用缺省值。管理 API 未启用、端点不可用或非空错误类型继续报告失败。显式 null 是合法保存节点，读取使用对应运行缺省，不自动删除或改写它。
- 仅无副作用的读取允许连接退避。配置写入、凭据修改、上游 api-call、OAuth 启动和取消不自动重试，避免响应丢失后重复执行。
- 用量队列仍是全应用单消费者，读取即出队，始终单次请求；取得的批次继续优先落盘。队列缺失时报告 unsupported，不调用旧聚合 `/usage`，已有 SQLite 账本和历史统计保留。
- 管理与模型客户端凭据分离；HTTP 重定向仅允许同协议、主机与有效端口，拒绝跨源或 HTTPS 降级，避免认证头离开原服务。
- 文件名、OAuth state、日志 cursor 中的加号、与号等按查询值编码。Vertex 的 multipart 使用固定安全文件名、随机边界与原始 JSON 字节。
- 当前客户端的密钥修改设有 actor 内互斥，避免异步等待时重入造成读后覆盖；取消会释放保护。v8 没有列表元素级 CAS，因此不宣称不同外部管理客户端之间存在事务保证。

## 兼容项与运行缺省

`quota-exceeded.switch-project` 与 `switch-preview-model` 没有 v8 对应字段。最初按用户选择只读展示；2026-10-14 用户进一步确认删除后，已移除“设置 → 模型与请求策略 → 额度不足时的行为”区块、专用读取／解码模型、无效搜索关键词及词条。不主动删除磁盘中的历史值，其他 v8 配置的局部更新继续保留它们与原有注释。账号故障转移仍由 CPA 的路由与重试机制控制，删除旧控件不会关闭该能力。

官方模板显式推荐重试 3 次、最大等待 30 秒，但 **CPA 8.0.0 和实测 8.0.28 在文件未声明两个 retry 节点时实际为 0/0**。读取与设置页按真实缺省展示，新建配置模板仍显式写 3/30。界面允许等待间隔为 0，表示不等待凭据冷却，仍可切换其他可用账号。

重复清空已不存在的代理地址，仅将精确 not_found 视为已清空；其他 404 仍是失败。没有把 DELETE 替换成 null。

Qwen/iFlow 保留已有账号和登录入口，但在 CPA 8 中依赖注册的 OAuth 插件。登录页面说明必要条件，provider_not_found 返回可操作的插件提示；已注册插件仍通过统一 v8 路径登录，不冒充内置支持。

## OAuth 生命周期

`CPAOAuthSessionCoordinator` 冻结本轮客户端并用独立代号隔离开始、取消及新登录，避免旧响应覆盖新弹窗。

- 已知 state 时立即取消轮询，并独立调用服务端 DELETE 会话。
- 授权 URL 尚未返回时保留该次传输；迟到的旧 state 只用于后端清理，不发布状态或打开链接。
- 不吞掉取消或鉴权错误继续轮询，避免反复失败触发 CPA 临时封禁。
- 只打开有效的 HTTP/HTTPS 登录链接，拒绝 file 等其他协议。
- 成功仅刷新一次账号数据；已保存的成功账号不会被当成待取消会话撤销。
- 弹窗的成功自动关闭任务随视图/提供商/状态取消；关闭和退出路径结束会话，不让迟到关闭回调影响新登录。

Monitor、Copilot 和 Kiro 的独立认证内部实现保留。网络完全中断时无法确认服务端取消结果，记录未确认并隔离本地旧结果，不声称已经撤销服务端凭据，也不自动重复请求。

## v8 适配验证结果（移除旧设置之前）

- Debug 构建成功，最终 **17 组、203 项相关回归通过，0 失败、0 跳过，运行时警告为空**；编译没有 error/warning。
- 回归覆盖全部现有管理调用的实际 URLSession 请求、路径、鉴权、原始值、确认、错误、取消、重试、null、密钥编辑互斥与 OAuth 迟到响应。
- 旧配置、账号身份与去重、备份/统计维护、配额、启动健康、仪表盘模型目录、Claude Fable 与已有菜单相关回归通过。
- 使用独立 **CPA 8.0.28** 实例，对原生 v8 和旧布局各自执行配置、热重载、账号、日志、队列、null、OAuth 运维与注释保护核验，共 **93 项检查通过**。
- 实测凭据、服务账号样本与业务密钥全部是假数据；出站 api-call 仅访问本机假上游。没有更改用户真实 CPA、账号、配置或数据库。
- 最低 8.0.0 的路由与协议使用官方固定标签源码核对；没有声称已经运行该版本二进制。重试缺省对照只在隔离验证脚本读取了历史运行时视图，生产应用仍没有旧管理请求。

验证产物：

- 最终构建/回归日志：`/tmp/quotio-cpa-v8-hardened-tests.log`
- 回归结果：`/tmp/quotio-cpa-v8-hardened-tests.xcresult`
- 本轮专用差异与快照：`/tmp/quotio-cpa-v8.diff`、`/tmp/quotio-cpa-v8-before-20261014`
- 真实内核结果：`/var/folders/w9/cgyn8nj14fs91j8rrc220l3w0000gn/T/quotio-cpa-v8-real-o5e7hjcq/results.json`
- 构建应用：`/tmp/quotio-account-identity-derived/Build/Products/Debug/QuotioPlus.app`

## 删除旧额度设置后的回归

2026-10-14 的追加变更只移除没有 v8 对应字段的两个旧设置及其专用代码，未新增其他 CPA 设置项。Debug 应用与测试目标构建成功；管理 API 契约、提供商局部更新、版本／配置兼容、客户端生命周期与用量采集五组共 **57 项通过，0 失败、0 跳过，无编译或运行时警告**。删除的只读展示测试不再计入用例，迁移文件保留历史字段的兼容用例继续通过。

- 本轮回归日志：`/tmp/quotio-cpa-settings-cleanup-tests-20261014.log`
- 本轮测试结果：`/tmp/quotio-cpa-settings-cleanup-tests-20261014.xcresult`
- 删除前快照与专用差异：`/tmp/quotio-cpa-settings-before-20261014`、`/tmp/quotio-cpa-settings-cleanup-20261014.diff`
- 其余设置的现状与建议：[CPA v8 设置审计与补充建议](cpa-v8-settings-audit-2026-10-14.md)。清单中的首轮五项已按后续授权实施，其他进阶项仍为建议；详细结果见 [首轮升级记录](cpa-v8-first-round-settings-2026-10-14.md)。

## 最低版本源码参考

- [CPA 8.0.0 管理路由](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/internal/api/server_management_v8.go)
- [v8 配置读写](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/internal/api/handlers/management/config_v8.go)
- [配置加载与缺省值](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/internal/config/config_load.go)
- [重试运行值](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/sdk/cliproxy/auth/conductor_lifecycle.go)
