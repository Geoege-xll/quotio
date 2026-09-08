import Foundation
import CryptoKit
import Darwin

/// 可重建的 OpenCode 扫描索引。只保存文件系统指纹、散列消息身份、版本摘要和脱敏 Token 记录，
/// 不保存数据库路径、原始 message/session ID、正文或凭据。记录与索引同次原子写入，
/// 即使永久账本随后写入失败，下次复用索引仍能完整重放已观测使用量。
nonisolated struct OpenCodeClientUsageCache: Codable, Equatable {
    var version = 1
    var databaseIdentity: String
    var fingerprint: String
    var revisions: [String: String]
    var records: [ClientUsageRecord]
    var hasErrors: Bool

    var isValid: Bool {
        version == 1 && databaseIdentity.count == 64 && fingerprint.count == 64
            && revisions.allSatisfy { $0.key.count == 64 && $0.value.count == 64 }
            && records.allSatisfy {
                $0.source == .opencode && $0.id.count == 64 && $0.timestamp.timeIntervalSince1970.isFinite
                    && [$0.input, $0.output, $0.cached, $0.reasoning].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000_000 }
                    && $0.total >= 0 && $0.total <= 2_000_000_000_000
            }
    }

    static func digest(_ parts: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// 与 ClientUsageRecord 构造器使用同一个结构化身份，确保更新记录替换旧值而不是叠加。
    static func messageKey(session: String, id: String) throws -> String {
        let identity = String(decoding: try JSONEncoder().encode([session, id]), as: UTF8.self)
        return SHA256.hash(data: Data(("opencode:" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 主库与 WAL 的纳秒级 mtime/ctime、inode、大小共同决定复用；替换数据库或 WAL 重建均失效。
    /// 不读取 SQLite 原始页，也不复制 WAL。/SHM 读者锁本身可能变化，不用它制造无意义重扫。
    static func fileStamp(_ path: String) throws -> (identity: String, fingerprint: String, bytes: Int64) {
        var database = stat()
        guard lstat(path, &database) == 0, database.st_mode & S_IFMT == S_IFREG else { throw StampError.unreadable }
        var parts = statParts(database)
        var size = database.st_size
        var wal = stat()
        if lstat(path + "-wal", &wal) == 0 {
            guard wal.st_mode & S_IFMT == S_IFREG else { throw StampError.unreadable }
            parts += statParts(wal)
            size += wal.st_size
        } else {
            guard errno == ENOENT else { throw StampError.unreadable }
            parts.append("no-wal")
        }
        return (digest([String(database.st_dev), String(database.st_ino)]), digest(parts), max(0, size))
    }
    private static func statParts(_ value: stat) -> [String] {
        [String(value.st_dev), String(value.st_ino), String(value.st_size),
         String(value.st_mtimespec.tv_sec), String(value.st_mtimespec.tv_nsec),
         String(value.st_ctimespec.tv_sec), String(value.st_ctimespec.tv_nsec)]
    }
    private enum StampError: Error { case unreadable }
}
