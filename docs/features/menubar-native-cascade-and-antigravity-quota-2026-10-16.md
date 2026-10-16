# 菜单栏真实级联审计与 Antigravity Gemini 额度修复

日期：2026-10-16。基线：`4632030`，直接在 `master` 工作。

## 业务归属与保留边界

本轮只修复 Antigravity 外部额度接口选择，以及 App 菜单栏内的 Codex 展示交互。没有目录拆分，不调整账号页面卡片布局、导航、显示偏好、配置键、凭据映射、刷新调度或授权流程。`QuotaViewModel`、菜单装配器及各视图继续持有原来的状态与任务，保留 `private(set)`；热力图只删除可从当前数据计算的悬停文案缓存，悬停位置仍由原视图持有。

## Gemini 缺失的实际原因

使用当前运行的本机 CPA，对相同运行时账号索引执行只读 `api-call`；令牌仍由 CPA 的 `$TOKEN$` 替换，未输出账号、密钥或完整认证文件。现场结果：

- 两个 Antigravity 账号查询 `daily-cloudcode-pa.googleapis.com` 都返回 HTTP 200，但只有 `Claude and GPT models`，包含周额度与五小时额度。
- 同一账号查询 `daily-cloudcode-pa.sandbox.googleapis.com` 也只有 Claude/GPT。
- 使用相同项目和账号查询 `cloudcode-pa.googleapis.com` 时，返回 `Gemini Models` 和 `Claude and GPT models`，各包含周／五小时两个桶。
- 模型目录的 `quotaInfo` 与正式汇总中的周期额度数值不同，不能拿来替代周额度。

原获取器优先 daily，任意有效桶就立即成功，因此正式主机从未被查询。账号页与菜单栏都完整消费同一份快照，没有按 Gemini 名称过滤；问题不来自其他 agent 的账号布局。

修复在 `Infrastructure/Providers/QuotaFetchers/QuotaResponseValue.swift` 定义 `summaryHosts`：额度汇总优先正式主机，再按原规则回退两个 daily 主机。本地 `AntigravityQuotaFetcher` 与 CPA `CPAQuotaFetcher` 共用此顺序。订阅／项目发现继续使用原 `hosts` 顺序，不改变精确 `authIndex`、项目、取消和失败语义；不跨主机拼接响应，也不增加模型目录兜底。

只读诊断发现当前已运行实例提供旧管理路由，因此现场取证使用该实例现有路由；项目的 CPA v8 管理路径没有改回旧版。没有替换已安装应用或重启正在运行的 CPA。

## 菜单栏审计与修复

1. **真实三级级联。** 只对根 `NSMenu` 调用一次 `popUp`，在跟踪中通过原生账号项的辅助功能动作展开明细，再展开 Codex 分析。分别检查两个子级承载视图具有可见且不同的原生菜单窗口及正确的 `supermenu` 链。刷新时原菜单项、视图和子菜单身份不变；额度增多后原位增高；模式切换及 A→B→A 后，旧菜单不显示旧值，也不借用新来源的同名账号数据。
2. **Codex 悬停读数。** 原 `UsageTrendHeatmap` 将悬停文案单独存为 `@State`，只有鼠标事件才更新；原位刷新后鼠标不动就会显示旧读数。现保留原悬停格子 ID，直接从当前热力图数据计算文案，更新与删除该日数据均即时反映，不增加任务。
3. **Codex 重置券库存。** 20 张券的真实形状样例在三级菜单截图中被原无界 `HStack` 压成空胶囊。仅库存标签段改为水平 `ScrollView`，标签保持自然宽度，原次序、首张强调及到期提示保留；其余分析和账号布局不变。

## 定向验证

相关验证集中在 `MenuBarUpgradeTests`、`AntigravityQuotaTests`、`CPAQuotaParityTests` 的两个 Antigravity 获取用例，以及 `MenuBarQuotaPairTests`。不运行全量测试。

新增覆盖：正式汇总优先与备用主机回退、精确 CPA 索引和项目、Gemini 在账号页与菜单栏的实际绘制、真实三级菜单的迟到分析与模式隔离、库存尾部可达，以及鼠标不动时悬停读数更新和删除后清空。全部使用脱敏构造数据、临时偏好与离线网络夹具；线上查询只用于前述只读取证。

测试过程如实保留：初版合成按键未能驱动当前测试宿主的菜单跟踪，已改为本进程原生辅助功能动作，不向用户应用投递全局键盘事件；AppKit 对子菜单动作的布尔返回值可能为 false，因此验证以真实可见窗口为准。账号页原有共享显示口径和菜单隔离偏好可以不同，渲染断言分别按原口径核对，没有修改用户偏好。批量运行还暴露测试窗口激活的迟到事件，宿主在开始跟踪前先完成激活，不以跳过用例掩盖提前退出。

热力图另做了修复前的负对照：临时恢复基线中的原实现，仅跑同一个悬停用例。初始 `1313` 能正常读到，但刷新为 `4242` 后仍保留旧值，两条刷新断言失败；恢复修复版后通过。因此回归能区分新旧实现，而不只是重新计算一份模型值。临时对照代码已恢复，没有残留调试入口。

最终结果按不同用例计 **40 项通过**，没有运行全量测试：

| 范围 | 数量 | 结果 |
|---|---:|---|
| `AntigravityQuotaTests` | 14 | 全部通过 |
| `CPAQuotaParityTests` 的两个 Antigravity 取数用例 | 2 | 全部通过 |
| `MenuBarQuotaPairTests` | 12 | 全部通过 |
| `MenuBarUpgradeTests` | 12 | 最终整类全部通过，0 失败、0 跳过 |

前 28 项的通过记录位于 `/tmp/quotio-menu-antigravity-final-targeted-20261016.xcresult`；该轮菜单用例仍有一项库存前部小字 OCR 误识别，不能将整个结果包称为成功。目视核对首部和尾部截图后，保留真实滚动文档宽度、起点、末券读数与截图验证，并补充窗口实际可见范围和高度断言；没有改产品文字或数据来适配 OCR。最终菜单整类结果包为 `/tmp/quotio-menu-cascade-final-20261016.xcresult`，摘要确认 12 项通过、0 失败、0 跳过、无运行时警告。

- 独立 Debug 构建：`/tmp/quotio-menu-antigravity-build-20261016.log`，`BUILD SUCCEEDED`。
- 最终菜单回归日志：`/tmp/quotio-menu-cascade-final-20261016.log`，`TEST SUCCEEDED`。
- 最终截图目录：`/tmp/quotio-menu-cascade-final-images-20261016`，实际核对 Gemini、库存首尾及悬停更新画面。
- 修复前负对照：`/tmp/quotio-menu-hover-negative-control-20261016.xcresult`，预期暴露旧悬停读数问题。
- 构建产物：`/tmp/quotio-account-identity-derived/Build/Products/Debug/QuotioPlus.app`。

最终日志未出现新的 AppKit 布局重入提示；没有过滤日志。只读代码复审未发现可证实的未解决问题。`git diff --check` 通过，其他 agent 的账号布局文件及 `QuotaViewModel` 未修改。本轮没有替换已安装的应用；需运行新构建并刷新额度，才会使用新的汇总主机顺序。
