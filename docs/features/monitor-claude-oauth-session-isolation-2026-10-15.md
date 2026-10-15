# 监控 Claude 手动授权会话隔离修复

日期：2026-10-15。本专项处理整理后审计确认的既有风险：监控模式提交 Claude 授权码后，取消或开始新授权，旧 token 响应仍可能保存凭据、清除新 pending 并回写成功。该问题在目录整理前已存在，本次为功能修复，不继续拆分文件或迁移状态所有权。

## 修复边界

| 宿主 | 本次变化 | 保留内容 |
|---|---|---|
| [MonitorOAuthCoordinator.swift](../../Quotio/Infrastructure/Providers/Monitor/MonitorOAuthCoordinator.swift) | 在原 actor 内为 pending 和任务登记所属世代；同步失效，浏览器及 token 返回后复核；旧 defer 只清自己的状态 | 原 shared、activeTask、回调服务器、PKCE、授权端点、字段和提供商协议 |
| [QuotaViewModel+OAuth.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+OAuth.swift) | 取消／新授权首次挂起前失效旧 Claude；以原 OAuthState.sessionID 和模式 revision 保护开始、通知、成功、错误及取消提交；重复提交只接受 polling 状态 | 原 oauthState 宿主、账号变更入口、额度刷新及其他授权入口 |
| [QuotaViewModel.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) | 增加默认原 shared 的只读协调器构造注入，方便离线回归 | 全部原可变存储、private(set)、四个 Task 句柄和初始化启动顺序 |
| [MonitorCredentialVault.swift](../../Quotio/Shared/Accounts/Monitor/MonitorCredentialVault.swift) | 新增带世代的授权保存重载，实际写入前在同步锁内校验；原编码／CAS 抽为私有同步方法供两个入口复用 | 原保存协议签名、存储后端、指纹、刷新 CAS、删除与原凭据格式 |
| [MonitorMetadataStore.swift](../../Quotio/Shared/Accounts/Monitor/MonitorMetadataStore.swift) | 新增同一世代保护的保存重载，在原 actor 排队结束后复核并原子落盘 | 原路径、Payload、合并、迁移、禁用、删除及无世代保存接口 |

授权世代复用已有 MonitorStateRevision 的同步锁能力；该类型本身未修改。新一轮和取消在 MainActor 的首次挂起前推进世代，保险库和元数据在各自实际执行时检查同一个值。同步临界段内没有 await；它定义取消与写入的先后边界，取消不会反向删除此前已经完成的提交。凭据、元数据和页面状态仍分别归原 actor／ViewModel，未创建新 Task 宿主、消费者或并行凭据服务。

取消按对象分别处理：旧 activeTask 与旧 Claude pending 可被同一截止世代清理，新 pending 不受迟到取消影响。旧 login 的收尾按任务世代清句柄，旧浏览器收尾按服务器引用清理。监控设备授权的迟到通知、失败和取消也检查原 UI 会话，避免旧任务退出时清掉新 Claude 状态。原 CPA 授权协调器和本地 CLI 授权实现没有改动。

正常构造仍使用 URLSession.shared、MonitorCredentialVault.shared 与原系统浏览器。网络、保险库和浏览器只读依赖可供回归替换；四个原 HTTP 发送点使用注入会话，生产默认值、端点、方法、字段、轮询规则与凭据格式不变。原方法仍支持不传新增可选参数的调用，未增加设置键或本地化文案。

## 验证与复审

基线 `/tmp/quotio-monitor-claude-isolation-before-20261015` 保存 700 个文件及完整副本。只对照本批增量，不以 HEAD 的历史未提交差异判断范围。生产变更限定为上述五个文件，原 115 个测试文件内容不变，仅新增 [MonitorClaudeOAuthIsolationTests.swift](../../QuotioTests/Shared/Accounts/MonitorClaudeOAuthIsolationTests.swift) 的 11 项回归，当前共 116 个 Swift 测试文件。工程、资源、依赖锁、已有配置与类型名称保留；未放宽私有 setter。

生产 Debug 构建成功。首轮定向测试在编译阶段发现测试夹具不可变字符串被推断为 MainActor；显式补回 nonisolated 后解决，未运行失败用例。最终生产构建和测试没有编译器 warning，结果包没有运行时 warning。

所有测试逐方法指定 `-only-testing:QuotioPlusTests/<Class>/<Method>`，未运行全量测试。

| 范围 | 数量 | 覆盖 |
|---|---:|---|
| 新 MonitorClaudeOAuthIsolationTests | 11 | 正常 token 请求与保存、取消后迟到成功、调用任务取消、新 Claude 不被旧成功／错误覆盖、迟到取消保留新 pending、旧设备授权被取消且不覆盖新 Claude、旧 UI 不能借用新 verifier、重复提交、排队保险库写入失效、元数据拒绝旧世代、原 code#state 校验 |
| 原 MonitorRuntimeTests 相关方法 | 3 | 原保险库新增／更新／删除、元数据／禁用持久化、回调 state 不匹配 |
| 原 OAuthSheetBoundaryTests | 2 | 共享弹窗退出与成功倒计时不影响替换提供商的会话 |
| 合计 | 16 | 全部通过，0 失败、0 跳过、0 预期失败 |

独立复审发现并已修复一项实现阶段的兼容风险：不能因 Claude 已换代而整段跳过旧取消，否则可能漏停仍在等待的其他提供商任务。现按任务及 pending 所属世代分别处理，并加入实际离线设备流回归；复审确认该问题解决，未发现其他新增实质问题。之后按复审建议加固该测试的失败收尾，单独复核这 1 项通过，避免未来取消回归时夹具无限等待。总计 17 次成功执行，对应 16 个不同用例。

新增回归使用实际协调器、URLSession／URLProtocol、内存凭据后端及临时元数据文件；浏览器返回内存结果，模式及通知使用独立偏好域。不访问真实授权服务、钥匙串或用户账号，VM 只运行不会触发额度发现的旧结果路径。正向凭据保存通过原协调器与保险库执行；未通过 VM 的成功分支触发真实额度刷新。

验证边界：未执行真实浏览器、上游授权、Release 构建，未直接控制浏览器打开时的取消以及同步凭据写入已完成后、元数据 actor 排队中的所有交错。排队保险库拒绝过期写入、元数据拒绝失效世代分别有定向覆盖；不把分层验证外推为任意文件系统故障下的全事务回滚。独立复审未自行运行测试。

验证材料：

- `/tmp/quotio-monitor-claude-isolation-build-final-20261015.log`
- `/tmp/quotio-monitor-claude-isolation-targeted-20261015.log`（首轮测试编译诊断）
- `/tmp/quotio-monitor-claude-isolation-targeted-final-20261015.log`
- `/tmp/quotio-monitor-claude-isolation-targeted-final-20261015.xcresult`
- `/tmp/quotio-monitor-claude-isolation-test-selection-20261015.json`
- `/tmp/quotio-monitor-claude-isolation-test-summary-20261015.json`
- `/tmp/quotio-monitor-claude-isolation-test-results-20261015.json`
- `/tmp/quotio-monitor-claude-isolation-cleanup-recheck-20261015.xcresult`
- `/tmp/quotio-monitor-claude-isolation-cleanup-summary-20261015.json`
- `/tmp/quotio-monitor-claude-isolation-verification-20261015.json`
