import Foundation

/// Claude 用户配置的唯一位置契约；读取、写入、备份、恢复和目录同步都使用同一实例。
/// 显式目录优先，其次采用调用环境的 CLAUDE_CONFIG_DIR，缺省仍为原来的 ~/.claude。
/// 仅解析路径，不扫描目录、不访问 Keychain，也不承担配置状态或任务所有权。
nonisolated struct ClaudeConfigurationLocation: Sendable {
    let directory: URL
    var settings: URL { directory.appendingPathComponent("settings.json") }

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let directory { self.directory = directory; return }
        guard let raw = environment["CLAUDE_CONFIG_DIR"], !raw.isEmpty else {
            self.directory = homeDirectory.appendingPathComponent(".claude")
            return
        }
        // 目录名中的空白和大小写属于实际路径，不 trim、不传播凭据哈希专用的规范化规则。
        let expanded = raw == "~" ? homeDirectory.path
            : raw.hasPrefix("~/") ? homeDirectory.path + raw.dropFirst() : raw
        self.directory = URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
