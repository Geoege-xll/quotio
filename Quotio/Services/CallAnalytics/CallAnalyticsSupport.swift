// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 改编自 sylearn/AIUsage（bdb83bbe）；Quotio 修改：隔离扫描、可取消、私有统计归档与原生展示。
// 只保留调用分类与聚合元数据，不归档原始对话、工具参数或凭据。

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Call Analytics Support
// 调用分析的共享底座：流式按行读取（容忍 95MB 级单文件）、本地时区日期键、
// 针对大行的字节级 JSON 字段提取（避免对超大行做整体 JSON 解析），以及计数聚合器。

/// 本地时区时钟：把 ISO8601 / 毫秒时间戳转成 yyyy-MM-dd 日期键。
/// 每个 source 各持一份实例（内部 DateFormatter 非线程安全），避免跨任务共享。
nonisolated struct CallAnalyticsClock {
    let calendar: Calendar
    private let isoWithFraction: ISO8601DateFormatter
    private let isoPlain: ISO8601DateFormatter

    init(timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoWithFraction = withFraction

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.isoPlain = plain
    }

    func date(fromISO text: String) -> Date? {
        isoWithFraction.date(from: text) ?? isoPlain.date(from: text)
    }

    func dayKey(_ date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    func dayKey(fromMillis millis: Int64) -> String {
        dayKey(Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}

// MARK: - Streaming line reader

nonisolated enum CallAnalyticsLineReader {
    /// 逐行回调 `path` 中匹配任一 needle 的行（其余行跳过）。
    /// 每行最多缓冲 `maxLineBytes` 字节（足以覆盖目标字段在行首部的情况），避免巨行撑爆内存。
    static func forEachLine(
        path: String,
        needles: [Data],
        maxLineBytes: Int,
        onLine: (Data) -> Void
    ) throws {
        let cap = max(1, maxLineBytes)
        var lineBuffer = Data()
        var encounteredOversizedLine = false
        lineBuffer.reserveCapacity(min(cap, 64 * 1024))

        func flush() {
            defer { lineBuffer.removeAll(keepingCapacity: true) }
            guard !lineBuffer.isEmpty else { return }
            if !needles.isEmpty {
                let matched = needles.contains { lineBuffer.range(of: $0) != nil }
                guard matched else { return }
            }
            let line = lineBuffer
            autoreleasepool {
                onLine(line)
            }
        }

        #if canImport(Darwin)
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CallAnalyticsReadError.unreadable }
        defer { close(fd) }

        let chunkSize = 128 * 1024
        var readBuffer = [UInt8](repeating: 0, count: chunkSize)

        func appendCapped(_ pointer: UnsafePointer<UInt8>, count: Int) {
            if count > cap - lineBuffer.count { encounteredOversizedLine = true }
            guard count > 0, lineBuffer.count < cap else { return }
            let toAppend = min(count, cap - lineBuffer.count)
            lineBuffer.append(pointer, count: toAppend)
        }

        while true {
            try Task.checkCancellation()
            let bytesRead = readBuffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, chunkSize)
            }
            if bytesRead < 0 { throw CallAnalyticsReadError.unreadable }
            if bytesRead == 0 { break }

            readBuffer.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < bytesRead {
                    let remaining = bytesRead - offset
                    if let found = memchr(base.advanced(by: offset), 0x0A, remaining) {
                        let newline = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        appendCapped(base.advanced(by: offset), count: newline - offset)
                        flush()
                        offset = newline + 1
                    } else {
                        appendCapped(base.advanced(by: offset), count: remaining)
                        offset = bytesRead
                    }
                }
            }
        }
        flush()
        #else
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }
        let newline = Data([0x0A])
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            var start = chunk.startIndex
            while start < chunk.endIndex,
                  let nl = chunk.range(of: newline, options: [], in: start..<chunk.endIndex) {
                let segment = chunk[start..<nl.lowerBound]
                if lineBuffer.count < cap {
                    lineBuffer.append(segment.prefix(cap - lineBuffer.count))
                }
                flush()
                start = nl.upperBound
            }
            if start < chunk.endIndex, lineBuffer.count < cap {
                lineBuffer.append(chunk[start..<chunk.endIndex].prefix(cap - lineBuffer.count))
            }
        }
        flush()
        #endif
        // 超长行不静默丢弃：整来源报告失败，保留上次已验证的摘要。
        if encounteredOversizedLine { throw CallAnalyticsReadError.unreadable }
    }
}

