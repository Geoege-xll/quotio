# Antigravity Gemini 五小时额度与重置时间校准

> 2026-10-17 后续核对：本文中 Antigravity 的旧请求标识／production 优先方案已由 [Hub 周期额度统一契约](antigravity-hub-quota-contract-2026-10-17.md)替代。旧缺组现象与当时的 `cli/1.0.13` 请求身份有关，不能据此认为 production 周额度始终权威；以下保留当时现场及实施历史。
日期：2026-10-16。基线：`f097e4e`，直接在 `master` 实施。本轮源于 build `1.1.01.2` 实际使用时 Gemini 五小时额度一直满额、倒计时随刷新延后的反馈。

## 官方周期与参考实现

Google 当前[套餐说明](https://antigravity.google/docs/plans)仍说明 Pro／Ultra 有五小时额度；[模型页面](https://antigravity.google/docs/models)同时列出 Gemini 的周额度和五小时额度。不能把本次异常解释为官方取消五小时限制；免费方案与付费方案的周期也不能混为一谈。

- 上游 Quotio 固定核对提交 `dfa5beeb59cd169d98b25331f72c3149c713cae2`：[Rust Antigravity 获取器](https://github.com/nguyenphutrong/quotio/blob/dfa5beeb59cd169d98b25331f72c3149c713cae2/apps/cli/src/providers/antigravity.rs)。其主要优先级仍是汇总成功即返回，不能解决本次成功响应中会话桶为占位值的现场问题；不合并其 Rust／SPM 架构调整。
- Magpie 固定核对提交 `63be47717a9ca91fc89102078a1f1fff3e03e0ce`：[Google 额度实现](https://github.com/yetone/magpie/blob/63be47717a9ca91fc89102078a1f1fff3e03e0ce/internal/provider/google.go)、[共享池回归](https://github.com/yetone/magpie/blob/63be47717a9ca91fc89102078a1f1fff3e03e0ce/internal/provider/google_test.go)。实现明确区分模型级 `quotaInfo` 的五小时额度和汇总中的周期池，不把模型读数当周额度。本轮借鉴这一取数边界，未搬入其状态、账号池或后台调度。

## 本机只读取证

使用当前本机 CPA **v8** `/credentials` 和 `/requests/api-call`，分别对两个启用中的 Antigravity 账号按各自精确 `auth_index` 查询。`$TOKEN$` 始终由 CPA 在服务端替换；管理密钥只保留在诊断进程内存，不输出账号、项目、令牌或完整认证文件。只查询额度与套餐，没有发送生成请求或修改用户配置。

| 同一账号的接口来源 | Gemini 五小时读数 | 重置时间与完整度 |
| --- | --- | --- |
| production `retrieveUserQuotaSummary` | 两个账号均为 100% | 每次查询向后推五小时；有 Gemini 的真实周额度 |
| production `fetchAvailableModels`／`retrieveUserQuota` | 均为 100% | 同样滚动，不足以校准实际执行环境 |
| daily `retrieveUserQuotaSummary` | 没有 Gemini 桶 | 只有 Claude／GPT，不能直接替代完整汇总 |
| daily `fetchAvailableModels.quotaInfo` | 采样时约 86.53%／87.25% | 各账号有固定且彼此不同的重置时间，Gemini 模型读数一致 |

以上百分比仅表示现场采样时刻，不作为固定值写入代码或回归样例。正式汇总不带 project 的只读对照也返回同样的五小时占位，因此不能通过删掉 project 修复。

此前[Gemini 汇总主机修复](menubar-native-cascade-and-antigravity-quota-2026-10-16.md)只解决了 daily 汇总缺 Gemini 的问题；它没有覆盖“production 五小时桶成功返回满额占位”的行为。本轮补齐这一缺口，不能沿用“只需换汇总主机即可”的结论。

## 业务归属、实现与保留边界

改动仍归 `Infrastructure/Providers` 的原取数器、纯解析器和端点定义，不移动业务目录，不拆分大文件职责。账号页与菜单栏继续消费同一份 `ProviderQuotaData`。没有新增状态容器、Task、全局缓存、后台轮询或单例，保留类型名称、`private(set)`、配置键与旧缓存解码。

1. **按周期选取数据。** 汇总保留 production 优先及原端点回退，周桶的 ID、数值和重置时间不改。标准五小时共享桶补查同一凭据、同一项目的 daily 模型 `quotaInfo`，并同时采用该条读数的百分比与重置时间；不会拿模型额度替代周额度，也不读取兼容层 `/v1/models` 来推测额度。
2. **明确补查来源。** 五小时补查只使用两个原 daily 环境，不回退已证实存在滚动满额占位的 production 模型目录。本地 HTTP 请求显式忽略本地缓存；CPA 继续复用原管理客户端及其既有禁缓存规则。
3. **保留真实池边界。** 只有官方标准共享组且该组恰有一个会话桶时才补查。模型额度和时间完全一致时保留原共享桶 ID 与标题；不同或部分未知时保留逐模型五小时读数，不平均、不随意取一条。未知组、同组多个独立会话桶和仅周额度的响应不发无收益补查，也不合并已有独立池。
4. **失败不当满额。** 补查失败、全未知或返回无效数据时，保留已成功的周额度，将无法核实的标准五小时桶设为未知并清空不可靠重置时间；不把 production 的占位满额继续当作真实消耗。汇总整体失败仍遵循原失败路径，不用模型全满额伪造整账号成功。
5. **耗尽与缺失分开。** 参考 Magpie 记录的 protobuf 零值省略兼容，仅当 `quotaInfo.remainingFraction` 键真正缺失且有可解析的显式 `resetTime` 时认作 0。显式 null、布尔、NaN、无效时间及空对象仍为未知；禁用模型不参加校准。这是上游兼容依据，不声称本次现场采到了耗尽账号；周额度未知值语义不变。
6. **会话与身份不变。** CPA 补查沿用原 `authIndex`、`$TOKEN$` 和 project，不下载或借用本机其他账号。取消在补查与最终快照提交前传播；`QuotaViewModel` 原模式／账号／代理会话校验及刷新槽位保持不变。

## 必要验证

最终 **42 项通过、0 失败、0 跳过**；`xcresulttool` 已复核统计，运行时诊断项为空。只运行下列定向范围，未运行全部测试：

- `AntigravitySessionQuotaTests`：新增 12 项，覆盖滚动满额被实际五小时读数校准、百分比与时间配对、周额度与桶身份保留、独立模型差异、零值省略、空值与坏值、补查失败、本地获取、CPA 连续刷新与精确身份、取消、未知／有歧义桶不发额外请求。
- `AntigravityQuotaTests`：原 14 项；保留未知值、独立桶、窗口标签、旧缓存、汇总端点回退及失败语义。
- `CPAQuotaParityTests`：仅 4 个 Antigravity 直接相关方法，核对精确索引／项目、汇总回退与项目发现。
- `MenuBarQuotaPairTests`：12 项，核对共同快照中的上下周期与最低有效额度映射。

独立 Debug 构建成功；只读代码复核发现的无收益补查问题已关闭，`git diff --check` 通过。所有回归使用固定合成数据和离线传输，不连接真实账号。

- 最终结果：`/tmp/quotio-antigravity-session-complete-20261016.xcresult`
- 最终回归日志：`/tmp/quotio-antigravity-session-complete-20261016.log`
- 独立构建日志：`/tmp/quotio-antigravity-session-build-20261016.log`
- 构建产物：`/tmp/quotio-antigravity-session-derived-20261016/Build/Products/Debug/QuotioPlus.app`

本记录描述修复初审阶段的源码与构建验证。后续按用户授权保持版本 `1.1.01`、将 build 提升为 `1.1.01.3`；GitHub 资产替换、本机安装、生效验证及清理结果由[build 1.1.01.3 交付记录](../releases/1.1.01-build-3-delivery.md)单独记录，不以初审构建替代交付验收。
