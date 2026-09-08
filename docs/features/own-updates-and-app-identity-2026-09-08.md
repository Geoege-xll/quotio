# 自有更新、上游维护与应用身份调整

日期：2026-09-08。

## 需求与交付行为

- 关于页标题、应用更新卡片、版本复制信息及主窗口名称读取 Bundle 的 `CFBundleDisplayName`。缺失时依次使用 `CFBundleName` 和 Bundle 文件名，支持 `InfoPlist.strings` 本地化。当前显示名称为 `QuotioPlus`。
- 生产 Bundle ID 统一为用户指定的 `com.app.george.quotioplus`，测试目标为 `.tests`，开发身份示例为 `.dev`。项目配置、xcconfig、启动脚本和资源 Bundle 定位同步处理。
- `Config/Updates.xcconfig` 统一配置自有仓库 `Geoege-xll/quotio`、原项目上游 `nguyenphutrong/quotio` 和自有 Sparkle 公钥。应用、Atom 预检查与发布脚本共用自有仓库配置。
- 关于页和设置中的应用更新入口指向自有 Releases / appcast。代理二进制仍从其实际发行仓库 `router-for-me/CLIProxyAPI` 更新。
- “诊断与维护 → 维护入口 → 检查上游更新”展示上游最新稳定发行版、发布时间、发布说明和源码比较入口。上游查询与应用安装器分离，本地版本号不能用于判断源码是否已合并。
- 应用和代理的上次检查时间改为固定日期及分钟，鼠标提示可查看秒数。该组件不使用相对时间、定时器或 `TimelineView`，不再因秒数变化触发刷新。

## 更新状态和身份迁移

`AppIdentity` 在正式应用初始化前执行一次偏好补缺迁移，新身份已有设置优先，旧身份按最近使用顺序补齐。旧域不会删除；统计数据库、代理及其他 Application Support 路径继续使用原位置。

用户自动检查偏好属于跨版本可保留的选择。迁移兼容 `autoCheckUpdates` 与早期仅使用 `SUEnableAutomaticChecks` 的格式，显式关闭不会被默认开启覆盖。与旧发行源绑定的 `SUSkippedVersion`、检查时间等其他 Sparkle 状态，以及旧 Atom 缓存不迁移。新 Atom 缓存键包含仓库身份。

Sparkle 延迟创建后，先应用已迁移的自动检查开关，再启动更新调度；应用启动时的显式后台检查入口也遵守该开关。完成状态实现实际三参数 Sparkle 委托 `updater(_:didFinishUpdateCycleFor:error:)`，检查结束后更新一次可观察时间快照，并清除检查中状态。

钥匙串沿用已有的按需迁移机制，新服务名缺少凭据时才读取旧服务名；成功保存新条目后按原机制清理旧条目。本轮没有读取或修改真实用户凭据。Bundle ID 更换可能影响系统登录项和权限归属，需要在首次实际安装时验证，测试不能替代系统授权检查。

## 自有签名与发布状态

公钥从 `SPARKLE_PUBLIC_ED_KEY` 构建设置写入应用，CI 使用同名 Repository Variable；对应私钥使用 `SPARKLE_PRIVATE_KEY` Secret。旧上游公钥被明确拒绝。没有配置有效公钥时，界面说明当前仅能查看自有发布页，不初始化 Sparkle，自动检查选项不可用。

生成 appcast 前，发布脚本会要求公私钥齐全，并使用最终包内公钥验证 ZIP 的 Ed25519 签名。错误公钥或被修改的归档不能继续生成 appcast。Homebrew 发布通知改为显式配置 `HOMEBREW_TAP_REPOSITORY` 后才启用，并限定同一仓库所有者。

本次只读核对时，自有仓库尚无 Release，`releases/latest/download/appcast.xml` 返回 404。本地未配置自有公钥，因此自动下载安装尚不具备线上端到端验证条件。本轮未生成生产密钥、修改 Apple 开发者证书、配置远程 Secrets、提交标签或发布 Release。

## 验证记录

执行命令：

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DebugDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=NO \
  -only-testing:QuotioTests/AppUpdatesTests -only-testing:QuotioTests/AppIdentityTests \
  -resultBundlePath /tmp/quotio-own-updates-tests-r3.xcresult test
```

结果：构建成功，17 项测试通过，0 失败、0 跳过。覆盖 Display Name 回退、实际构建 Bundle ID 和 feed、旧公钥拒绝、Sparkle 委托 selector 注册、关闭自动检查的迁移优先级、上游响应解析、错误和取消、失败重试保留已知结果。

补充验证：

- 实际构建产物中的 `CFBundleDisplayName` 为 `QuotioPlus`，`CFBundleIdentifier` 为 `com.app.george.quotioplus`，appcast 为自有仓库地址。
- 使用仅存在于临时夹具中的密钥完成离线验签：匹配公钥通过，错误公钥和被修改的归档均被拒绝；未访问生产私钥。
- 缺少密钥的 appcast 命令在修改版本、清理产物或启动构建前被拒绝。
- `bash -n scripts/build_dmg.sh scripts/build_and_run.sh`、Info.plist 语法及改动空白检查通过。
- 独立只读复核发现的完成回调和自动检查偏好问题已修复，并补充上述回归测试。

尚未验证的边界：自有首次发布后的真实更新下载和安装、Developer ID 签名与公证、用户现有安装的系统权限和登录项迁移。本轮测试使用未签名 Debug 构建，不代表上述分发流程已验收。
