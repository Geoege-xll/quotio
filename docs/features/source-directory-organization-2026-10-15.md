# 源码与测试目录规整

日期：2026-10-15。本轮按用户确认的首轮方案规整目录，不拆分大文件职责。

## 实施范围

- 应用源码按 `App`、`BusinessModules`、`Shared`、`Infrastructure`、`Resources` 归类；业务模块以侧边栏范围为主，并按真实共享关系放置账号协调、模型管理和统计能力。
- 仪表盘下聚合路由中心；账号额度与账号管理同属 `Accounts`；客户端配置和工作区分开；统计保留 `CPAUsage` 与 `ClientCalls` 两种数据范围。
- `Models.swift`、`QuotaViewModel.swift`、`MenuBarSettings.swift` 等混合大文件整体迁移，不在本轮改名、拆分或重建实例。
- 测试目录映射源码职责，跨类离线 HTTP 夹具归入 `QuotioTests/Support/Networking/LifecycleHTTPFixture.swift`。
- Assets 与本地化移入 `Resources`，Info、entitlements 及桥接头移入 `App/Configuration`；工程固定路径与本地文档入口同步修正。
- 类型名称、配置键、数据库 Schema、用户数据位置和历史兼容入口保留；未新增内部 Tab、Swift Package 或应用 Target。

完整结构、主要入口和归属规则见 [源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 文档维护

项目索引、二次开发入口、规范索引及 Agent 维护说明均指向新目录。已有文档中能明确匹配的本地源码路径按迁移表更新；上游地址、原始 GitHub 源码链接和历史验证事实保留。已删除的历史文件仅作为历史记录存在，不建立虚假的当前路径映射。

## 文件完整性与打包检查

主任务核对迁移清单共 493 个文件，包含 288 个生产 Swift 文件和 103 个原有测试 Swift 文件。其中 488 个文件逐字节一致；其余 5 个文件仅涉及中文归属注释、桥接头引用和共享夹具抽离。新增 `Support/Networking/LifecycleHTTPFixture.swift` 后，测试 Swift 文件为 104 个，原有 104 个测试类、1,131 个测试方法的集合保持一致。

应用包的 `Assets.car` 与第三方许可证核查通过；本地化包含 `en`、`fr`、`vi`、`zh-Hans`、`zh-Hant` 五种语言。主应用没有重复复制 Info.plist。

## 验证记录

- 文档静态核对：新入口与本地 Markdown 目标均检查；外部 URL 与修改前一致。两处已消失的历史临时产物改为带说明的路径文本，保留原记录；已移除页面和上游原始链接中的旧目录继续作为历史证据。静态结果为 `/tmp/quotio-directory-docs-static-20261015.json`。
- 应用构建：主任务 Debug 构建成功，无编译 warning 或 error。
- 定向回归：主任务执行 78 项，0 失败。完整执行 `ManagementAPIClientLifecycleTests`、`CPA8ManagementAPIContractTests`、`AuthImportSessionTests`、`CompatibilityCheckerV8Tests`、`CPASettingsInteractionTests`、`LogsV8LifecycleTests`、`AppUpdatesTests`、`ClaudeConfigurationViewTests`，并单独执行 `MonitorRuntimeTests.testExternalCredentialReadRestoresProcessInteractionFlag`。测试构建无编译 warning 或 error。
- 结果包：`/tmp/quotio-directory-targeted-20261015.xcresult`；对应日志为 `/tmp/quotio-directory-targeted-20261015.log`。文件完整性和资源证据分别为 `/tmp/quotio-directory-integrity-20261015.json`、`/tmp/quotio-directory-resources-20261015.json`。
- 验证范围：只运行与目录、工程路径、共享夹具及跨层引用有关的定向用例，不运行全量测试。
