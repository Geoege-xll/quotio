import Foundation
import CoreFoundation

/// 两个统计入口共享同一条日志识别规则，避免一页成功、另一页仍把扩展转录当作损坏会话。
/// pi-subagents 的 transcript 可能与正式子会话重叠，也可能是唯一保留的转录；它缺少
/// SessionEntry 的稳定 id，不能把 recordType 强行改成 type 后累计。当前口径以正式保存的
/// 会话为准，两页均明确提示「仅存于扩展转录的用量/调用未纳入」，不把可读等同于完整覆盖。
nonisolated enum PiSessionEntry {
    static func decode(_ line: Data) throws -> [String: Any]? {
        guard let entry = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw CallAnalyticsReadError.unreadable
        }
        if let type = entry["type"] as? String, !type.isEmpty { return entry }
        // 仅跳过已确认协议的辅助记录；无 type 的普通 JSON 和坏数据仍向上报告读取错误。
        // 即使它位于非默认目录也按内容识别，不靠文件名或一刀切排除 subagent-artifacts 目录。
        if let version = entry["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
           let recordType = entry["recordType"] as? String,
           ["message", "tool_start", "tool_end", "stdout", "stderr", "truncated"].contains(recordType),
           let source = entry["source"] as? String, ["foreground", "async"].contains(source),
           let runID = entry["runId"] as? String, !runID.isEmpty,
           entry["agent"] is String, entry["timestamp"] is String {
            return nil
        }
        throw CallAnalyticsReadError.unreadable
    }
}
