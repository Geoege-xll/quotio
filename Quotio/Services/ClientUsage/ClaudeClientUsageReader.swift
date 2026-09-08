import Foundation
import CryptoKit
import Darwin

/// Claude 专属增量读取器。磁盘检查点只含文件指纹与脱敏用量，绝不序列化正文、消息原 ID 或路径。
nonisolated enum ClaudeClientUsageReader {
    nonisolated struct Fingerprint: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let createdSeconds: Int64
        let createdNanoseconds: Int64

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
            createdSeconds = Int64(info.st_birthtimespec.tv_sec)
            createdNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }

        /// 从按列保存的扫描指纹恢复，不读取原始日志，也不保存其路径。
        init(device: Int32, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64,
             changedSeconds: Int64, changedNanoseconds: Int64, createdSeconds: Int64, createdNanoseconds: Int64) {
            self.device = device; self.inode = inode; self.size = size
            self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
            self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
            self.createdSeconds = createdSeconds; self.createdNanoseconds = createdNanoseconds
        }

        /// 同 inode 的缩短或等长改写必须重建；出生时间避免 inode 重用被误当作追加。
        func canAppend(to next: Self) -> Bool {
            device == next.device && inode == next.inode && createdSeconds == next.createdSeconds
                && createdNanoseconds == next.createdNanoseconds && size < next.size
        }
    }

    nonisolated struct Entry: Codable, Equatable {
        var fingerprint: Fingerprint
        var prefixDigest: String
        var boundaryDigest: String
        var offset: Int64
        var records: [ClientUsageRecord]
        var hasErrors: Bool
        var tailHasErrors: Bool
    }

    nonisolated struct Cache: Codable, Equatable {
        var version = 2
        var files: [String: Entry] = [:]
    }

    static func key(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(path: String) throws -> Fingerprint {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CallAnalyticsReadError.unreadable
        }
        return Fingerprint(info)
    }

    /// 用 fstat 冻结本轮文件边界，追加内容留待下一轮；每块检查取消，避免巨型日志占住刷新任务。
    /// EOF 没有换行的片段可临时解析，但 offset 仍停留在片段开始，下轮追加会完整重读该行。
    static func read(path: String, previous: Entry?,
                     bytesRead: (Int64) -> Void,
                     parse: (Data) -> (record: ClientUsageRecord?, hasErrors: Bool)) throws -> Entry {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CallAnalyticsReadError.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CallAnalyticsReadError.unreadable
        }
        let current = Fingerprint(info)
        // 枚举与打开之间文件可能已替换，实际描述符的指纹才是游标归属依据。
        var base = previous.flatMap { entry in
            entry.offset >= 0 && entry.offset <= entry.fingerprint.size
                && (entry.fingerprint == current || entry.fingerprint.canAppend(to: current)) ? entry : nil
        }
        // stat 无法区分“原地改写后变大”与正常追加。仅对变化文件核验前缀和旧 EOF 附近各 4 KiB，
        // 发现正文边界变化就丢弃旧游标。缓存只保存 SHA-256；未变化文件仍完全不打开日志。
        func anchors(size: Int64) throws -> (prefix: String, boundary: String) {
            func digest(at offset: Int64, count: Int) throws -> String {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: count) ?? Data()
                bytesRead(Int64(data.count))
                guard data.count == count else { throw CallAnalyticsReadError.unreadable }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let width = Int(min(4096, size))
            let prefix = try digest(at: 0, count: width)
            let boundary: String
            if size <= 4096 { boundary = prefix }
            else { boundary = try digest(at: size - Int64(width), count: width) }
            return (prefix, boundary)
        }
        if let old = base {
            let oldAnchors = try anchors(size: old.fingerprint.size)
            if oldAnchors.prefix != old.prefixDigest || oldAnchors.boundary != old.boundaryDigest { base = nil }
        }
        let currentAnchors = try anchors(size: current.size)
        var offset = base?.offset ?? 0
        var messages = Dictionary((base?.records ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            first.total > second.total ? first : second
        })
        var hasErrors = base?.hasErrors ?? false
        var tailHasErrors = false
        var pending = Data()
        var oversized = false
        let lineLimit = 16 * 1024 * 1024
        try handle.seek(toOffset: UInt64(offset))
        var position = offset
        var lines = 0
        func consume(_ data: Data, tail: Bool) {
            let result = parse(data)
            if tail { tailHasErrors = result.hasErrors } else { hasErrors = hasErrors || result.hasErrors }
            if let record = result.record, messages[record.id].map({ $0.total <= record.total }) ?? true {
                messages[record.id] = record
            }
        }
        while position < current.size {
            try Task.checkCancellation()
            let count = Int(min(1024 * 1024, current.size - position))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                // 扫描途中截断，不能提交指向未读内容的检查点；调用方仍可重放原缓存。
                throw CallAnalyticsReadError.unreadable
            }
            bytesRead(Int64(chunk.count))
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let newline = chunk[start...].firstIndex(of: 0x0A)
                let end = newline ?? chunk.endIndex
                let segment = chunk[start..<end]
                if !oversized {
                    if pending.count + segment.count > lineLimit { oversized = true; pending.removeAll(keepingCapacity: true) }
                    else { pending.append(contentsOf: segment) }
                }
                guard let newline else { break }
                if oversized { hasErrors = true } else if !pending.isEmpty { consume(pending, tail: false) }
                offset = position + Int64(newline - chunk.startIndex + 1)
                pending.removeAll(keepingCapacity: true); oversized = false
                start = newline + 1
                lines += 1
                if lines % 256 == 0 { try Task.checkCancellation() }
            }
            position += Int64(chunk.count)
        }
        if oversized { tailHasErrors = true }
        else if !pending.isEmpty { consume(pending, tail: true) }
        try Task.checkCancellation()
        return Entry(fingerprint: current, prefixDigest: currentAnchors.prefix, boundaryDigest: currentAnchors.boundary,
                     offset: offset, records: messages.values.sorted { $0.id < $1.id },
                     hasErrors: hasErrors, tailHasErrors: tailHasErrors)
    }
}
