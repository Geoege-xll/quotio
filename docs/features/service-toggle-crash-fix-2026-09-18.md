# 服务启停闪退与再次启动无响应修复

## 现象与定位

- 本机 1.0.03（构建 77）在 2026-09-18 16:50:39 关闭服务后发生 SIGABRT。
- 系统崩溃记录显示 `NSURLSession.data(for:delegate:)` 创建任务时触发 CFNetwork 的 Objective-C 异常。
- `ManagementAPIClient.invalidate()` 已使会话失效，但旧刷新、配额请求或连接错误退避仍可能创建任务。Objective-C 异常不能由现有 Swift `do/catch` 捕获。
- `QuotaViewModel.startProxy()` 原来在账号刷新、预热完成前一直持有布尔启动锁；停止没有取消这条初始化，立即再次启动会被旧锁挡住。
- 重启应用后，现有 CPA 7.3.5 可正常启动；此次没有更换 CPA 二进制或重置用户配置。

## 修复范围

- 网络任务在管理客户端 actor 内同步检查、创建和登记，避免检查有效之后跨执行器创建任务的竞争窗口。
- 会话失效、调用方取消和请求返回之间统一传播 `CancellationError`；重试退避不再吞掉取消。用量队列仍保持单次请求、不自动重试。
- 完整启动流程改为可取消任务，并以流程身份保护清理。停止立即释放旧初始化，旧任务晚返回不能清掉新启动状态。
- 底层进程启动在端口清理、启动等待之后核对会话；新的启动等待旧启动退出，避免交错清理误伤新进程。
- 每次停止都取消自动恢复并使等待中的启动失效，实际进程清理只执行一次。
- 自动恢复独立于已取消的轮询任务，用户手动停止仍可取消恢复。
- 账号、API Key、CPA 额度和错误写回均检查客户端身份、代理会话和运行状态。

## 自动验证

- 新增 12 项回归：9 项管理客户端生命周期测试，3 项启动流程测试。
- 36 项定向测试通过，覆盖相关 CPA 配额、采集生命周期和启动健康轮询。
- 最终全套运行 871 项：870 项通过，1 项性能测试按条件跳过，0 项失败。
- 沿用上次同步已确认的基线排除：`CPAUsageFilterDraftTests.testHiddenCountExcludesEveryPersistentControlAndIncludesMetric`。该用例在更新前源码中同样失败，不计入本次通过数量。
- 最终结果：`build/ServiceLifecycleFinalTests.xcresult`；日志：`build/service-lifecycle-final-tests.log`。
- 独立只读审查提出的自动恢复自取消、CPA 过期写回及重复停止不取消恢复问题均已修正。

本机修复构建使用 1.0.03（构建 78）。公开发行的 1.0.03（构建 77）安装包保持原有内容；本次修复未发布到 GitHub。

## 本机安装与验收

- 最终 Release 归档成功，产物签名完整性验证通过；已替换 `/Applications/QuotioPlus.app`。
- 已安装主程序 SHA-256：`5a11eaab41a156a5f2a7f60e0200a7d5b010fb18771a3fd48eea428819a63dbd`。
- 构建 78 首次启动曾等待 `KeychainHelper.getLocalManagementKey → SecItemCopyMatching` 的系统授权。2026-09-19 用户已确认状态栏开启、关闭不再闪退，随后反馈按钮显示不实时更新，继续修复菜单状态绑定。
- 启动采样、安装记录与 Release 日志位于忽略目录 `build/` 中。

## 2026-09-19：状态栏按钮实时刷新

- 用户确认构建 78 开关服务不再闪退，但菜单按钮仍显示旧状态。
- 原因：构建 `MenuNetworkInfoView` 时传入端口和运行状态的值快照，SwiftUI 的 `body` 没有读取实际服务的可观察属性。改为在 `body` 中读取状态闭包，原位更新开关、端口、提示及启停中的禁用状态。
- 启停中显示进度，并禁用重复点击；启动完成后显示停止按钮，停止完成后显示启动按钮。
- 原生菜单按承载视图的实际 frame 布局，内容更新不会自动改变菜单项高度。网络行通过 `fixedSize` 与 `onGeometryChange` 测量理想高度，再在主运行循环的 common modes 中合并同步 frame，避免新增隧道行被裁切。承载视图和菜单项均保持身份不变。
- 新增 2 项真实 NSMenu 跟踪测试，覆盖停止、启动中、运行、停止中、再次启动、端口绘制变化、菜单高度增减与菜单项身份。测试使用隔离状态，不启动真实代理、不读取用户凭据。
- 本轮 31 项定向回归全部通过：菜单呈现 2 项、菜单额度 13 项、上游回归 4 项、网络生命周期 9 项、启动流程 3 项。结果：`build/MenuProxyGeometryTests.xcresult`；日志：`build/menu-proxy-geometry-tests.log`。
- 独立只读复核未发现剩余 P1/P2；尺寸桥接采用弱引用，并延后合并更新，未发现保留环或持续布局循环。
- 本轮修复构建号为 79，正式版本号仍为 1.0.03。
- Release 归档成功，签名完整性验证通过，已安装到 `/Applications/QuotioPlus.app` 并启动。界面确认 CPA 已恢复运行，监听 `127.0.0.1:8317`。安装后的检查未发现新增崩溃记录。
- 构建 79 主程序 SHA-256：`63309c1b7a9e3688e74f669f0c69e48415dfe80f5ef9e41a288b6b2aabcf6f79`。记录：`build/menu-state-installation.json`；归档日志：`build/menu-state-release-build.log`。
- 已清理构建 77、78 的临时旧应用备份。公开 GitHub 发行包仍为构建 77，本轮修复未对外发布。

## 2026-09-24：本机构建 80

- 在上述启停修复基础上，合入账号头像与状态色、额度计数、Antigravity 模型级 429 提示、Claude Code 配置布局和运行日志 HTTP 400 修复。
- 正式版本号仍为 1.0.03，仅将本机构建号升至 80；Release 归档、应用深度签名验证通过，DMG 与 ZIP 只保存在本机 `build/release/`，没有发布到 GitHub。
- 已替换 `/Applications/QuotioPlus.app`，安装后主程序 SHA-256 为 `89ed12979d82d525fdd9f48da6ac2daa2b4cc31fe8780cde1566da6337bea357`，与本地打包产物一致。
- CPA 兼容性与额度计数共 19 项定向测试通过；完整测试运行中已有 855 项通过，随后测试应用初始化阻塞在 macOS 钥匙串读取，故中断全量测试。并行运行时一项界面布局测试失败，单独串行复测通过；中断产生的其余失败不代表断言失败。
- 新应用启动同样等待 macOS 钥匙串授权；授权后的界面和代理验收需另行记录。
