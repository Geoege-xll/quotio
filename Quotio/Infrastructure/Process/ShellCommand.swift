import Foundation

/// 终端启动器与 CLI 安装渠道共用的参数转义，只处理一个参数，不执行命令或读取用户配置。
/// 常见包名保持可读；空格、换行、引号、反引号和命令替换符都按字面值传递。
nonisolated enum ShellCommand {
    static func argument(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./@+-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
