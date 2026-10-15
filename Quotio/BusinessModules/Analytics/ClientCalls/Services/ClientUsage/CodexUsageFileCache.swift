// Codex 增量索引只保存统计元数据；原始会话 ID、文件路径、正文和半行内容均不落盘。
import Foundation
import Darwin

nonisolated struct CodexUsageFileStamp: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    init(path: String) throws {
        var value = stat()
        guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else { throw CallAnalyticsReadError.unreadable }
        device = UInt64(value.st_dev); inode = UInt64(value.st_ino); size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }
    /// 指纹按标量列存储；UInt64 inode 使用位模式恢复，避免大 inode 在转换时溢出。
    init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanos: Int64,
         changedSeconds: Int64, changedNanos: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanos = modifiedNanos
        self.changedSeconds = changedSeconds; self.changedNanos = changedNanos
    }
    func mayAppend(to old: Self) -> Bool { device == old.device && inode == old.inode && size > old.size }
}

nonisolated struct CodexUsageFileCache: Codable, Equatable {
    // v2 修正无关大行及 fork 继承元数据；旧缓存只用于历史检查点恢复，必须重扫源文件。
    var version = 2
    let stamp: CodexUsageFileStamp
    /// 仅推进到换行之后。未完成行下次从原位置重读，不能把半个 JSON 当作永久坏记录。
    let offset: Int64
    let ordinal: Int
    let model: String
    let hashedSessionID: String
    let foundMetadata: Bool
    let hasErrors: Bool
    let prefixHash: String
    let boundaryHash: String
    let checkpoints: [CodexUsageCheckpoint]

    /// 扫描完成后只保留追加读取所需的水位，已落盘检查点由账本按需消费。
    var withoutCheckpoints: Self {
        Self(version: version, stamp: stamp, offset: offset, ordinal: ordinal, model: model,
             hashedSessionID: hashedSessionID, foundMetadata: foundMetadata, hasErrors: hasErrors,
             prefixHash: prefixHash, boundaryHash: boundaryHash, checkpoints: [])
    }

    /// 可丢弃缓存也要验证计数边界，损坏数据不能进入差额计算造成溢出。
    var isValid: Bool {
        guard (1...2).contains(version), offset >= 0, offset <= stamp.size, ordinal >= 0, hashedSessionID.count == 64,
              model.count <= 512 else { return false }
        return checkpoints.allSatisfy { checkpoint in
            checkpoint.id.count == 64 && checkpoint.sessionID.count == 64
                && [checkpoint.cumulative, checkpoint.last].compactMap { $0 }.allSatisfy { tokens in
                    [tokens.input, tokens.output, tokens.cached, tokens.reasoning, tokens.total]
                        .allSatisfy { $0 >= 0 && $0 <= 2_000_000_000_000 }
                }
        }
    }

    static func directory(base: URL) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + ".files", isDirectory: true)
    }

    static func url(base: URL, path: String) -> URL {
        directory(base: base).appendingPathComponent(key(path: path))
    }

    /// 新数据库沿用旧逐文件 JSON 的键，迁移后可以直接匹配相同日志。
    static func key(path: String) -> String {
        // macOS 的 /var 与 /private/var 可由 URL 枚举返回不同拼写，散列前统一物理路径。
        // 这里只统一缓存键，不存储路径；实际日志打开仍使用 O_NOFOLLOW 的只读校验。
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return ClientUsageDigest.sha256(normalized) + ".json"
    }
}

