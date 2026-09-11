# Codex 用量读取状态与账本重建验证

日期：2026-09-11。目标是解决用量页面每次刷新均显示“读取不完整”，同时评估清空账本重新扫描的恢复范围。界面布局和 Token 差额算法保持原有设计。

## 原因

原实现把本轮文件读取／解析错误与全部历史会话的统计投影错误合并为同一个 `hasErrors`。SQLite 每轮合并都会检查全部 `client_usage_projection_status`，因此旧会话中长期存在的缺口会反复使 ViewModel 进入失败状态。

初次只读检查时，860 份当前缓存文件的 `has_errors` 均为 0，历史会话投影有 550 个错误。其中 314 个会话引用的父会话在永久账本内没有检查点；其余不能仅凭错误标记判定为父会话缺失。没有发现需要通过删库修复的数据库损坏，备份的 SQLite `quick_check` 返回 `ok`。

## 实施

- `ClientUsageStatus` 增加可选的 `readErrors`、`incompleteSessionCount`。旧归档在下一次真实扫描前仍使用原错误状态，不猜测已读取成功。
- 使用 `client_usage_status_details` 附表存储诊断；原状态表保持四列，旧 JSON、SQLite 和归档导入兼容。原状态与新诊断在同一事务保存。
- 原 `hasErrors` 继续表示整体完整性；ViewModel 的读取阶段和读取失败提示使用 `hasReadErrors`。
- 历史缺口通过“读取完成 · N 个历史会话统计不完整”及原有橙色提示点表达，真实文件错误仍报告读取失败。
- 原始日志已经消失时，不再把缓存里陈旧的读取错误算作本轮文件错误；历史检查点及其统计缺口继续保留。
- 父会话检查点后来补入时，继续通过原有待投影队列重新计算子会话；没有通过清错误位掩盖缺口。

## 本机隔离实验

所有实验使用生产编译模块，真实日志只读。使用 SQLite backup API 获取一致性原始副本，未通过直接复制活动数据库主文件忽略 WAL。

| 数据集 | Codex 用量记录数 | 读取错误 | 历史统计不完整会话数 |
| --- | ---: | --- | ---: |
| 原始备份 | 707,623 | 旧状态未分离；文件缓存错误为 0 | 550 |
| 全新空账本，重扫 866 份日志 | 49,704 | 无 | 232 |
| 原始备份上增量刷新 866 份日志 | 707,756 | 无 | 551 |

日志在诊断期间仍有新增，故不同实验的计数不是同一时间点。空账本全量扫描读取约 2.08 GB 日志，扫描约 14.7 秒、含账本投影约 21.4 秒；保留历史的增量刷新约 3.4 秒。以上是单次诊断观测，不是正式性能基准。

按记录稳定 ID 比较，空账本重建结果缺少原账本中的 658,043 条记录。这些旧记录的账本 Token 合计为 106,760,529,370；该数字是旧账本口径，并不代表独立确认的请求数或费用。早先文件覆盖检查还发现 661 个缓存会话仅对应已经不存在的日志文件。因此清空重扫不能保证恢复完整历史，也无法消除现存日志自身的统计缺口。

保留历史的副本刷新后，原账本各来源的记录 ID 缺失数为 0；Claude、OpenCode、Pi 的记录数及总 Token 与原始备份完全一致。

## 已应用到本机

采用保留历史的增量刷新方案，未清空生产账本。生产刷新完成时 Codex 为 866 份文件、无读取错误、551 个历史统计不完整会话，记录数为 707,772。原始数据库备份保存到：

`/Users/liqunmacmini/.quotio/usage_backups/20260911-1053/analytics.sqlite`

隔离实验及日志位于工作区 `build/codex-usage-rebuild-audit-20260911/`。备份另存于私有目录，避免清理 build 时失去恢复副本。

已退出旧 DerivedData 路径的应用并启动本次通过验证的构建：

`/Users/liqunmacmini/Desktop/quotio/build/ClaudeDefaultRowDerivedData/Build/Products/Debug/Quotio.app`

通过应用无障碍树实测，用量页面显示：

> Codex、读取完成 · 551 个历史会话统计不完整、866 / 866 个文件、已复用 862 个未变化文件

## 验证

定向 Xcode 回归 63 项全部通过，包含新增 8 项读取状态测试及原有 Codex 解析、刷新、SQLite 迁移、增量写入／扫描测试。覆盖真实读取失败、父检查点迟到、跨刷新／重启保留历史、旧状态迁移、坏文件消失、源目录缺失与 Engine → ViewModel 完成状态。

```sh
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/ClaudeDefaultRowDerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  -only-testing:QuotioTests/ClientUsageReadStatusTests \
  -only-testing:QuotioTests/CodexClientUsageTests \
  -only-testing:QuotioTests/ClientUsageTests \
  -only-testing:QuotioTests/ClientUsageRefreshTests \
  -only-testing:QuotioTests/ClientUsageSQLiteMigrationTests \
  -only-testing:QuotioTests/ClientUsageIncrementalStorageTests \
  -only-testing:QuotioTests/ClientUsageIncrementalScanTests test
```

独立只读代码复核未发现阻塞问题。本地化 JSON 解析通过。编译过程中还修复了技能导入回归测试对可选日期直接比较的类型错误，先通过 `XCTUnwrap` 验证字段存在再比较时间。