// MARK: - Byte-level JSON field extraction
// 针对超大行（Codex 单行可达数 MB）只取需要的字段，不做整体反序列化。

nonisolated enum CallAnalyticsJSON {
    /// 提取 `data[range]` 中首个 `"key": "value"` 的字符串值（处理转义）。range 为空时全行。
    static func stringValue(forKey key: String, in data: Data, range: Range<Data.Index>? = nil) -> String? {
        let searchRange = range ?? data.startIndex..<data.endIndex
        let needle = Data("\"\(key)\"".utf8)
        var cursor = searchRange.lowerBound
        while cursor < searchRange.upperBound,
              let keyRange = data.range(of: needle, options: [], in: cursor..<searchRange.upperBound) {
            var index = keyRange.upperBound
            skipWhitespace(in: data, index: &index, end: searchRange.upperBound)
            guard index < searchRange.upperBound, data[index] == 0x3A else { cursor = keyRange.upperBound; continue }
            index += 1
            skipWhitespace(in: data, index: &index, end: searchRange.upperBound)
            guard index < searchRange.upperBound, data[index] == 0x22 else { cursor = keyRange.upperBound; continue }
            index += 1
            var bytes: [UInt8] = []
            bytes.reserveCapacity(32)
            var escaped = false
            while index < searchRange.upperBound {
                let byte = data[index]
                index += 1
                if escaped {
                    bytes.append(unescape(byte))
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    return String(bytes: bytes, encoding: .utf8)
                } else {
                    bytes.append(byte)
                }
            }
            return nil
        }
        return nil
    }

    /// 读取 `"key": <number>` 的整数值（不带引号，如 duration 的 secs/nanos）。失败返回 nil。
    static func intValue(forKey key: String, in data: Data, range: Range<Data.Index>? = nil) -> Int64? {
        let searchRange = range ?? data.startIndex..<data.endIndex
        let needle = Data("\"\(key)\"".utf8)
        guard let keyRange = data.range(of: needle, options: [], in: searchRange) else { return nil }
        var index = keyRange.upperBound
        skipWhitespace(in: data, index: &index, end: searchRange.upperBound)
        guard index < searchRange.upperBound, data[index] == 0x3A else { return nil } // ':'
        index += 1
        skipWhitespace(in: data, index: &index, end: searchRange.upperBound)
        var negative = false
        if index < searchRange.upperBound, data[index] == 0x2D { negative = true; index += 1 } // '-'
        var value: Int64 = 0
        var hasDigit = false
        while index < searchRange.upperBound, data[index] >= 0x30, data[index] <= 0x39 {
            let (scaled, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (next, overflow2) = scaled.addingReportingOverflow(Int64(data[index] - 0x30))
            guard !overflow1, !overflow2 else { return nil }
            value = next
            hasDigit = true
            index += 1
        }
        guard hasDigit else { return nil }
        return negative ? -value : value
    }

    /// 返回对象（range 含首尾大括号）的第一个 key 名。用于判定 `result` 是 `Ok` 还是 `Err`，
    /// 避免用整行子串搜索把嵌套正文里的 "Ok"/"Err" 误判。空对象/异常返回 nil。
    static func firstKey(inObject range: Range<Data.Index>, in data: Data) -> String? {
        var index = range.lowerBound
        guard index < range.upperBound, data[index] == 0x7B else { return nil } // '{'
        index += 1
        skipWhitespace(in: data, index: &index, end: range.upperBound)
        guard index < range.upperBound, data[index] == 0x22 else { return nil } // '"'
        index += 1
        var bytes: [UInt8] = []
        var escaped = false
        while index < range.upperBound {
            let byte = data[index]
            index += 1
            if escaped { bytes.append(byte); escaped = false }
            else if byte == 0x5C { escaped = true }
            else if byte == 0x22 { return String(bytes: bytes, encoding: .utf8) }
            else { bytes.append(byte) }
        }
        return nil
    }

    /// 返回 `"key": { ... }` 对象（含大括号）的字节范围。
    static func objectRange(forKey key: String, in data: Data, from start: Data.Index? = nil) -> Range<Data.Index>? {
        let begin = start ?? data.startIndex
        let needle = Data("\"\(key)\"".utf8)
        guard let keyRange = data.range(of: needle, options: [], in: begin..<data.endIndex) else { return nil }
        var index = keyRange.upperBound
        skipWhitespace(in: data, index: &index, end: data.endIndex)
        guard index < data.endIndex, data[index] == 0x3A else { return nil }
        index += 1
        skipWhitespace(in: data, index: &index, end: data.endIndex)
        guard index < data.endIndex, data[index] == 0x7B else { return nil }

        let objStart = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                if depth == 0 { return objStart..<data.index(after: index) }
            }
            index += 1
        }
        return nil
    }

    private static func unescape(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x6E: return 0x0A // \n
        case 0x74: return 0x09 // \t
        case 0x72: return 0x0D // \r
        default: return byte
        }
    }

    private static func skipWhitespace(in data: Data, index: inout Data.Index, end: Data.Index) {
        while index < end {
            switch data[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }
}

// MARK: - Aggregator

/// 把单条调用累加为「日 × 来源 × 类别 × 名称(× server)」计数。
/// Phase 2：可选 `success` / `durationMs` 按「有信号才计入分母」累加，缺失则只加 `count`。
nonisolated struct CallEventAccumulator {
    private struct Key: Hashable {
        let source: CallSourceKind
        let kind: CallKind
        let name: String
        let server: String?
        let agent: String?
        let dayKey: String
    }

    private struct Agg {
        var count = 0
        var outcomeKnown = 0
        var success = 0
        var durationSamples = 0
        var durationMsTotal = 0.0
    }

    private var counts: [Key: Agg] = [:]
    private(set) var eventCount = 0

    mutating func add(
        source: CallSourceKind,
        kind: CallKind,
        name: String,
        server: String?,
        dayKey: String,
        agent: String? = nil,
        success: Bool? = nil,
        durationMs: Double? = nil
    ) {
        let key = Key(source: source, kind: kind, name: name, server: server, agent: agent, dayKey: dayKey)
        var agg = counts[key] ?? Agg()
        agg.count += 1
        if let success {
            agg.outcomeKnown += 1
            if success { agg.success += 1 }
        }
        if let durationMs, durationMs.isFinite, durationMs >= 0 {
            agg.durationSamples += 1
            agg.durationMsTotal += durationMs
        }
        counts[key] = agg
        eventCount += 1
    }

    func entries() -> [CallAnalyticsEntry] {
        counts.map { key, agg in
            CallAnalyticsEntry(
                source: key.source,
                kind: key.kind,
                name: key.name,
                server: key.server,
                agent: key.agent,
                dayKey: key.dayKey,
                count: agg.count,
                outcomeKnownCount: agg.outcomeKnown,
                successCount: agg.success,
                durationSampleCount: agg.durationSamples,
                durationMsTotal: agg.durationMsTotal
            )
        }
    }
}

// MARK: - MCP name normalization

nonisolated enum CallAnalyticsNaming {
    /// 把 Claude 的 `mcp__<server>__<tool>` 拆成 (server, tool)。tool 可能再含下划线，保留其余段。
    static func parseClaudeMCP(_ raw: String) -> (server: String, tool: String)? {
        guard raw.hasPrefix("mcp__") else { return nil }
        let body = String(raw.dropFirst("mcp__".count))
        guard let sep = body.range(of: "__") else { return (server: body, tool: body) }
        let server = String(body[body.startIndex..<sep.lowerBound])
        let tool = String(body[sep.upperBound...])
        return (server: server, tool: tool.isEmpty ? server : tool)
    }

    /// MCP 展示名统一为 `server/tool`。
    static func mcpDisplayName(server: String, tool: String) -> String {
        "\(server)/\(tool)"
    }
}

/// 只暴露固定错误类别，避免文件路径或原始会话内容进入界面和日志。
nonisolated enum CallAnalyticsReadError: Error {
    case unreadable
    case database
    case archive
}
