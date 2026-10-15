# 账号共享能力与运行模式归位：第三轮第四批

日期：2026-10-15。实施依据：[业务边界审计与后续方案](business-boundary-audit-third-round-plan-2026-10-15.md)。本批按真实使用方纠正账号身份、IDE 扫描、授权协调与弹窗归属，并区分共享运行模式和 App 导航；不按文件行数继续拆分。

## 业务归属与维护入口

| 能力 | 当前维护位置 | 保留边界 |
|---|---|---|
| 账号身份与菜单候选解析 | [MenuBarAccountCatalog.swift](../../Quotio/Shared/Accounts/Presentation/MenuBarAccountCatalog.swift) | 继续使用原目录、旧别名、固定项及精确额度解析；身份能力供原 QuotaViewModel 和菜单共同使用，不持有新状态 |
| IDE 显式扫描契约 | [IDEScanSettings.swift](../../Quotio/Shared/Accounts/Services/IDEScanSettings.swift) | 选项、结果、隐私辅助和原 manager 成组；扫描 Sheet 及获取任务留原宿主 |
| CPA 授权会话编排 | [CPAOAuthSessionCoordinator.swift](../../Quotio/Shared/Accounts/Services/CPAOAuthSessionCoordinator.swift) | 完整保留原 MainActor 类，由原 QuotaViewModel 唯一持有，Task、世代、期限和回调不拆开 |
| CPA 授权传输契约 | [CPAOAuthSessionClient.swift](../../Quotio/Infrastructure/CPA/API/CPAOAuthSessionClient.swift) | 原四个异步 API 与 ManagementAPIClient 符合声明成组，底层不持有 OAuthState 或协调任务 |
| 共享授权弹窗 | [OAuthSheet.swift](../../Quotio/Shared/Accounts/Views/OAuthSheet.swift) | 原 OAuthSheet 与 private OAuthStatusView 同文件，账号页与仪表盘保留同一调用方式 |
| 共享运行偏好 | [OperatingMode.swift](../../Quotio/Shared/AppSettings/OperatingMode.swift) | 原模式、原 manager、单例、偏好迁移与私有 setter 成组，原颜色与说明属性保持 |
| App 导航查询 | [OperatingMode+Navigation.swift](../../Quotio/App/Navigation/OperatingMode+Navigation.swift) | 原 visiblePages 和 isPageVisible 两个只读成员；通过既有 getter 读取同一模式，不写偏好或世代 |

原 App 菜单目录、Accounts 扫描契约、API 协调器和 App/State 模式文件位置已移除，不留下转发壳或第二份声明。ProvidersScreen 只移出实际跨业务使用的两个 OAuth 视图，其他页面、表单与状态继续留原位置。

## 完整性与行为约束

本轮基线 `/tmp/quotio-account-business-boundary-before-20261015` 记录 687 个文件及完整副本。以该快照核对本批增量，不以 HEAD 上的历史未提交差异判断范围；没有回退、暂存或提交既有改动。

- 八个迁移声明正文逐字一致：MenuBarAccountCatalog、IDEScanOptions、IDEScanResult、IDEScanSettingsManager、CPAOAuthSessionClient、CPAOAuthSessionCoordinator、OAuthSheet、OAuthStatusView。原隔离标注、私有字段、嵌套类型及方法属性随所属类型保留。
- IDE 隐私扩展与 ManagementAPIClient 的原符合声明完整保留。IDE 默认仅允许 CLI 发现；Cursor／Trae 仍须显式选择；没有新增目录、自动扫描、扫描状态副本或配置键。
- 原账号规范键、一对一旧别名、歧义拒绝、同邮箱多凭据、GLM 多 Key、当前模式目录选择及固定项顺序不变。原 QuotaViewModel 仍提交额度与订阅缓存，原菜单设置仍持有用户固定项。
- 共享模式与 manager 仅移走两个原只读导航成员，其他完整正文保持；导航成员自身正文原样。Shared 模式不再引用 NavigationPage；原 manager 的三个 private(set)、revision、defaults、初始化与旧键迁移、切换和写入顺序不变。
- 原 @Observable／@MainActor 仍在同一 manager 主类型；App 扩展只通过 currentMode getter 读取，不新增存储、Task、setter 或第二个模式实例。旧 AppMode 兼容入口未修改。
- OAuth generation、远端 pending state、期限、轮询／取消、手动回调、取消传播和迟到响应判定全部保持。原协调器仍由同一 QuotaViewModel 持有，原 oauthState 继续在该 ViewModel 中发布。
- 原弹窗 @State、设备码、Kiro 入口、手动回调反馈、新会话输入清理、task(id:) 成功等待和 onDisappear 取消正文不变。私有 OAuthStatusView 保持 private，不扩大跨文件访问。
- QuotaViewModel 及全部扩展、IDE 取数、账号页／仪表盘调用、CPA 管理客户端、监控授权、资源、工程和依赖锁定文件均保持本轮基线。没有更改任何原状态或任务所有权。

