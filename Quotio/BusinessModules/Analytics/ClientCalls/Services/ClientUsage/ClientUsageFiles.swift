import Foundation
import CoreFoundation

/// 复用调用分析已验证的只读流式I/O。根路径可注入测试；遇到权限/格式问题向上保留部分状态。
nonisolated enum ClientUsageFiles {
    static func jsonlFiles(roots: [String]) throws -> [String] {
        var paths = Set<String>()
        for root in roots where FileManager.default.fileExists(atPath: root) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: root)
            guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CallAnalyticsReadError.unreadable }
            var failed = false
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else { throw CallAnalyticsReadError.unreadable }
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true && file.pathExtension == "jsonl" { paths.insert(file.path) }
            }
            if failed { throw CallAnalyticsReadError.unreadable }
        }
        return paths.sorted()
    }
    /// 缺失的可选子项为零；存在却非法的字段必须返回nil，由来源标为部分失败。
    static func validatedNumber(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let amount = number.doubleValue
        guard amount.isFinite, amount >= 0, amount <= 1_000_000_000_000,
              amount.rounded(.towardZero) == amount else { return nil }
        return Int(amount)
    }
}
