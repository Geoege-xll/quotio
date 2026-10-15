# CPA v8 首轮设置升级

## 结果与页面归属

原 CPA 设置缺少加权轮询、会话绑定、流式稳定性和日志容量控制，路由详情还会把非轮询值全部解释成优先填充。本轮按用户授权补齐五项能力，沿用现有分类，不增加内部 Tab。

| 位置 | 功能与交互 |
|---|---|
| 设置 → 模型与请求策略 | 轮询／加权轮询／优先填充使用 `QuotioCapsuleSegmentedControl`；会话固定账号主开关常显 |
| 同页 → 高级请求选项 | 默认收起；会话保持时间、子代理继承父账号、每轮尝试账号数、SSE 保活秒数、首字节前重试次数，修改后点击应用 |
| 设置 → 诊断与维护 → 高级日志选项 | 默认收起；日志目录总容量 MB、请求日志关闭时的错误日志保留数量，修改后点击应用 |
| 账号行 | 真实 CPA 文件账号增加账号权重按钮及右键入口；通过独立弹窗读取、修改权重 |
| 自定义提供商／GLM 编辑 | 密钥权重区默认收起，按不可变的条目 UUID 分别修改；GLM 仍保留原简化编辑行为及其它密钥 |
| 路由总览、KPI、请求详情 | 共用三种策略名称映射，处理 `wrr`、`weightedroundrobin`、`ff`、`fillfirst`；未知值显示原文 |

子代理继承控制 CPA 账号选择，与 Claude Code 的子代理模型分别设置。会话固定开启后，账号不可用时仍允许内核故障转移。

## v8 写入契约

- 主策略和会话主开关分别 PUT `routing/strategy`、`routing/session-affinity` 节点。
- 高级请求与日志使用 `/v8/management/config` 的局部 PATCH，只发送相对读取基线实际变化的字段，成功确认要求 `status=ok` 与 `config-version=8`。
- 文件权重只 PATCH `/credentials/fields` 的 `name` 和整数 `weight`，要求 `status=ok`。读取使用 `/credentials?name=...` 的非秘密权重元数据，不下载再上传认证文件。
- 已知运行时 API Key、监控账号和插件虚拟来源不走文件权重入口；提供商 API Key 的权重通过原有分组配置合并保存。
- 保留已有客户端密钥、令牌、账号元数据、模型别名、未知高级字段、注释和统计历史；没有新增旧管理 API 请求。

## 值与兼容行为

`CPAAdvancedSettingsDraft` 分离文本草稿与服务器读取基线。打开页面、展开高级区或关闭会话绑定均不保存配置；失败保留输入并提供现有重读入口。主控件在同步回调中先锁定表单，再执行异步保存，避免连点造成响应顺序倒置。

| 值 | 含义 |
|---|---|
| 账号权重缺省 1 | 加权轮询的缺省比例；最大 1,000,000 |
| 账号权重非正数 | 加权轮询时排除账号；实测 `/credentials/fields` 将非正值规范化为 0 |
| 每轮尝试账号数 0 | 尝试所有合格账号，与额外重试轮次分别控制 |
| 流式保活非正数 | 关闭保活；未编辑的负值保持不动 |
| 流式启动重试 0 | 关闭首字节前重试；已输出内容不重放 |
| 日志容量 0 | 不限制容量 |
| 错误文件数量 0 | 不自动清理 |

旧 `CustomAPIKeyEntry` JSON 不含权重仍可解码；nil 不被伪造成显式 1，也不删除 CPA 已有权重。唯一匹配的 CPA 密钥实际缺省时，界面观察到有效值 1。

权重的只读观察值与写入意图分别保留。成功同步快照记录密钥摘要、权重及本地编辑修订；本地修订只参与识别修改，不发给 CPA。已覆盖以下情形：

1. 外部把权重 5 改成 7，保存代理地址等无关项时保留 7。
2. 用户明确将外部 7 恢复为曾保存的 5，仍发出实际修改。
3. 停用后重新启用连接，新建密钥条目携带原显式权重。
4. 外部删除权重字段，界面显示实际缺省 1，而非旧本地值。
5. 密钥删除／重排按 UUID 对应草稿，避免权重串到另一个账号。

## 真实内核验证发现

CPA 8.0.28 的配置接口会接受不合法的 `session-affinity-ttl` 字符串，不能只依赖服务端字段类型校验。客户端已在本轮修改时验证 Go duration 的单位、符号、小数、组合单位、完整匹配和 Int64 纳秒范围；未编辑的历史值仍原样保留。该保护不对已有配置执行自动修复。

## 验证结果

- Debug 应用与测试目标构建成功；最终 11 组 **142 项回归通过，0 失败、0 跳过，无编译或运行时警告**。
- 覆盖新增字段读取／局部 PATCH、false／0／负值、旧 JSON、权重修改意图、外部更新与重新启用、管理协议、提供商配置、版本迁移、账号融合／去重及用量采集。
- 用生产 SwiftUI 控件渲染默认收起、展开、明暗主题、窄窗口和关闭会话绑定场景；修正原生 Form 重复显示 TextField 标签的问题，保留辅助功能标签。
- 独立只读代码审查及追加时长／布局复查没有剩余 Critical、Important、Minor 问题。
- 隔离 CPA **8.0.28** 原生 v8 与旧布局实例共 **112 项检查通过**，验证实际保存、热重载、权重更新、认证材料保留、注释与历史字段保留。全部使用临时假配置、假密钥和假账号，不改用户真实服务、配置或数据库。
- 最低 `v8.0.0` 的字段与协议通过官方固定标签源码核对；没有运行该版本二进制。未启用真实 OAuth 插件进行插件安装／虚拟账号运行验证，本轮也未增加这些操作。

验证产物：

- `/tmp/quotio-cpa-first-round-complete-tests-20261014.log`
- `/tmp/quotio-cpa-first-round-complete-tests-20261014.xcresult`
- `/tmp/quotio-cpa-first-round-visuals/`
- `/var/folders/w9/cgyn8nj14fs91j8rrc220l3w0000gn/T/quotio-cpa-first-round-real-98nn4mcv/results.json`
- `/tmp/quotio-cpa-first-round-real-probe.py`
- `/tmp/quotio-cpa-first-round-before-20261014/`、`/tmp/quotio-cpa-first-round-20261014.diff`

## 参考

- [官方配置选项](https://help.router-for.me/cn/configuration/options.html)
- [官方 v8 管理 API](https://help.router-for.me/cn/management/apiv8.html)
- [v8.0.0 配置模板](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/config.example.yaml)
- [v8.0.0 文件凭据字段处理](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.0/internal/api/handlers/management/auth_files_fields.go)