/// 支持偏移量的独立只读流。每个块报告真实读取字节，取消最多等待当前块/当前 JSON 行结束。
/// 文件按打开时的大小设置上界，避免正在不断追加的活跃日志让一次刷新永远追不到 EOF。
nonisolated enum CodexUsageLineReader {
    struct Result { let offset: Int64; let oversized: Bool }
    static func read(path: String, offset: Int64, limit: Int64, acceptFinalLine: Bool,
                     progress: (Int64) -> Void,
                     isIrrelevantLine: (Data) -> Bool = { _ in false },
                     onLine: (Data) throws -> Void) throws -> Result {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CallAnalyticsReadError.unreadable }
        defer { close(descriptor) }
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { throw CallAnalyticsReadError.unreadable }
        let capacity = 1024 * 1024, maxLine = 4 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        var line = Data(), position = offset, complete = offset
        var oversized = false, lineTooLarge = false
        while position < limit {
            try Task.checkCancellation()
            let requested = Int(min(Int64(capacity), limit - position))
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, requested) }
            guard count >= 0 else { throw CallAnalyticsReadError.unreadable }
            if count == 0 { break }
            progress(Int64(count))
            try buffer.withUnsafeBufferPointer { bytes in
                let base = bytes.baseAddress!
                var cursor = 0
                while cursor < count {
                    let remaining = count - cursor
                    let newline = memchr(base.advanced(by: cursor), 10, remaining)
                    let end = newline.map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? count
                    let length = end - cursor
                    // 即使跨越缓冲上限也保留有界前缀，用结构化事件头判断是否与统计无关。
                    // 无关 compacted/图片/工具输出的大正文不再污染整份统计的错误状态。
                    if length > maxLine - line.count { lineTooLarge = true }
                    let retained = min(length, maxLine - line.count)
                    if retained > 0 { line.append(base.advanced(by: cursor), count: retained) }
                    if newline != nil {
                        try Task.checkCancellation()
                        if !line.isEmpty, !isIrrelevantLine(line) {
                            if lineTooLarge { oversized = true }
                            else { try onLine(line) }
                        }
                        line.removeAll(keepingCapacity: true); lineTooLarge = false
                        complete = position + Int64(end + 1)
                    }
                    cursor = end + (newline == nil ? 0 : 1)
                }
            }
            position += Int64(count)
        }
        if !lineTooLarge, !line.isEmpty {
            // JSONL 最后一条完整对象可能尚未写换行：验证完整 JSON 后可以消费。
            // 未完成对象不推进 offset，也不把正文片段写入缓存，追加时从行首重新读取。
            if acceptFinalLine || (try? JSONSerialization.jsonObject(with: line)) != nil {
                if !isIrrelevantLine(line) { try onLine(line) }
                complete = position
            }
        }
        return Result(offset: complete, oversized: oversized)
    }

    /// append 只校验旧文件头与已消费边界附近。读数包含这些校验字节，UI 不伪报零 I/O。
    static func sample(path: String, offset: Int64, count: Int, progress: (Int64) -> Void) throws -> Data {
        try Task.checkCancellation()
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CallAnalyticsReadError.unreadable }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: max(0, count))
        let readCount = bytes.withUnsafeMutableBytes { raw in
            Darwin.pread(descriptor, raw.baseAddress, count, off_t(offset))
        }
        guard readCount >= 0 else { throw CallAnalyticsReadError.unreadable }
        progress(Int64(readCount))
        return Data(bytes.prefix(readCount))
    }
}

/// 只读取 JSON 信封的结构化字符串字段，不在正文中查找类型名称。
/// 字节扫描最多查看 64 KiB 头部，正确跳过转义字符串、嵌套对象和数组；
/// 无法确认信封时返回未知，让调用者保留严格解析/不完整状态，而不是猜测成功。
nonisolated enum CodexLogEnvelope {
    static func isIrrelevantToUsage(_ line: Data) -> Bool {
        guard let type = string("type", in: line) else { return false }
        switch type {
        case "session_meta", "turn_context": return false
        case "event_msg":
            guard let event = string("type", in: line, inPayload: true) else { return false }
            return event != "token_count"
        default: return true
        }
    }

    static func isIrrelevantToCalls(_ line: Data) -> Bool {
        guard let type = string("type", in: line) else { return false }
        guard type == "response_item" || type == "event_msg" else { return true }
        guard let event = string("type", in: line, inPayload: true) else { return false }
        if type == "response_item" {
            return event != "function_call" && event != "custom_tool_call"
        }
        return event != "mcp_tool_call_end"
    }

    private static func string(_ key: String, in data: Data, inPayload: Bool = false) -> String? {
        let bytes = Array(data.prefix(65_536))
        var index = 0
        var depth = 0
        var insidePayload = false

        func skipWhitespace(_ start: Int) -> Int {
            var cursor = start
            while cursor < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[cursor]) { cursor += 1 }
            return cursor
        }
        func closingQuote(_ start: Int) -> Int? {
            var cursor = start + 1
            var escaped = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { return cursor }
                cursor += 1
            }
            return nil
        }
        func decodedString(_ start: Int, _ end: Int) -> String? {
            // 用系统 JSON 解码处理键名转义，不能用简单 replace 改变真实字段语义。
            (try? JSONSerialization.jsonObject(with: Data(bytes[start...end]), options: .fragmentsAllowed)) as? String
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 || byte == 91 {
                depth += 1
            } else if byte == 125 || byte == 93 {
                depth -= 1
                if depth < 2 { insidePayload = false }
            } else if byte == 34 {
                guard let end = closingQuote(index) else { return nil }
                let separator = skipWhitespace(end + 1)
                if separator < bytes.count, bytes[separator] == 58 {
                    let valueStart = skipWhitespace(separator + 1)
                    let name = decodedString(index, end)
                    if depth == 1, name == "payload", valueStart < bytes.count, bytes[valueStart] == 123 {
                        insidePayload = true
                    }
                    let matchesScope = inPayload ? (insidePayload && depth == 2) : depth == 1
                    if matchesScope, name == key {
                        guard valueStart < bytes.count, bytes[valueStart] == 34,
                              let valueEnd = closingQuote(valueStart) else { return nil }
                        return decodedString(valueStart, valueEnd)
                    }
                }
                index = end
            }
            index += 1
        }
        return nil
    }
}
