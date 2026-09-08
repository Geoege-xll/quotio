# 用户提供的 11111.trace 检查记录

日期：2026-09-08。输入为仓库根目录 `11111.trace/`；本轮只读分析，没有修改 trace 或应用业务代码。

## 结论与读取限制

官方命令行 `xctrace export --toc`、直接指定 Allocations Statistics 的 XPath，以及 Instruments 原生打开均失败。两条独立读取路径报告相同错误：

> Trace is malformed - run data is missing.

原生弹窗完整文字为 `The document “11111.trace” could not be opened. Trace is malformed - run data is missing.`。原生程序未能创建该记录的文档。

这证明当前文件不能被本机同版本 Instruments 正常解析，不是单纯的 XPath 写法问题。虽然包内保留了运行元数据和大型原始事件文件，但本轮没有取得可靠的分配统计、调用树、存活对象增长曲线或泄漏明细。不能把以前 `heap`、`vmmap` 的结果声称为从这份 trace 得到，也不能由文件大小推算应用的内存占用。

最初一次沙箱内导出因 InstrumentsCLI 缓存目录不可写而失败；允许工具访问所需缓存后，才得到上述 trace 解析错误。最终限制来自文件解析，并非权限仍未满足。

## 从存留元数据确认的信息

通过 Python `plistlib` 读取 `form.template` 的 NSKeyedArchive 对象索引，不实例化归档中的 Objective-C 类；仅保存必要标量。压缩的 schema／表配置使用 zlib 只读解压。

| 项目 | 结果 |
| --- | --- |
| 模板 | Leaks，包含 Allocations 和 Points of Interest |
| 录制开始 | 2026-09-08 09:08:43.100，Asia/Shanghai |
| 录制结束 | 2026-09-08 09:14:24.234，Asia/Shanghai |
| 时长 | 341.133 秒，约 5 分 41 秒 |
| 目标进程 | Quotio，PID 397 |
| Bundle ID | `app.bytrong.quotio` |
| 构建位置 | Xcode DerivedData 的 `Build/Products/Debug/Quotio.app` |
| 系统 | macOS 26.5.2（25F84） |
| 录制工具 | Instruments 26.6（17F113） |
| 当前导出工具 | xctrace 16.0（17F113），构建号一致 |
| 录制模式 | Deferred |
| 结束原因字段 | Target app exited |
| 退出状态字段 | 0；没有证据据此判定 OOM 或崩溃 |
| Allocations 设置 | Heap and VM allocations；Reference counts；Identities of virtual C++ objects；Freed memory: Keep events；Record all types |
| 原始分配事件文件 | `Trace1.run/event_data_397.oa`，30,450,126,848 字节，约 28.36 GiB |

`RunIssues.storedata` 中存在一条 `Data stream: Time Mapping` 记录。尚不能将该字段确定为导出失败或文件缺失的根因。

这次采集发生在统计内存改造完成之前，目标也是旧 Bundle ID 的 Debug 产物，因此即使恢复成功，也只能作为优化前的补充证据，不能用于评价新产物的运行内存。

## 接下来的有效输入

优先从仍可打开的原始 Instruments 会话另存一份 trace，关闭再重新打开，验证保存完整。若原始记录同样不能打开，需要重新采集。

重新采集应使用本轮优化后的产物，确认实际显示名／Bundle ID 为本项目新身份。建议先用 Allocations 做短录制，保留分配调用栈；本轮先不额外记录引用计数，若后续要追具体引用链再单独开启。

在进入统计页、完成刷新、切换筛选及退出页面前后使用 Mark Generation，比较各阶段持续存活的分配。先确认一次短 trace 能保存并重新打开，再延长观察时间。Apple 的 [收集内存使用信息](https://developer.apple.com/documentation/Xcode/gathering-information-about-memory-use) 和 [Analyze heap memory](https://developer.apple.com/videos/play/wwdc2024/10173/) 说明了 Allocations 与 Generations 用于定位持续增长的方式。

本轮脱敏元数据摘要保存于 `/tmp/quotio-user-trace-summary-20260908.json`。没有导出整份事件内容、环境变量或系统进程清单，没有向网络上传 trace。为检查原生读取而启动的 Instruments 在确认失败后关闭，原始文件保留。
