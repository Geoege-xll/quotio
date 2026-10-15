# Copilot GHE.com 与 Claude Code 目录规范化适配

本批在保留原桌面控制中心、账号管理、三种菜单样式及既有配置的前提下，同步上游 PR #545 的 GHE.com 支持，以及 `17258af`、`513cc0b` 的 Claude 目录修复。没有引入上游 Rust CLI／SPM 架构，也没有迁移原状态和 Task 所有权。

## 审计结果与业务归属

原 Copilot 设备授权、用户信息、额度和模型令牌请求固定为 GitHub.com；原生 JSON／gh YAML 的令牌读取没有保留主机，模型缓存也只按令牌区分。因此不能只替换授权 URL，必须让所选主机随凭据、身份及后续请求一起传递。

原 Claude 只读凭据始终查询 `Claude Code-credentials`，不能正确选择自定义 `CLAUDE_CONFIG_DIR` 的钥匙串服务。本项目没有全局 NFC 调用可直接回退；适配重点是只在 Claude 原生边界补 NFC 和精确服务名计算，保持其他客户端的路径字面量。

- `Infrastructure/Providers/Copilot`：`GitHubHost` 校验及固定路由、安全重定向策略、原生 JSON／YAML 凭据解析。授权和额度实际复用同一契约，不放到全局字符串工具中。
- `CopilotQuotaFetcher`：使用原代理会话与取数生命周期，支持注入会话、保险库、原生路径及认证目录；缓存按主机与令牌隔离。
- `MonitorOAuthCoordinator`：复用原授权任务、世代、浏览器和保险库依赖。新企业流使用原会话校验与保护保存，不新增协调器单例。
- `Shared/Accounts`：保留主机元数据、同名企业账号身份及旧别名迁移边界；授权弹窗通过原 VM 注入的模式实例决定显示条件。
- `ClaudeCredentialOwnership`：仅负责 Claude 原生目录、钥匙串服务名及原刷新权限规则；`ClaudeCodeQuotaFetcher` 和发现入口共用。安全打开、symlink／hardlink 规则保持原样。

没有给 `QuotaViewModel` 增加存储属性，没有新增业务单例或向 App 的反向依赖。

## 用户入口与支持范围

监控模式添加 GitHub Copilot 账号时，原授权弹窗增加“GitHub 主机”：留空使用 GitHub.com，也可填写 `company.ghe.com` 或粘贴其 HTTPS 首页。

仅接受 `github.com` 和单层 `slug.ghe.com`；拒绝端口、额外路径、查询、用户信息、嵌套子域和任意自建服务器地址。CPA 模式继续使用原 CLI 登录机制，没有虚构 CPA 的企业登录参数。已保存的受支持主机元数据随账号用于额度及模型读取。

授权请求、轮询和用户信息端点由同一个校验主机生成；设备验证页必须精确属于该主机。携带认证信息的请求不跟随重定向。企业账号的令牌不会在失败后回退发送到 GitHub.com。

GitHub.com 保持原用户名账号键及空 `extra` 元数据；GHE.com 使用 `用户名@企业主机`，并在该凭据的 `extra.github_host` 保存主机。模型令牌和额度分别访问 `api.<slug>.ghe.com`；企业模型目录使用 `copilot-api.<slug>.ghe.com`，公共站点仍使用原模型目录地址。

## 配置、身份与缓存兼容

- 旧凭据缺少主机字段时仍为 GitHub.com；显式空值、`null`、错误类型或冲突主机一律拒绝，不能当成旧版缺字段。
- 认证文件支持 `host`／`github_host`。监控凭据、直接扫描与 CPA 列表元数据使用同一校验及账号键规则。
- 同文件运行记录合并磁盘记录时保留主机；主机冲突使用明确失败身份，不退回裸用户名。API／磁盘旧别名关联还要求主机一致。
- 企业账号不认领旧裸 username、login 或 email 缓存；仅保留可确认文件来源的完整名称别名。原个人账号别名迁移规则继续兼容。
- 原生 Copilot JSON 与 gh YAML 保留主机。gh 顶层只接受受支持主机，未知单标签主机也会跳过；JSON 仅识别固定包装层，不能把不明主机降级成公共账号。
- 模型缓存键包含主机。无效主机文件先排除，不会遮蔽同名有效个人凭据。
- 切换企业、取消或开始新授权后，旧响应不能保存凭据、污染新账号或回写授权提示。

