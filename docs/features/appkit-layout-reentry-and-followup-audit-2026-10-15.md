# AppKit 布局重入定位与近期同步改动复审

日期：2026-10-15。

## 布局提示的证据与边界

本次处理前批原生弹窗回归中的 `layoutSubtreeIfNeeded` 重入提示，没有过滤日志、替换 AppKit 方法或跳过原场景。

1. 使用 LLDB 附加本次定向测试自己启动的进程，在 `_NSDetectedLayoutRecursion` 设置真实符号断点。修复前命中，主线程前 60 帧显示：`SheetBridge.createSheet` → 首轮 `NSHostingView.layout` → 尺寸观察通知 → `SheetBridge.apply(size:for:)` → `NSWindow._setFrameCommon` → 再次布局 → AppKit 诊断。
2. 单独提前完成测试父宿主的首轮布局不能消除提示，因此没有把它草率归结为测试辅助函数多调用了一次 layout。
3. 用不含 XCTest、截图或强制 layout 的原生小程序，分别直接编译前后两个生产弹窗文件，其他依赖为最小空列表夹具。该对照的旧版和新版都没有出现提示：旧版自动提议尺寸为 480 × 380，新版为声明的 560 × 440。
4. 因此，目前证据是**原生测试宿主的呈现时序触发了 SwiftUI 自动尺寸桥接重入**，并非已经证明用户常规点击生产详情按钮也会触发。生产详情按钮原本还要求模型超过四项；测试额外覆盖了空模型直接开窗的边界。
5. 在生产弹窗中显式使用 `.presentationSizing(.fitted)`，让创建阶段采用原声明的理想尺寸，继续保留最小尺寸与用户缩放。同一个原生测试场景修复后，符号断点已解析、命中数为 **0**；后续 44 项及 16 项相关回归日志均无原提示。

临时调试等待入口已从项目源码移除。最终测试继续实际打开 Sheet，检查初始尺寸、空数据／加载切换、缩放、滚动及原生关闭按钮。没有用固定测试根 frame 或降低场景覆盖来规避重入。

## 审计范围

复审了前批 Antigravity 弹窗、菜单栏稳定更新与额度历史、Copilot GHE.com／Claude NFC，以及其他 agent 的 CLI 渠道、终端、工具栏和模型候选调整。以各批实际快照和验证清单追踪逻辑变化，不把目录移动计成功能修改，不宣称覆盖整个仓库的所有历史代码。

用户最后明确账号网格布局由其他 agent 优化且没有问题；这部分保留原样，没有为本批恢复旧布局或增加额外布局验证。工具栏固定按钮结构也保留。

## 已修复的具体问题

### Copilot 身份与原生账号兼容

- 无效主机的直读文件不再落入裸邮箱键，使用文件范围身份，避免借用同名个人账号额度。
- CPA 目录逐个校验 `github_host`／`githubHost`／`host`；显式 null、非字符串、空值、别名冲突及嵌套冲突保持失败身份，不按缺字段降级为 GitHub.com。
- 支持已校验主机下的 gh `users.<login>.oauth_token` 多账号格式，按主机和令牌去重，不恢复任意未知容器递归。
- 企业无名凭据占位只在同一主机的真实账号出现后隐藏。发现目录与 VM 额度收尾共用规则，其他企业或公共账号不会替它去重。
- Claude NFC、精确路径哈希及 OAuth 取消／保险库世代路径未因本次修复改变。

### CLI 生命周期与终端执行

- 删除“位于 Homebrew 前缀就属于 brew”的兜底；Node 全局包仍按实际包路径识别。普通独立可执行文件不因该工具有 npm 发行包就被认成 npm。
- 已确认独立入口的 Claude／Codex／OpenCode 对同一入口执行原生更新；不支持自更新的旧版会保留终端失败结果，不另装 npm 副本。未知渠道在卡片现有提示区要求按原安装方式手动处理。
- npm／pnpm／bun 卸载由包管理器清理入口，不在失败后继续 `rm` 或覆盖其退出码。独立卸载只删除探测到的入口，保留目录配置。
- 拉起终端不代表卸载成功；不再提前清 `configured` 或 `lastConfigured`。启动失败写现有卡片消息；默认终端依赖不变，新增只读闭包注入仅用于离线失败回归。
- 终端由实际 Shell 的 login/interactive 模式初始化自己的配置，再执行 POSIX 正文；不让 Bash 同时解释 Zsh/Fish 配置。初始化后的 PATH 保持原优先级，常见目录只追加。
- 目录、入口和命令展示使用同一基础设施参数转义，防止引号、反引号或 `$()` 在打印命令时被二次求值。

