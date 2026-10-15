# Antigravity 全模型弹窗适配与布局回归

日期：2026-10-15。

## 上游核对

对照 [nguyenphutrong/quotio PR #558](https://github.com/nguyenphutrong/quotio/pull/558)，PR head 为 `e6881ebdb06690ff66ce15f8f4ccf7c0fd347346`。核对时 PR 已关闭、未合并，因此本批记录为选择性适配，不表示整仓同步或上游已经发布该修复。

PR 的实际崩溃原因是全模型 sheet 及懒加载模型卡片从 `@Environment` 读取未提供的 `MenuBarSettingsManager`；修复改为显式传入 `displayMode` 和 `hideSensitiveInfo`。其测试覆盖空、五项、九项的独立承载布局。

本项目原实现直接读取 `.shared`，没有相同的缺失环境陷阱，但会绕过账号卡片注入的设置实例。仅照抄上游包结构或补一份环境对象不能解决这个依赖问题。

## 业务归属与改动

- 生产入口仍在 `BusinessModules/Accounts/Views/AccountQuotaContent.swift`；全模型弹窗及私有模型卡片继续同文件维护于 `AntigravityModelsDetailSheet.swift`，不提取无实际复用的公共控件。
- 由账号卡片的原设置实例读取两个展示值并传入弹窗。弹窗和私有卡片不持有设置 manager、不读全局单例、不新增存储或后台任务。
- `.sheet` 从“有额度数据”的条件分支移到同一账号卡片的稳定根节点，仍使用原 `showModelsDetailSheet`。打开后切换加载状态、模型列表刷新为空时保留原弹窗；账号卡片本身移除后仍遵循 SwiftUI 原生命周期。
- 空模型明确显示既有本地化文案“暂无配额数据”，不把空列表当成 0%。恢复模型后继续展示原两列懒加载网格。
- 保留原最小尺寸 480 × 360，初始提议尺寸为 560 × 440；模型内容滚动，标题和关闭按钮固定。长邮箱单行中间省略，关闭按钮补齐辅助功能名称。尺寸不回写状态，不增加测量反馈环。

## 保留的边界

详情入口仍只在 Antigravity 模型数量超过四项时显示；模型按原始名称升序排列。已用／剩余转换、未知额度占位、颜色阈值和重置时间仍复用原实现，其他额度布局不变。

不改变设置键、配置格式、账号身份映射、提供商取数和刷新规则。`QuotaViewModel`、`private(set)`、原状态和 Task 所有权均不调整；没有新增业务单例或环境依赖。

## 定向验证

新增 `QuotioTests/BusinessModules/Accounts/AntigravityModelsDetailSheetTests.swift`，使用内存模型、隔离偏好、原生 NSWindow／Sheet 和本地 Vision 读取实际绘制文字，不操作真实账号或连接 CPA。语言使用当前实际本地化，不修改用户语言或语言单例。

覆盖：

1. 未提供设置环境的独立承载，空／五项／九项在 480 × 360、560 × 440、960 × 680 下布局，检查有限尺寸和无横向溢出。
2. 已用／剩余额度、真实 0% 与 100%、未知额度、隐私及深色外观。
3. 真实 Sheet 的空→五项→九项→61 项→空更新，父窗口与 Sheet 尺寸变化、尾部滚动可达、标题保留及关闭按钮。
4. 从真实生产账号卡片点击详情，验证注入偏好及打开后的偏好更新，并验证加载→空列表→九项保持同一个 Sheet。

## 完成结果

最终 Debug 独立构建 `BUILD SUCCEEDED`；最终定向回归 9 项通过、0 失败、0 跳过：弹窗 4 项、`QuotaPercentagePresentationTests` 4 项、账号卡片既有 CPA 额度挂接渲染 1 项。未运行全量测试。

已目视核对最终测试附件：空列表、480 × 360 的九项列表、960 × 680 的九项列表、滚动到第 61 项、深色模式及未知额度。宽画布空状态通过截图和无残留网格验证；实际 Sheet 和生产账号卡片路径保留本地化空状态文字断言。

生产代码只改两个账号视图文件；`QuotaViewModel.swift`、`QuotaModels.swift`、`MenuBarSettingsManager.swift` 与本地化资源对比本批快照内容不变。只读复审发现的条件宿主卸载和测试语言依赖已修正并复核。

首轮原生测试记录过一次 AppKit `layoutSubtreeIfNeeded` 重入提示。后续[专项定位与复审](appkit-layout-reentry-and-followup-audit-2026-10-15.md)已在真实符号断点确认测试宿主中的自动尺寸协商链，显式使用可缩放的 `.fitted` 后同场景 0 命中，定向日志无原提示。无 XCTest 的生产视图对照在修复前后均未复现，因此不能把测试提示等同于已确认的用户场景崩溃。验证不包含真实账号联网刷新或其他 macOS 版本矩阵。

可复现的定向命令（结果路径每次使用新目录）：

```bash
xcodebuild -project Quotio.xcodeproj -scheme QuotioPlus -configuration Debug \
  -destination 'platform=macOS' -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -only-testing:QuotioPlusTests/AntigravityModelsDetailSheetTests \
  -only-testing:QuotioPlusTests/QuotaPercentagePresentationTests \
  -only-testing:QuotioPlusTests/AccountPageRenderingTests/testNativeCPAStartShowsOneCredentialWithAttachedLegacyQuota \
  test
```

本机临时证据为 `/tmp/quotio-antigravity-sheet-build-final-20261015.log`、`/tmp/quotio-antigravity-sheet-targeted-final-20261015.xcresult` 和 `/tmp/quotio-antigravity-sheet-attachments-final-20261015`，可能被系统清理，不作为长期来源索引。
