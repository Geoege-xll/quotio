# CPA v8 API 追加审计与修复（2026-10-15）

## 范围

继续核对程序已使用的管理调用：凭据目录、账号状态与权重、OAuth、客户端密钥、配置读写、模型目录、上游 api-call、日志、用量队列和启动健康探测。对照官方 v8 文档、最低支持版本 v8.0.0 的路由／配置 PATCH 源码，以及 v8.0.28 的凭据与认证实现。未使用的插件安装、配额插件管理等端点不作为适配缺陷新增界面。

保留上一轮 Grok 设备流、回调和导入会话隔离，以及已有账号、凭据、配置与布局。生产代码继续只使用 v8 管理路径；模型业务协议保留 `/v1/models`。未启动或操作用户真实 CPA，未执行真实账号授权。

## 确认并修复的五项问题

### 1. v8 active 未计入可用账号

`AuthFile.isReady` 原来只识别 `ready`，但官方 v8 凭据目录使用 `active`。统计页顶部的可用账号数量因此可能显示为 0，旧额度卡片也有相同判断。

现在统一识别 `active` 和历史 `ready`，两者都排除 disabled/unavailable。统计、旧额度卡片与冷却提醒恢复复用该判断，不改写服务端原始状态、不把未知状态当作可用。

### 2. 调试模式三次写入可能部分成功

`setDebugLogging` 原来顺序写三个配置节点。第二或第三次请求失败时，界面报告失败，但先前字段已保存。

现在用一次 `PATCH /v8/management/config` 提交 `observability.logs` 下的 debug、logging-to-file、request-log，由 v8 一起合并、校验并保存。没有发送日志容量、错误文件数量或其他配置；原有单字段方法保留。写入不自动重试，仍检查 status=ok 和 config-version=8。

### 3. 空客户端密钥列表阻止模型别名目录加载

目录读取强制要求至少一个客户端密钥，合法的空 `access.api-keys` 会被客户端提前拒绝。v8.0.0 与 v8.0.28 的配置认证实现均会在密钥列表为空时撤销该认证提供方，无其他认证提供方时允许无认证访问业务接口。

现在先读取当前密钥配置；有非空客户端密钥则使用它，没有则不发送 Authorization，继续请求 `/v1/models`。绝不把管理密钥作为业务密钥回退。如果额外认证提供方仍返回 401/403，保留真实 HTTP 状态，不误报为目录格式错误。

### 4. 健康探测绕过主客户端重定向限制

`CompatibilityChecker` 原来独立创建默认 URLSession，没有使用主管理客户端的重定向边界，可能跟随另一主机或端口并把目标返回的 v8 配置视为当前服务正常。

现在健康探测与管理请求共用 `ManagementSessionDelegate`，按原请求的协议、主机及有效端口限制重定向；同源跳转仍支持，跨主机、换端口和 HTTPS 降级不跟随。响应仍必须同时满足成功 HTTP 状态与 config-version=8，不回退旧管理 API。测试可注入传输配置，生产保持原超时设置。

### 5. 日志连接切换的在途操作影响新会话

原 reset 没有立即释放 isRefreshing/isClearing；旧请求的 defer 又无世代保护。换连接后，新读取可能被旧操作阻塞；旧操作完成也可能错误释放新操作锁。日志 400 后的二次开关检查只有部分分支核对世代，同样可能迟到覆盖新提示。

现在重置时立即释放本地槽位、取消原客户端并清空游标；刷新和清理的 defer 只结束所属世代的操作。400 复查在 await 后统一验证世代，再进入成功或失败分支。日志页连接身份及 ViewModel 配置都纳入 CPA runtimeSessionID，同地址、同密钥重启也会建立新连接。无布局调整。

## 定向验证

仅运行四个直接相关测试类，共 **51 项通过，0 失败**，未运行全量测试。HTTP 均由 URLProtocol 离线夹具截获；新增重定向验证经过实际 URLSession 代理回调，检查跨主机目标没有收到请求、换端口未被跟随、同源跳转可正常读取。

| 测试类 | 用例数 | 覆盖 |
| --- | ---: | --- |
| CPA8ManagementAPIContractTests | 31 | 单次日志 PATCH、保存拒绝、空客户端密钥目录、额外认证拒绝、active/ready，以及原有凭据／OAuth／配置／队列／api-call 契约 |
| CompatibilityCheckerV8Tests | 5 | v8 路径及管理认证、错误版本／HTML／401、跨主机、换端口、同源重定向 |
| LogsV8LifecycleTests | 4 | 刷新中重配、清理中重配、400 复查迟到、相同连接地址下运行世代变化 |
| ManagementAPIClientLifecycleTests | 11 | 原有取消、失效、连接重试、队列不重试、目录请求取消和文件日志开关行为 |

最终 Debug 应用构建通过；本轮编译日志无 warning/error。未迁移或重写用户已有配置、凭据与偏好。独立只读复核未发现新增高信号问题。

- 定向回归：`/tmp/quotio-cpa-v8-followup-targeted-20261015.xcresult`
- 回归日志：`/tmp/quotio-cpa-v8-followup-targeted-20261015.log`
- 最终构建日志：`/tmp/quotio-cpa-v8-followup-final-build-20261015.log`
- 本轮修改前快照：`/tmp/quotio-cpa-v8-followup-before-20261015`
- 官方补充源码缓存：`/tmp/quotio-cpa-v8-followup-source-20261015`

源码核对不等同于运行过所有 8.x 二进制版本；本轮运行验证使用离线契约与生命周期夹具。

## 官方依据

- [管理 API v8：配置节点、PATCH 合并、确认与运维接口](https://help.router-for.me/cn/management/apiv8)
- [CPA 8.0.0 配置处理与保存](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/internal/api/handlers/management/config_v8.go)
- [CPA 8.0.28 凭据状态生成与恢复](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.28/internal/api/handlers/management/auth_files.go#L512)
- [CPA 8.0.0 配置认证提供方](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/internal/access/config_access/provider.go)
- [CPA 8.0.0 认证管理器](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/sdk/access/manager.go)
