import Foundation

// 多个统计页面共同使用的紧凑数字格式化；保留 K/M/G、符号及 nonisolated 计算口径。

// MARK: - Formatting Helpers

extension Int {
    /// 纯数字格式化不依赖 UI 状态，允许统计展示值在非主 actor 上复用相同的紧凑口径。
    /// 自动在 K -> M -> G 之间进位换算，达到 1G (10^9) 时转换为 G 单位并精简冗余尾零。
    nonisolated var formattedCompact: String {
        let absValue = abs(self)
        let sign = self < 0 ? "-" : ""
        if absValue >= 1_000_000_000 {
            let value = Double(absValue) / 1_000_000_000
            return sign + String(format: "%.1fG", value).replacingOccurrences(of: ".0G", with: "G")
        } else if absValue >= 1_000_000 {
            let value = Double(absValue) / 1_000_000
            return sign + String(format: "%.1fM", value).replacingOccurrences(of: ".0M", with: "M")
        } else if absValue >= 1_000 {
            let value = Double(absValue) / 1_000
            return sign + String(format: "%.1fK", value).replacingOccurrences(of: ".0K", with: "K")
        }
        return "\(self)"
    }
}
