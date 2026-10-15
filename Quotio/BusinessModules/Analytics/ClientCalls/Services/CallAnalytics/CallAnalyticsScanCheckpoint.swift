import Foundation
import CryptoKit
import Darwin

/// 来源级变化检测：只枚举路径并读取文件属性，不读取日志正文，也不另建磁盘缓存。
/// 未变化来源可直接复用 SQLite 日摘要；变化来源仍执行完整解析，不能把日摘要误当追加增量。
/// 解析器、时区或分类依据变化都必须使指纹失效；持久化的结果只有 SHA-256 摘要。
nonisolated struct CallAnalyticsScanCheckpoint {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    /// 解析语义变化时递增版本，确保旧成功指纹不会阻止必要的重建。
    private static let parserVersion = "call-source-fingerprint-v1"

    func fingerprint(for source: CallSourceKind, knownMCPServers: Set<String>) throws -> String {
        var pieces = [Self.parserVersion, source.rawValue, timeZone.identifier, homeDirectory]
        // 只纳入路径相关环境变量；凭据及无关环境变量既不读取，也不写入摘要输入。
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_DATA_HOME", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR"] {
            pieces.append(key)
            pieces.append(environment[key] ?? "")
        }
        let roots: [String]
        switch source {
        case .claude:
            roots = ClaudeCallEventSource(homeDirectory: homeDirectory, timeZone: timeZone, environment: environment).resolveProjectRoots()
        case .codex:
            roots = CodexCallEventSource(homeDirectory: homeDirectory, timeZone: timeZone, environment: environment).resolveSessionRoots()
        case .pi:
            // Pi 转录识别规则升级只让 Pi 的成功指纹失效，其他来源继续复用原 SQL 日摘要。
            pieces.append("pi-session-entry-v2")
            roots = PiSessionPaths.sessionRoots(homeDirectory: homeDirectory, environment: environment)
        case .opencode:
            // OpenCode 工具归类依赖已知服务器名；修改配置后，即使数据库没变也需要重新归类。
            pieces.append(contentsOf: knownMCPServers.sorted())
            let reader = OpenCodeCallEventSource(homeDirectory: homeDirectory, timeZone: timeZone,
                environment: environment, knownMCPServers: knownMCPServers)
            if let directory = reader.resolveDataDirectory() {
                let path = URL(fileURLWithPath: directory).appendingPathComponent("opencode.db").path
                for file in [path, path + "-wal", path + "-journal"] {
                    pieces.append(file)
                    pieces.append(try stamp(file))
                }
            } else { pieces.append("database-missing") }
            return Self.digest(pieces)
        }

        for root in Set(roots).sorted() {
            try Task.checkCancellation()
            pieces.append(root)
            let rootStamp = try stamp(root)
            pieces.append(rootStamp)
            guard rootStamp != "missing" else { continue }
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in enumerationFailed = true; return false }) else {
                throw CallAnalyticsReadError.unreadable
            }
            var files: [String] = []
            for case let item as URL in enumerator {
                try Task.checkCancellation()
                // Claude 的边车控制子代理类型，不能只检查 jsonl 的修改时间。
                let relevant = item.pathExtension.lowercased() == "jsonl"
                    || (source == .claude && item.lastPathComponent.hasSuffix(".meta.json"))
                guard relevant else { continue }
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                files.append(item.path)
            }
            guard !enumerationFailed else { throw CallAnalyticsReadError.unreadable }
            for file in files.sorted() {
                pieces.append(file)
                pieces.append(try stamp(file))
            }
        }
        return Self.digest(pieces)
    }

    /// inode、尺寸、纳秒 mtime/ctime 共同检测追加、替换、权限变化与保留 mtime 的重写。
    /// 缺失是可比较状态；无权限或其他读取错误必须抛出，不能误报来源未变化。
    private func stamp(_ path: String) throws -> String {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return "missing" }
            throw CallAnalyticsReadError.unreadable
        }
        return "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):"
            + "\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):"
            + "\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    /// 每段使用字节长度前缀，避免路径/服务器名中的分隔符造成不同输入拼接出同一串。
    private static func digest(_ pieces: [String]) -> String {
        var hasher = SHA256()
        for piece in pieces {
            let bytes = Data(piece.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
