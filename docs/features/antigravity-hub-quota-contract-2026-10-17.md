# Antigravity 周期额度契约修复与取数重构（2026-10-17）

## 现场证据与根因

用户反馈第二个账号的 Gemini 周额度始终为 0。本机显示口径为「已用」，但这次并非口径误解或整数舍入：以 CPA v8 `/requests/api-call`、同一 `auth_index` 和同一项目逐项核对，确认请求身份和环境会改变额度响应。

| 同账号／同项目查询 | 第一账号 Gemini 周额度 | 第二账号 Gemini 周额度 |
|---|---|---|
| production 汇总，旧 CLI 或新 Hub 标识 | 剩余 91.49922%，重置 10 月 22 日 | 剩余 100%，重置不断变成查询时刻加七天 |
| daily 汇总，旧 `antigravity/cli/1.0.13` | 未返回 Gemini 组 | 未返回 Gemini 组 |
| daily 汇总，`antigravity/hub/2.23.0 darwin/arm64` | 剩余 95.12757%，固定重置 10 月 24 日 02:57:44 UTC | 剩余 95.41793%，固定重置 10 月 24 日 02:57:54 UTC |

新 Hub 标识下的 daily 同时给出 Gemini 五小时额度；第二账号当时剩余 86.46274%，固定重置 07:57:54 UTC。换算为现有「已用」整数显示，第二账号周额度约为 5%，不应持续为 0%。上述为 2026-10-17 06:15—06:17 UTC 的现场快照，不是固定额度值。

最终再按应用实际的「列表项目优先」规则只读核对两账号：其存量项目与 `loadCodeAssist` 新发现项目并不相同，但用各自存量项目和精确索引读取 Hub daily，仍返回上述固定周重置时间及随消耗变化的额度（第二账号周剩余 95.25321%，五小时剩余 85.88624%）。因此不擅自重写用户项目；双账号回归特意让辅助发现返回不同项目，验证原项目优先级继续生效。

两账号在 daily／production 的项目发现结果分别一致，CPA 请求始终绑定各自索引。production 与 daily 的周额度并不相等，不能继续把前者当作后者缺字段时的权威补充。此前 10 月 16 日两轮修复确认了接口差异，但将旧请求标识引起的缺失误判为环境固有差异；只校准五小时仍留下周额度错误。

现场请求只读，不发送生成／预热请求，不修改账号或配置；密钥仅在内存使用，证据仅保留脱敏周期数值，不记录邮箱、项目或完整凭据。

## 对照来源

