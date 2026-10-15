# 路由中心失败类型与详细说明

日期：2026-10-15。范围：最近一次上游执行、上游执行记录及队列失败类型解析。

## 用户可见变化

- 最近一次上游执行保留原链路步骤，结果行显示状态码与失败类型；失败时增加默认收起的“失败详情”，展开查看原因说明和处理建议。
- 上游执行记录保留两行布局，失败徽标显示如 `HTTP 500 · 无可用凭据`、`HTTP 429 · 请求限流`。悬停可读解释，点击原记录展开原因、建议和证据来源。
- 失败详情已经包含状态码，不再在同一展开区重复输出单独的状态行。成功和取消继续使用原有状态字段及行为。
- 分类包括额度不足、请求限流、无可用凭据、上下文过长、模型不可用、认证失败、权限受限、无效请求、超时、连接失败和服务异常等。

## 数据来源及解释边界

CPA 官方失败记录包含 `StatusCode` 和 `Body`，错误正文可能来自执行器的原始响应或错误字符串。因此状态码不能独立证明具体原因，500 也可能包装超时或凭据调度错误。

- [CPA 官方失败记录结构](https://github.com/router-for-me/CLIProxyAPI/blob/dev/sdk/cliproxy/usage/manager.go)
- [CPA 官方错误到失败记录的转换](https://github.com/router-for-me/CLIProxyAPI/blob/dev/internal/runtime/executor/helps/usage_helpers.go)
- [CPA v8 管理 API](https://help.router-for.me/cn/management/apiv8)

新增 `CPAUsageFailureKind`，只保存有限分类；采集时优先识别 CPA 错误信息中的明确代码或短语。例：

| CPA 上报 | 可识别错误信息 | 展示 |
| --- | --- | --- |
| 500 | `auth_unavailable` | 无可用凭据 |
| 500 | `context deadline exceeded` | 请求超时 |
| 429 | `insufficient_quota` / `usage_limit_reached` | 额度不足 |
| 429 | `rate_limit_exceeded` / `rate_limit_error` | 请求限流 |
| 429 | 只有状态码或泛化 quota 文案 | 限流或额度限制，并明确无法区分 |

`quota exceeded`、`quota exhausted` 也可能描述每分钟频率配额，不能直接认定订阅额度耗尽。明确的限流代码不会被通用 quota 文案覆盖。

两个 UI 共用 `CPAUsageFailureExplanation`，区分“根据 CPA 错误信息归类”“按 CPA 上报状态提供通用解释”和“没有可识别原因”。不推断客户端最终结果，也不推断当前执行是否实际重试或成功切换账号。

## 隐私与兼容

- 不保存或显示原始错误正文；归档、tooltip 和可复制内容中只包含有限分类与静态本地化说明。
- JSON 正文只读错误相关字段，忽略 prompt、headers、api_key 等业务字段；字符串正文设长度限制，结构设深度和数组数量限制，无法识别时回退状态解释。
- `CPAUsageContext.failureKind` 为可选字段，旧记录缺失时保持 nil；现有 SQLite payload 直接兼容，无新增 SQL 列或历史重写。
- 历史记录已经丢弃的原始错误信息无法补回，仅能提供状态码的通用解释。
- 不改变请求去重身份、统计口径、取消判定、账号匹配、光流动画、路由配置或真实重试行为。

## 验证

只执行必要定向验证，没有运行全量测试：

- `CPAUsageFailureTests`：9 项，覆盖 429 额度与限流、500 的具体类型、模糊配额文案、错误字段范围、无效／过大正文、成功及取消、旧 Codable 和 SQLite 重开后的有限类型保存。
- `CPARoutingTests`：22 项通过，确认路由记录与身份投影原有合同。
- `CPAUsageDashboardTests`：10 项通过，确认现有聚合和历史记录语义。
- `CPARoutingRenderingTests/testFailureSummariesAndExpandedDetailsRenderWithPrivacy`：1 项，真实路由组件的宽窗口摘要、窄窗口深色展开及隐私渲染。

共 42 个不同用例。首轮新增历史夹具曾漏写旧格式必带的 canceled / generate，已修正为真实旧格式，兼容测试随后通过。

原生截图：

- `/tmp/quotio-routing-compact-visuals-20261014/failure-summaries-light-20261015.png`
- `/tmp/quotio-routing-compact-visuals-20261014/failure-expanded-private-dark-20261015.png`

构建与测试记录：

- `/tmp/quotio-routing-failure-build-delivery-20261015.log`
- `/tmp/quotio-routing-failure-tests-20261015.xcresult`：既有路由／统计 32 项通过；新增兼容夹具修正前的一项失败保留供追溯。
- `/tmp/quotio-routing-failure-delivery-tests-20261015.xcresult`：本轮 9 项分类及 1 项原生渲染通过。
- `/tmp/quotio-routing-failure-rate-boundary-verified-tests-20261015.xcresult`：明确限流代码与通用 quota 文案组合夹具通过。

测试仅使用离线目录、偏好和临时数据库，不读取真实队列、不触碰真实账号，也不启停 CPA。

只读审查已完成，发现的泛化 quota 文案误分类已修复。独立补丁：`/tmp/quotio-routing-failure-20261015.diff`，基于本轮修改前快照生成，未包含此前菜单栏、路由动画或统计布局的改动。