相关官方命令边界：[Claude 手动更新](https://code.claude.com/docs/en/setup#update-manually)、[Codex update](https://learn.chatgpt.com/docs/developer-commands?surface=cli#codex-update)、[OpenCode upgrade](https://opencode.ai/docs/cli/#upgrade)。Codex 文档仅保证支持自更新的发行版，不推断所有历史版本都具有该命令。

### 历史来源、期限与模型候选

- 历史发布携带原目录确认的别名，只补齐 previous 中缺失的规范键比较基线。精确旧键优先，不按相同时间／数值合并账号，不把监控旧快照的纯重键记录成 CPA 新观测。
- 菜单卡片、明细、分析及历史动作使用同一模式世代。跟踪中切模式保留原生项身份，显示原空状态；点击及异步呈现前都复核来源，A→B→A 也不会复活旧动作。
- 可见预测使用 UI Timeline，分钟和重置／新鲜性截止点更新读数与行高；不增加提供商请求、采集 Task 或历史查询 Task。
- 按用户本次明确回复恢复原有**非 Pi 静态候选兜底**。保留当前原生角色引用与已保存配置；Pi 始终使用实时模型，实时目录和连接测试不混入静态列表。

所有状态、原 Task、`private(set)` 和设置键继续由原宿主持有。唯一新增基础设施文件为 `Infrastructure/Process/ShellCommand.swift`，由终端和 CLI 渠道两个真实使用方复用；没有为缩短文件拆分业务。

## 验证结果

独立 Debug 构建通过，最终日志 `/tmp/quotio-layout-audit-build-final-20261015.log`。

首轮 **44 项通过，0 失败、0 跳过**：

| 相关范围 | 用例数 |
|---|---:|
| Antigravity 实际 Sheet、空列表、尺寸与交互 | 4 |
| Copilot GHE 及本次四项边界 | 14 |
| 菜单身份、模式切换、原生明细到期收高度 | 9 |
| 模型候选与实时目录边界 | 3 |
| CLI 安装渠道与命令 | 4 |
| 历史 VM 发布链、精确别名、期限及维护 | 4 |
| 终端参数、退出码、配置与偏好 | 6 |

收尾 PATH 与可见错误提示修正后，仅重验受影响的 **16 项，全部通过**，其中新增 1 项生命周期失败回归；随后将旧兼容重载也纳入该失败用例，单独复验 1 项通过。因此本轮共覆盖 **45 个不同用例**，不重复累计执行次数。没有运行全量测试。

新增的原生菜单用例实际弹出明细 NSMenu 窗口，在没有新额度发布时跨过期限，确认同一承载视图的提示行高收回。它不代表已经覆盖根菜单悬停展开至 Codex 第三层的所有级联交互。

全部网络用离线 URLProtocol，存储和命令用临时目录、内存凭据与夹具 Shell；不登录真实账号、不运行真实包管理器、不拉起用户终端或启停用户 CPA。测试用的原代理状态样本在 defer 中恢复。

本地临时证据：

- 原调用栈：`/tmp/quotio-layout-reentry-stack-before-20261015.log`
- 修复后 0 命中：`/tmp/quotio-layout-reentry-stack-after-20261015.log`
- 无 XCTest 对照：`/tmp/quotio-layout-production-before-20261015.log`、`/tmp/quotio-layout-production-after-20261015.log`
- 首轮：`/tmp/quotio-layout-audit-targeted-20261015.xcresult`
- 收尾：`/tmp/quotio-layout-audit-final-targeted-20261015.xcresult`

这些路径可能被系统清理；长期维护以本记录的源码位置、相关用例及上述官方契约为依据。