- [CPAMC `fe296333` 的请求常量](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/fe2963330f32a933f562282165f62ae52cf57145/src/utils/quota/constants.ts)：使用 Hub 2.23.0 标识，汇总按 daily、daily sandbox、production 排序。[账号取数实现](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/fe2963330f32a933f562282165f62ae52cf57145/src/features/quota/providers/antigravity/data.ts)按精确索引和项目请求，不合并不同响应的周期。
- [Magpie `cb05dc2d` 的 Google 实现](https://github.com/yetone/magpie/blob/cb05dc2d1bc92aced1206c6271ca1d94f5690435/internal/provider/google.go)：Antigravity 使用 daily 执行环境和 Hub 标识；原生汇总负责周期池，模型级读数不能凭空生成周额度。其路由模型读取并不等同于我们的账号额度读取，不整体移植。
- [Quotio `1660b111` 的 Rust 实现](https://github.com/nguyenphutrong/quotio/blob/1660b111e79ac3510a6e8ca9374dfa9adb8aaf4c/apps/cli/src/providers/antigravity.rs)：参考其账号、项目和原生接口边界，不合并上游 Rust／SPM／主窗口架构变化。
- [CPA `911f49cb` 的执行器](https://github.com/router-for-me/CLIProxyAPI/blob/911f49cbd49f4fe2516979754a7488a3fd14fe64/internal/runtime/executor/antigravity_executor.go)：执行环境与项目发现环境分开；现有 v8 管理转发继续由原客户端负责。

## 业务边界与实施

本次按「Antigravity 周期额度读取」这一实际复用能力重构，不按文件行数拆分：

1. 新增 `Infrastructure/Providers/Antigravity/AntigravityQuotaReader.swift`，同文件维护无状态 Reader 和原 `AntigravityQuotaEndpoints`。统一项目载荷、汇总端点、解析、错误回退及取消复核，供本地直连和 CPA 精确凭据转发共同使用。
2. 两条路径统一 Hub 请求标识。五小时、周额度及各自重置时间来自一次汇总，不再额外查询模型目录并校准周期。
3. 汇总仅使用 daily 和 daily sandbox；**有意不照搬 CPAMC 的 production 最后兜底**。现场已证实其成功响应可能是另一环境的陈旧读数或滚动满额，错误继续交给原宿主按模式处理（CPA／监控保留旧值并标记失败），不能用跨环境满额替换。项目／套餐发现仍保留原 production 回退，不扩大此限制。
4. 删除已被替代的会话校准分支、模型明细补查及无生产使用方的模型目录额度解析；`AntigravityQuotaParser` 只负责原生周期桶。保留独立桶、未知字段、旧标签、原 ID 和 Codable 缓存兼容规则。汇总的 protobuf 省略零值按 Magpie 原生夹具核对：仅额度表示键全部缺失且重置时间有效时判为耗尽，显式 null／布尔／非有限数和畸形容器仍为未知。

原 `AntigravityQuotaFetcher` 仍持有 URLSession、原生认证、数据库和订阅缓存；`CPAQuotaFetcher` 仍复用原 `ManagementAPIClient`、精确 `auth_index` 和 `$TOKEN$`，不直读其他本地账号。`QuotaViewModel` 的状态、任务、刷新槽位、`private(set)`、失败旧值保留及会话提交边界均不动。账号页及菜单栏的布局、显示模式、账号配置和运行数据路径不变，不引入新的轮询或缓存宿主。

## 验证

定向验证范围：

- `AntigravitySessionQuotaTests`：同响应两周期、两凭据同邮箱并发隔离、连续刷新数值与时间成对替换、本地 Hub 传输、daily sandbox 回退、失败禁止 production／模型假满额、空／未知／明确零值、独立池、取消和迟到响应、原 403 状态。
- `AntigravityQuotaTests`：原生桶兼容、独立池、不平均、未知值、ID 去重、周期识别、中性标题及旧缓存。
- `CPAQuotaParityTests` 仅四个 Antigravity 方法：索引／项目／请求头、同环境回退、不可下载凭据时发现项目。
- `MenuBarQuotaPairTests` 及 `MenuBarUpgradeTests` 的单个 Antigravity 账号页／菜单展示方法。

最终验证完成：**46 项通过、0 失败、0 跳过**，结果包的 `runtimeWarnings` 为空；最终源码的独立 Debug 应用构建通过，`git diff --check` 通过。没有运行全量测试。

- 最终定向结果：`/tmp/quotio-antigravity-weekly-final-20261017.xcresult`
- 最终定向日志：`/tmp/quotio-antigravity-weekly-final-20261017.log`
- 最终独立构建日志：`/tmp/quotio-antigravity-weekly-build-final-20261017.log`
- 应用产物：`/tmp/quotio-antigravity-weekly-derived-20261017/Build/Products/Debug/QuotioPlus.app`

独立只读复核发现并修复了省略零值的解析缺口；最终复核未发现尚未解决的问题。旧校准测试已按实际生产契约更新，测试类入口保留；测试没有读取真实凭据或启停用户 CPA。

源码修复完成后，维护者另行授权以版本 `1.1.01`／build `1.1.01.4` 打包并替换 GitHub 及本机应用；两个账号真实额度生效验收见[构建交付记录](../releases/1.1.01-build-4-delivery.md)。临时验证产物在交付后清理，以上文档保留可长期核对的依据与结论。
