# CPA OAuth 与凭据导入会话加固（2026-10-15）

本轮依据前次审计修复六项问题，保留既有凭据、运行配置、浏览器授权流程、设备码展示和逐文件导入容错。不修改 CPA 配置文件、账号文件格式或应用沙盒开关。

## 六项修复

1. **Grok 设备流与有效期。** `OAuthURLResponse` 可选解码 `flow`、`expires_in`，兼容没有新字段的响应。协调器使用单调时钟，从授权 URL 请求开始计时，优先按服务端有效期结束，最长受 CPA 的 30 分钟会话 TTL 限制。缺少有效期时，设备流默认 30 分钟，旧浏览器流保留两分钟。`flow=device`、Grok 或非空 `user_code` 均识别为设备流，不展示或接受浏览器手动回调。
2. **本地提供商映射。** 本地 JSON 扫描与 API 账号目录共用 `AIProvider.fromAuthProvider`，统一识别 `xai`、`x-ai`、`grok`、`devin`，并保留 Copilot 等原有别名。导入仍保留文件原始字节与私密文件权限。
3. **Monitor 新增入口。** 手动认证能力按运行模式判断，Local Proxy 保留 Grok/Devin 入口；Monitor 隐藏这两个尚未实现的手动登录，并在 ViewModel 再做校验。不影响已有账号、额度、自动发现与文件导入。
4. **批量及单文件导入隔离。** 第一次挂起前固定 client／本地目录、模式修订和 CPA 运行世代，后续读取、写入、刷新与错误发布都校验原上下文。模式切换、CPA 停止或换客户端后停止剩余文件，不改写至另一目标。已完成的写入保留，不回滚；单个坏文件仍允许后续正常文件继续，整批只刷新一次。
5. **授权码解析。** 支持完整 HTTP(S) 回调、查询参数、`code:`／`code=` 前缀和裸授权码。完整 URL 必须自带 state；所有输入都与当前 state 精确匹配，拒绝重复的 code/state/error 参数。重建查询时保护 `+ / =` 等不透明字符，避免 Go 查询解码把加号改为空格；同时保留授权错误回调。
6. **手动回调生命周期。** 回调由 OAuth 协调器持有原 client、provider、state 和 generation；UI 提交点击时的 sessionID。提交状态与反馈也属于该会话，取消、关闭或同一提供商重试后，旧请求的成功或失败均不覆盖新反馈。提交中和已提交状态防止重复发送，新会话清空旧输入并收起手动区。

独立只读复核另确认了一个相关边界：CPA 健康检查的自动恢复可能绕过页面停止入口。本轮一并结束这种失效上下文中的等待状态，并远端清理迟到 state，避免弹窗一直等待；被新 generation 替换的旧任务不清空新会话。

## 定向验证

应用 Debug 构建通过。只执行相关测试类，不运行全量测试；全部使用临时目录、独立 UserDefaults、模拟 HTTP 或可推进时钟，不操作真实 CPA 和账号授权。

| 测试类 | 不同用例数 | 重点 |
| --- | ---: | --- |
| `CPAOAuthSessionCoordinatorTests` | 20 | 超过 60 轮仍可成功、有效期到期清理、旧浏览器默认期限、设备流拒绝回调、provider/state/sessionID 校验、迟到反馈、取消提交、自动恢复收尾、授权码编码 |
| `AuthImportSessionTests` | 8 | CPA→本地、CPA→新客户端、本地→CPA、离开后返回同模式、在途上传取消、单文件隔离、坏文件继续、一次刷新 |
| `AuthFileTransferTests` | 6 | 名称与 JSON 校验、0600 权限、原始字节保留、xAI/Devin 导入后重新扫描 |
| `CPA8ManagementAPIContractTests` | 27 | v8 原始 JSON、Grok→xai/Devin 请求参数、回调 POST，以及原有管理 API 契约 |

共 61 个不同用例通过，0 失败。先运行四个类的 59 项；最后针对协调器收尾变更单独运行其 20 项（含两个新增用例）。测试工程编译阶段补齐了现有账号页面测试夹具缺失的 SwiftUI 导入，没有扩大测试执行范围。

验证记录：

- `/tmp/quotio-cpa-oauth-fixes-targeted-r3-20261015.xcresult`
- `/tmp/quotio-cpa-oauth-fixes-coordinator-final-20261015.xcresult`
- `/tmp/quotio-cpa-oauth-fixes-final-build-20261015.log`

官方契约核对基于 [CPA v8.0.28 xAI 设备流](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.28/internal/api/handlers/management/auth_files_provider_oauth.go#L493)、[OAuth 会话 TTL](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.28/internal/api/handlers/management/oauth_sessions.go#L15) 与 [手动回调处理](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.28/internal/api/handlers/management/oauth_callback.go)。本轮未进行真实上游授权。