## Claude NFC 与钥匙串规则

Claude 原生目录在 NFC 后使用；`~` 展开保留其后的分隔符。哈希输入保留尾斜杠、重复分隔符、大小写和有效空白，不用标准化文件 URL 或真实路径替代原导出字符串。

未设置覆盖变量时仍读取 `Claude Code-credentials`；显式覆盖目录时读取 `Claude Code-credentials-<SHA256 前八位十六进制>`，即使该覆盖值指向默认目录。自定义目录服务缺失时，不借用默认目录另一个账号的钥匙串凭据。

Codex、Grok、gh 与公共 `MonitorIdentity.expand` 不添加 NFC。Claude 的物理文件安全检查仍可按原规则规范化系统路径别名，但该结果不作为钥匙串哈希输入。原 CLI 凭据继续只读，不刷新其单次 refresh token。

## 定向验证

修复及复审后的六组定向回归：**66 项通过，0 失败、0 跳过**。

| 测试类 | 数量 | 主要范围 |
|---|---:|---|
| `CopilotGHECompatibilityTests` | 10 | 主机校验、完整设备流与主机持久化、同名个人账号、模型路由及缓存、错误主机、原生 JSON／YAML、重定向、取消迟到响应、目录合并与旧别名 |
| `ClaudeConfigDirectoryTests` | 5 | NFC UTF-8 字节、已知哈希向量、显式默认目录、尾斜杠／重复分隔符／大小写、其他客户端路径及原生只读保护 |
| `CopilotQuotaFetcherTests` | 13 | 原用户名与文件名优先级、旧别名去重、定向监控刷新兼容 |
| `ClaudeCredentialOwnershipTests` | 11 | 原只读刷新、复制凭据、symlink／hardlink 与写入边界 |
| `MonitorClaudeOAuthIsolationTests` | 11 | 原 Claude 取消、迟到响应、保险库与元数据提交隔离 |
| `AuthFileIdentityTests` | 16 | 原账号目录、不同索引、运行／磁盘合并、跨模式缓存映射 |

结果：`/tmp/quotio-ghe-nfc-targeted-20261015-v2.xcresult`；摘要：`/tmp/quotio-ghe-nfc-targeted-summary-20261015.json`。首轮五组 48 项也通过；后续在复审中补边界及用例，以上最终数量不与首轮累计。所有网络使用离线 URLProtocol，元数据使用临时目录，保险库使用内存后端。

最终 Debug 构建结果及文件静态核对记录见 `/tmp/quotio-ghe-nfc-build-final-20261015.log` 与 `/tmp/quotio-ghe-nfc-verification-20261015.json`。没有运行全量测试，没有登录真实企业账号、访问真实钥匙串或替换已安装应用。真实 GHE 企业的授权与模型服务连通性未由离线回归证明。

## 对照来源

- [上游 PR #545](https://github.com/nguyenphutrong/quotio/pull/545)：主机白名单、设备授权、凭据主机及后续路由；仅吸收本项目需要的协议与兼容规则。
- [17258af](https://github.com/nguyenphutrong/quotio/commit/17258af64ba4dfeb3d40f6416bd836129e60cfbe)：仅 Claude 原生目录做 NFC。
- [513cc0b](https://github.com/nguyenphutrong/quotio/commit/513cc0b503772019c12bfded253bea66b8d4dc6d)：保留目录精确拼写，含末尾斜杠。
- [GitHub 官方 GHE.com 认证说明](https://docs.github.com/copilot/how-tos/configure-personal-settings/authenticate-to-ghecom)及[网络域名说明](https://docs.github.com/en/copilot/reference/copilot-allowlist-reference)：企业主机及专用服务域名。

上游差异以 GitHub API 只读获取，保存在 `/tmp/quotio-copilot-ghe-pr545-20261015.json`、`/tmp/quotio-nfc-17258af-20261015.json`、`/tmp/quotio-nfc-513cc0b-20261015.json`，没有合并其桌面 UI 删除或守护进程架构变更。