新增详细中文注释说明实际使用方和边界。工程继续通过文件系统同步根组自动纳入源码与测试，仍为单一应用 Target。CPAOAuthSessionClient 仍引用 Shared 的 AIProvider，这是已有领域依赖；本批纠正业务归属，不宣称已完成 Infrastructure 的全部编译依赖隔离。

## 测试归属与新增回归

原 112 个测试文件全部保留内容：其中 OAuth 协调器测试迁入 [Shared/Accounts](../../QuotioTests/Shared/Accounts/CPAOAuthSessionCoordinatorTests.swift)，运行模式测试迁入 [Shared/AppSettings](../../QuotioTests/Shared/AppSettings/OperatingModeTests.swift)，两个文件的原字节不变；其余原文件不变。

新增两个测试文件、三项业务回归：

- [OperatingModeNavigationTests](../../QuotioTests/App/Navigation/OperatingModeNavigationTests.swift)：使用独立偏好域，验证两个模式的页面集合和 manager 查询保持一致，读取不改 revision、当前模式或持久化偏好。
- [OAuthSheetBoundaryTests](../../QuotioTests/Shared/Accounts/OAuthSheetBoundaryTests.swift)：通过生产 OAuthSheet 和原私有状态视图渲染设备流内存状态；移除旧弹窗时另一提供商的新状态保留；原成功倒计时期间切换提供商不会执行旧关闭回调。

没有为类型移动添加逐文件镜像测试。新增 UI 测试不开始登录、不点击浏览器／回调入口，不调用真实 IDE 扫描。

## 构建与必要定向验证

首轮构建发现共享模式中残留两个导航成员，已删除旧位置残留并核对唯一声明。最终构建使用 QuotioPlus、Debug、macOS、CODE_SIGNING_ALLOWED=NO，结果 BUILD SUCCEEDED；最终构建和测试无编译器 warning，结果包无运行时 warning。

所有回归均逐方法指定 `-only-testing:QuotioPlusTests/<Class>/<Method>`，未运行全量测试。

| 定向范围 | 数量 | 验证重点 |
|---|---:|---|
| OperatingModeTests | 3 | 原模式值、旧远程模式和本地模式迁移 |
| OperatingModeNavigationTests | 1 | App 导航读取同一个共享 manager，查询不写偏好或世代 |
| MenuBarAccountSyncTests 的目录／身份方法 | 11 | CPA 启停不重复旧邮箱、模式目录、精确键优先、Copilot／Codex 旧身份、歧义拒绝与 GLM 多 Key 固定项 |
| AuthFileIdentityTests 的相关方法 | 3 | 磁盘／运行同凭据合并、同邮箱歧义、停止后不同索引身份保留 |
| IDEQuotaRefreshTests 的相关方法 | 2 | 未导入提供商不自动纳入，已删除账号不被额度合并复活；不执行真实扫描 |
| CPAOAuthSessionCoordinatorTests 的会话方法 | 13 | 正常授权、轮询取消、迟到 URL、设备流与 Grok 期限、到期取消、手动回调身份、同提供商重试与运行会话失效 |
| OAuthSheetBoundaryTests | 2 | 生产弹窗渲染、跨提供商退出保护和成功倒计时取消 |
| 合计 | 35 | 全部通过，0 失败、0 跳过、0 预期失败 |

执行标识与选择清单逐一核对，未混入未选择用例。测试类名和 scheme 保留，路径归位不改变 -only-testing 的选择方式。

验证边界：模式使用独立偏好，协调器用内存客户端与可控时钟，目录／额度使用合成账号，UI 关闭 ViewModel 后台服务。弹窗仍按生产实现读取 OperatingModeManager.shared，新增测试只向 ViewModel 注入临时模式，不能据此声称固定覆盖 localProxy 分支；位图只断言可渲染，不断言设备码文字识别。新增弹窗生命周期测试覆盖跨提供商替换，不外推为同提供商任意替换 session 的 UI 保证；同提供商迟到回调由原协调器测试验证。本批未以真实 CPA、浏览器授权、真实 IDE 文件或 Release 配置作为回归依据，也未为扩大测试注入改变生产状态所有权。

验证材料：

- `/tmp/quotio-account-business-boundary-map-20261015.json`
- `/tmp/quotio-account-business-boundary-build-first-attempt-20261015.log`
- `/tmp/quotio-account-business-boundary-build-20261015.log`
- `/tmp/quotio-account-business-boundary-targeted-20261015.log`
- `/tmp/quotio-account-business-boundary-targeted-20261015.xcresult`
- `/tmp/quotio-account-business-boundary-test-selection-20261015.json`
- `/tmp/quotio-account-business-boundary-test-summary-20261015.json`
- `/tmp/quotio-account-business-boundary-test-tree-20261015.json`
- `/tmp/quotio-account-business-boundary-verification-20261015.json`

独立只读复审对照本轮副本确认声明、文件私有作用域、Observation、访问权限、调用方向和工程纳入，未发现本批新增可行动问题；结论限于迁移，不代表全部账号业务或分层体系已无债务。当前维护索引和第三轮计划进度已同步，第五批客户端接入与模型目录仍待后续实施。
