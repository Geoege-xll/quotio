// 大历史和增量行为只使用可删除的合成日志，不读取真实用户数据；进度只记录字节与计数。
import XCTest
import Foundation
@testable import Quotio

final class CodexClientUsagePerformanceTests: XCTestCase {
    private nonisolated final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ClientUsageProgress(source: .codex)
        func set(_ progress: ClientUsageProgress) { lock.lock(); value = progress; lock.unlock() }
        func get() -> ClientUsageProgress { lock.lock(); defer { lock.unlock() }; return value }
    }
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotio-codex-incremental-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func line(_ object: [String: Any]) throws -> Data {
        var value = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); value.append(10); return value
    }
    private func metadata(_ id: String = "PRIVATE_SESSION_ID", parent: String? = nil) throws -> Data {
        var payload: [String: Any] = ["id": id, "timestamp": "2026-09-05T10:00:00Z"]
        if let parent { payload["forked_from_id"] = parent }
        return try line(["type": "session_meta", "payload": payload])
    }
    private func usage(_ tokens: Int, time: String = "2026-09-05T10:01:00Z") throws -> Data {
        try line(["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": tokens, "output_tokens": 0, "total_tokens": tokens]]]])
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func scan(_ root: URL, box: ProgressBox = ProgressBox(), project: Bool = true) throws -> ClientUsageScan {
        try CodexClientUsageSource(homeDirectory: root.path, environment: [:]).collect(
            cacheURL: root.appendingPathComponent("private-index.json"), progress: { box.set($0) }, projectRecords: project)
    }

    func testLargeHistoryReopenSkipsAllUnchangedLogBytesAndKeepsCheckpoints() throws {
        let root = try home(), file = root.appendingPathComponent(".codex/sessions/large.jsonl")
        try metadata().write(to: file)
        let context = try line(["type": "turn_context", "payload": ["model": "fixture-model"]])
        try append(context, to: file)
        // 32 MiB 真实落盘的无关输出行，确认首次扫描面对正文量而不是仅两个 Token fixture。
        let filler = try line(["type": "response_item", "payload": ["type": "function_call_output", "output": String(repeating: "PRIVATE_OUTPUT", count: 80)]])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        for _ in 0..<32_768 { try handle.write(contentsOf: filler) }
        try handle.close()
        try append(usage(100), to: file)
        let firstProgress = ProgressBox(), start = Date()
        let first = try scan(root, box: firstProgress)
        XCTAssertFalse(first.hasErrors)
        XCTAssertEqual(first.records.first?.total, 100)
        XCTAssertEqual(first.records.first?.model, "fixture-model")
        XCTAssertGreaterThan(firstProgress.get().bytesRead, 32 * 1024 * 1024)
        // 新建 source 的第二次调用等价重开应用，不能依赖进程内状态。
        let reopenedProgress = ProgressBox(), reopened = try scan(root, box: reopenedProgress, project: false)
        XCTAssertEqual(reopened.codexCheckpoints, first.codexCheckpoints)
        XCTAssertTrue(reopened.records.isEmpty)
        XCTAssertEqual(reopenedProgress.get().bytesRead, 0)
        XCTAssertEqual(reopenedProgress.get().filesReused, 1)
        print("Codex synthetic first scan seconds=\(Date().timeIntervalSince(start)), bytes=\(firstProgress.get().bytesRead), reopened bytes=\(reopenedProgress.get().bytesRead)")
        let cache = CodexUsageFileCache.url(base: root.appendingPathComponent("private-index.json"), path: file.path)
        let physicalCache = CodexUsageFileCache.url(base: root.appendingPathComponent("private-index.json"),
            path: file.resolvingSymlinksInPath().path)
        XCTAssertEqual(cache, physicalCache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "不再创建逐文件 JSON 索引")
        let sqliteURL = AnalyticsDatabase.storeURL(forLegacyURL: root.appendingPathComponent("private-index.json"))
        let store = ClientUsageSQLiteStore(databaseURL: sqliteURL)
        let caches = try store.loadCodexCaches(legacyURL: nil)
        let saved = String(decoding: try JSONEncoder().encode(caches), as: UTF8.self)
        XCTAssertFalse(saved.contains("PRIVATE_SESSION_ID")); XCTAssertFalse(saved.contains("PRIVATE_OUTPUT"))
        XCTAssertFalse(saved.contains(file.path))
    }

    func testAppendReadsOnlyTailAndRetainsModelAndPreviousCheckpoints() throws {
        let root = try home(), file = root.appendingPathComponent(".codex/sessions/append.jsonl")
        var data = try metadata()
        data.append(try line(["type": "turn_context", "payload": ["model": "model-before-append"]]))
        let filler = try line(["type": "response_item", "payload": ["output": String(repeating: "x", count: 2048)]])
        for _ in 0..<1024 { data.append(filler) }
        data.append(try usage(100)); try data.write(to: file)
        let first = try scan(root)
        try append(usage(160, time: "2026-09-05T10:02:00Z"), to: file)
        let progress = ProgressBox(), second = try scan(root, box: progress)
        XCTAssertEqual(second.records.map(\.total), [100, 60])
        XCTAssertEqual(second.records.map(\.model), ["model-before-append", "model-before-append"])
        XCTAssertEqual(second.records.first?.id, first.records.first?.id)
        XCTAssertLessThan(progress.get().bytesRead, 150_000)
        XCTAssertGreaterThan(progress.get().bytesRead, 0)
    }

    func testPartialLastLineIsReplayedOnlyWhenCompleted() throws {
        let root = try home(), file = root.appendingPathComponent(".codex/sessions/partial.jsonl")
        var data = try metadata(); data.append(try usage(100))
        let next = try usage(160, time: "2026-09-05T10:02:00Z"), split = next.count / 2
        data.append(next.prefix(split)); try data.write(to: file)
        XCTAssertEqual(try scan(root).records.map(\.total), [100])
        try append(Data(next.dropFirst(split)), to: file)
        XCTAssertEqual(try scan(root).records.map(\.total), [100, 60])
        XCTAssertEqual(try scan(root).records.map(\.total), [100, 60])
    }

    func testTruncationAndAtomicReplacementInvalidateFileCache() throws {
        let root = try home(), file = root.appendingPathComponent(".codex/sessions/replaced.jsonl")
        var old = try metadata(); old.append(try usage(100)); try old.write(to: file)
        _ = try scan(root)
        var truncated = try metadata("new"); truncated.append(try usage(3)); try truncated.write(to: file)
        XCTAssertEqual(try scan(root).records.map(\.total).sorted(), [3, 100])
        var replacement = try metadata("replacement-session"); replacement.append(try usage(500))
        try replacement.write(to: file, options: .atomic)
        let progress = ProgressBox(), result = try scan(root, box: progress)
        XCTAssertEqual(result.records.map(\.total).sorted(), [3, 100, 500])
        XCTAssertEqual(progress.get().filesReused, 0)
    }

    func testArchivedCopyAndForkStillProjectTogetherFromPersistentCaches() throws {
        let root = try home(), parent = root.appendingPathComponent(".codex/sessions/parent.jsonl")
        var parentData = try metadata("parent"); parentData.append(try usage(100, time: "2026-09-05T09:59:00Z")); try parentData.write(to: parent)
        _ = try scan(root)
        let archived = root.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: parent, to: archived.appendingPathComponent("parent-copy.jsonl"))
        var child = try metadata("child", parent: "parent"); child.append(try usage(130))
        try child.write(to: root.appendingPathComponent(".codex/sessions/child.jsonl"))
        let result = try scan(root)
        XCTAssertFalse(result.hasErrors)
        XCTAssertEqual(result.records.map(\.total), [100, 30])
        XCTAssertEqual(try scan(root).records.map(\.total), [100, 30])
    }

    func testCancellationKeepsFinishedFileCacheForNextScan() async throws {
        let root = try home()
        var data = try metadata("first"); data.append(try usage(1))
        try data.write(to: root.appendingPathComponent(".codex/sessions/a.jsonl"))
        var second = try metadata("second"); second.append(try usage(2))
        try second.write(to: root.appendingPathComponent(".codex/sessions/z.jsonl"))
        let task = Task.detached {
            try CodexClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheURL: root.appendingPathComponent("private-index.json"), progress: { value in
                if value.filesCompleted == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; XCTFail("必须传播取消，不能发布空结果") }
        catch is CancellationError {}
        let progress = ProgressBox(), result = try scan(root, box: progress)
        XCTAssertEqual(progress.get().filesReused, 1)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 3)
    }

    /// 文件缓存已提交、永久账本尚未 merge 就取消；删除日志后仍必须重放孤儿缓存。
    func testCancelledBeforePermanentMergeThenDeletedLogReplaysOrphanCache() async throws {
        let root = try home(), file = root.appendingPathComponent(".codex/sessions/only.jsonl")
        var data = try metadata(); data.append(try usage(77)); try data.write(to: file)
        let task = Task.detached {
            try CodexClientUsageSource(homeDirectory: root.path, environment: [:]).collect(
                cacheURL: root.appendingPathComponent("private-index.json"), progress: { progress in
                    if progress.filesCompleted == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }, projectRecords: false)
        }
        do { _ = try await task.value; XCTFail("必须传播取消") } catch is CancellationError {}
        try FileManager.default.removeItem(at: file)
        let progress = ProgressBox(), recovered = try scan(root, box: progress)
        XCTAssertFalse(recovered.hasErrors)
        XCTAssertEqual(recovered.records.map(\.total), [77])
        XCTAssertEqual(progress.get().bytesRead, 0)
        XCTAssertEqual(recovered.filesScanned, 0)
        let handoff = try scan(root, project: false)
        XCTAssertEqual(handoff.codexCheckpoints, recovered.codexCheckpoints)
    }

    func testLongSingleSessionProjectionKeepsAllDeltas() {
        let tokens = CodexUsageCheckpoint.Tokens.self, start = Date()
        let checkpoints = (1...20_000).map { count in
            CodexUsageCheckpoint(rawSessionID: "long-session", rawParentSessionID: nil,
                timestamp: Date(timeIntervalSince1970: Double(count)), forkDate: nil, model: "fixture",
                cumulative: tokens.init(input: count, output: 0, cached: 0, reasoning: 0, total: count), last: nil, ordinal: count)
        }
        let result = CodexClientUsageSource.project(checkpoints: checkpoints)
        XCTAssertFalse(result.hasErrors); XCTAssertEqual(result.records.count, 20_000)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 20_000)
        print("Codex 20000-checkpoint projection seconds including fixture creation=\(Date().timeIntervalSince(start))")
    }
}
