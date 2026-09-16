# 会话删除卡顿排查与验证

验证日期：2026-09-16。环境：Xcode 27.0、Swift 6.4、macOS SDK 27，`QuotioPlus` Debug 构建。

## 根因与执行契约

项目启用了默认 `MainActor` 隔离。原 `AgentSessionProviderProtocol` 没有显式退出该默认值，导致其五个 `nonisolated struct` 实现的扫描、读取正文和删除方法仍被推断为 `MainActor`。外层 `WorkspaceSessionService` 即使是独立 actor，调用 Provider 时也会跳回主线程。

使用相同编译开关的最小程序检查 SIL 与运行结果，原实现显示 `scan` 的隔离为 `MainActor`，从独立 actor 调用时 `Thread.isMainThread == true`。临时 Home 中的真实 Codex 删除测试进一步复现：SQLite 写锁持有 400 毫秒期间，主线程无法执行排在 50 毫秒后的心跳。

Provider 协议现在显式声明为 `nonisolated`，协议的三个磁盘操作及五个实现的对应入口都声明 `@concurrent`。扫描、正文解析及删除因此离开 UI 执行器；从 MainActor 直接调用 Provider 也遵守同样约定。这里不能只添加 `async` 或改用 UI 内的 `Task {}`。项目启用的 `NonisolatedNonsendingByDefault` 会让普通非隔离异步方法继承调用方 actor；显式并发入口的语义见 [Swift 官方 SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)。

## 列表和容量刷新

- `WorkspaceSessionListSnapshot` 按会话集合、客户端和搜索词派生一次过滤结果、会话树、主列表及项目分组。每行读取后代数量时复用树，不再逐行重建完整索引。
- ViewModel 在三个输入变化时使缓存失效；命中缓存仍读取可观察输入，确保 SwiftUI 继续订阅后续删除和筛选变化。
- 批量删除复用同一棵事务前的 UI 会话树来计算已删除记录。
- 删除成功后更新列表、释放删除状态，容量统计使用独立任务刷新。一次只运行一个容量刷新任务；进行中收到新请求时废弃旧报告并补一次最新扫描，避免连续删除堆叠全客户端扫描。

删除前仍重新发现完整关系。路径校验、SQLite 写事务、隔离暂存和失败回滚仍由共用删除引擎执行，性能优化没有缩减父子会话或附件的删除范围。

独立只读审查未发现阻断项。当前生产页面的单删、批删和旧会话清理通过共享 ViewModel 的删除状态互斥；Facade 在等待 Provider 时允许重入，不能将其 actor 身份视作公开 API 之间的全局删除锁。

## 验证结果

| 检查 | 修改前 | 修改后 |
| --- | --- | --- |
| 真实 SQLite 写锁占用期间的主线程心跳 | 失败，释放写锁后才处理 | 通过，等待期间可响应 |
| 2,520 条记录、120 个主会话、三轮列表派生数据读取 | 1.388315167 秒 | 0.0250275 秒 |
| 删除成功后容量扫描尚未完成 | 删除状态持续占用 | 可继续删除，扫描请求合并 |
| 会话关系、删除安全、存储安全、ViewModel 等回归 | — | 73 项通过，0 失败 |

列表计时来自相同 Debug 配置下的测试，包含首次快照构建与后续复用，不包含窗口布局、GPU 绘制，也不代表用户本机所有历史数据的完整删除耗时。删除测试只操作独立临时目录和临时数据库，未删除真实会话。

测试入口：`WorkspaceSessionPerformanceTests`、`WorkspaceSessionRelationshipTests`、`WorkspaceSessionSafetyTests`、`WorkspaceStorageSafetyTests`、`WorkspaceViewModelSafetyTests`、`WorkspaceTests`。

```sh
xcodebuild -project Quotio.xcodeproj -scheme QuotioPlus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/QuotioPlusTargetRenameDerivedData \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -only-testing:QuotioPlusTests/WorkspaceSessionPerformanceTests \
  -only-testing:QuotioPlusTests/WorkspaceSessionRelationshipTests \
  -only-testing:QuotioPlusTests/WorkspaceSessionSafetyTests \
  -only-testing:QuotioPlusTests/WorkspaceStorageSafetyTests \
  -only-testing:QuotioPlusTests/WorkspaceViewModelSafetyTests \
  -only-testing:QuotioPlusTests/WorkspaceTests \
  CODE_SIGNING_ALLOWED=NO test
```
