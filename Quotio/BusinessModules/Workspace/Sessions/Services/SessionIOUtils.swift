//
//  SessionIOUtils.swift
//  Quotio
//

import Foundation
import SQLite3

/// 会话 Provider 共用的原文件／日期／UUID 辅助，按完整类型归位且保持 nonisolated。
/// 保留 SQLite 固定表名白名单、UTF-8 完整行读取和头尾边界，不改变读取上限、解析回退或失败语义。
nonisolated enum SessionIOUtils {
    /// 按列探测旧版数据库能力，避免一个可选列缺失导致所有关系字段一起降级。
    /// 表名只接受代码内的固定标识符，不能将会话元数据拼接成 SQL。
    static func columns(in table: String, database: OpaquePointer?) -> Set<String> {
        guard ["threads", "thread_spawn_edges", "conversation_summaries"].contains(table) else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) { names.insert(String(cString: text)) }
        }
        return names
    }

    static func readHeadAndTailLines(path: String, headCount: Int, tailCount: Int) -> (head: [String], tail: [String])? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            // 按完整的换行边界解码，不能把 UTF-8 字节流固定截成 64 KB 后整块丢弃。
            let limit = 2 * 1024 * 1024
            var headData = Data()
            while headData.count < limit && headData.filter({ $0 == 10 }).count < headCount {
                guard let chunk = try handle.read(upToCount: min(64 * 1024, limit - headData.count)), !chunk.isEmpty else { break }
                headData.append(chunk)
            }
            let headAtEnd = UInt64(headData.count) == size
            var headParts = headData.split(separator: 10, omittingEmptySubsequences: false)
            if !headAtEnd && headData.last != 10 { headParts.removeLast() }
            let head = headParts.compactMap { String(data: Data($0), encoding: .utf8) }.filter { !$0.isEmpty }
            // 关系补全只读取头部元数据，避免为数据库已登记的每条会话重复读取大段正文尾部。
            if tailCount == 0 { return (Array(head.prefix(headCount)), []) }
            let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
            try handle.seek(toOffset: offset)
            let tailData = try handle.readToEnd() ?? Data()
            var tailParts = tailData.split(separator: 10, omittingEmptySubsequences: false)
            // 非零偏移可能落在一条 JSON 或一个中文字符中间，首个碎片不能当成完整记录。
            if offset > 0 && !tailParts.isEmpty { tailParts.removeFirst() }
            let tail = tailParts.compactMap { String(data: Data($0), encoding: .utf8) }.filter { !$0.isEmpty }
            return (Array(head.prefix(headCount)), Array(tail.suffix(tailCount)))
        } catch { return nil }
    }

    static func parseDate(_ value: String) -> Date? {
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    static func extractUUID(from string: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        if let match = regex.firstMatch(in: string, range: range),
           let matchRange = Range(match.range, in: string) {
            return String(string[matchRange])
        }
        return nil
    }


}

