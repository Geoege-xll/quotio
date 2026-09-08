import Foundation

/// 旧版 JSON 索引的只读迁移入口；日常扫描统一使用 ClientUsageSQLiteStore。
/// 不再提供保存方法，从接口上避免新代码恢复文件与数据库的双写。
nonisolated enum ClientUsageCacheFile {
    enum CacheError: Error { case unsafePath, writeFailed }
    static func validate(_ url: URL) throws {
        var path = url
        // 检查所有实际目录，保留macOS系统/tmp与/var别名的正常使用。
        while path.path != "/" {
            if path.path != "/tmp", path.path != "/var",
               (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw CacheError.unsafePath
            }
            path.deleteLastPathComponent()
        }
    }
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        try validate(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
