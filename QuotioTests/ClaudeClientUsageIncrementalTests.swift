import XCTest
@testable import Quotio

/// 所有扫描、落盘和取消用例都在独立临时目录执行，不触碰真实 Claude 日志或用户账本。
final class ClaudeClientUsageIncrementalTests: XCTestCase {
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClientUsageProgress?
        func store(_ progress: ClientUsageProgress) { lock.lock(); defer { lock.unlock() }; value = progress }
        func read() -> ClientUsageProgress? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func fixture() throws -> (root: URL, log: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = root.appendingPathComponent(".claude/projects/private-project-path")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, logs.appendingPathComponent("private-session-path.jsonl"), root.appendingPathComponent("cache/claude.json"))
    }

    private func line(id: String = "secret-message-id", output: Int = 5) -> String {
        """
        {"type":"assistant","timestamp":"2026-09-05T03:00:00Z","message":{"id":"\(id)","model":"claude-test","content":[{"text":"secret conversation body"}],"usage":{"input_tokens":10,"output_tokens":\(output),"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}}
        """
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }

    func testUnchangedReopenReadsZeroBytesAndCacheIsPrivate() throws {
        let paths = try fixture()
        let text = line() + "\n"
        try text.write(to: paths.log, atomically: false, encoding: .utf8)
        let firstProgress = ProgressBox()
        let first = try ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
            .collect(cacheURL: paths.cache, progress: { firstProgress.store($0) })
        XCTAssertEqual(firstProgress.read()?.bytesRead, Int64(text.utf8.count * 2))
        // 使用新 source 实例重开，证明复用来自磁盘，而非某个对象的内存缓存。
        let secondProgress = ProgressBox()
        let second = try ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
            .collect(cacheURL: paths.cache, progress: { secondProgress.store($0) })
        XCTAssertEqual(second.records, first.records)
        XCTAssertEqual(secondProgress.read()?.bytesRead, 0)
        XCTAssertEqual(secondProgress.read()?.filesReused, 1)
        XCTAssertEqual(second.filesScanned, 1)
        let databaseURL = AnalyticsDatabase.storeURL(forLegacyURL: paths.cache)
        let store = ClientUsageSQLiteStore(databaseURL: databaseURL)
        let cache = try store.loadLineCache(source: .claude, legacyURL: nil)
        let json = String(decoding: try JSONEncoder().encode(cache), as: UTF8.self)
        for secret in ["secret-message-id", "secret conversation body", "private-project-path", "private-session-path", paths.root.path] {
            XCTAssertFalse(json.contains(secret), "缓存不能保存原始 ID、正文或路径")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cache.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: paths.cache.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
    }

    func testAppendReadsNewBytesWithBoundedFingerprintProbesAndDeduplicates() throws {
        let paths = try fixture()
        try (line(output: 1) + "\n").write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        _ = try source.collect(cacheURL: paths.cache)
        let appended = line(output: 9) + "\n" + line(id: "another-message", output: 2) + "\n"
        try append(appended, to: paths.log)
        let progress = ProgressBox()
        let scan = try source.collect(cacheURL: paths.cache, progress: { progress.store($0) })
        let read = try XCTUnwrap(progress.read()?.bytesRead)
        XCTAssertGreaterThanOrEqual(read, Int64(appended.utf8.count))
        XCTAssertLessThanOrEqual(read, Int64(appended.utf8.count + 16384))
        XCTAssertEqual(scan.records.count, 2)
        XCTAssertEqual(scan.records.map(\.output).sorted(), [2, 9])
        let copy = paths.log.deletingLastPathComponent().appendingPathComponent("copy.jsonl")
        try (line(output: 9) + "\n").write(to: copy, atomically: false, encoding: .utf8)
        XCTAssertEqual(try source.collect(cacheURL: paths.cache).records, scan.records)
    }

    func testPartialEOFCompletesWithoutLosingOrDuplicatingMessage() throws {
        let paths = try fixture()
        let text = line(output: 8)
        let split = text.index(text.endIndex, offsetBy: -3)
        let firstPart = String(text[..<split])
        try firstPart.write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        let partial = try source.collect(cacheURL: paths.cache)
        XCTAssertTrue(partial.hasErrors); XCTAssertTrue(partial.records.isEmpty)
        try append(String(text[split...]) + "\n", to: paths.log)
        let completed = try source.collect(cacheURL: paths.cache)
        XCTAssertFalse(completed.hasErrors); XCTAssertEqual(completed.records.count, 1)
        XCTAssertEqual(completed.records.first?.output, 8)
        XCTAssertEqual(try source.collect(cacheURL: paths.cache).records, completed.records)
    }

    func testCompleteJSONWithoutNewlineIsReplayedWhenNewlineArrives() throws {
        let paths = try fixture()
        try line().write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        let first = try source.collect(cacheURL: paths.cache)
        XCTAssertEqual(first.records.count, 1); XCTAssertFalse(first.hasErrors)
        try append("\n" + line(id: "second") + "\n", to: paths.log)
        let second = try source.collect(cacheURL: paths.cache)
        XCTAssertEqual(second.records.count, 2); XCTAssertFalse(second.hasErrors)
    }

    func testTruncationAndAtomicReplacementRebuildFileRecords() throws {
        let paths = try fixture()
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        try (line(id: "old-first") + "\n" + line(id: "old-second") + "\n").write(to: paths.log, atomically: false, encoding: .utf8)
        _ = try source.collect(cacheURL: paths.cache)
        // 同一 inode 缩短必须从零重读，旧文件的投影不能附着在新文件上。
        let truncated = line(id: "new") + "\n"
        let handle = try FileHandle(forWritingTo: paths.log)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data(truncated.utf8)); try handle.close()
        let progress = ProgressBox()
        let afterTruncate = try source.collect(cacheURL: paths.cache, progress: { progress.store($0) })
        XCTAssertEqual(afterTruncate.records.count, 1)
        XCTAssertEqual(progress.read()?.bytesRead, Int64(truncated.utf8.count * 2))
        let replacement = line(id: "replacement", output: 99) + "\n"
        try replacement.write(to: paths.log, atomically: true, encoding: .utf8)
        let afterReplace = try source.collect(cacheURL: paths.cache)
        XCTAssertEqual(afterReplace.records.count, 1); XCTAssertEqual(afterReplace.records.first?.output, 99)
    }

    func testEqualSizeOverwriteIsNotReused() throws {
        let paths = try fixture()
        try (line(output: 1) + "\n").write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        _ = try source.collect(cacheURL: paths.cache)
        let handle = try FileHandle(forWritingTo: paths.log)
        try handle.write(contentsOf: Data((line(output: 8) + "\n").utf8)); try handle.close()
        let result = try source.collect(cacheURL: paths.cache)
        XCTAssertEqual(result.records.first?.output, 8)
    }

    func testLargerInPlaceRewriteChecksOldContentBeforeAppending() throws {
        let paths = try fixture()
        let original = line(id: "old-message", output: 1) + "\n"
        try original.write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        _ = try source.collect(cacheURL: paths.cache)
        // 同 inode 从零覆盖且最终更大，仅看文件长度会误用旧 offset；边界散列必须触发全量重建。
        let replacement = line(id: "replacement-first", output: 10) + "\n" + line(id: "replacement-second", output: 20) + "\n"
        let handle = try FileHandle(forWritingTo: paths.log)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8)); try handle.close()
        let result = try source.collect(cacheURL: paths.cache)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.map(\.output).sorted(), [10, 20])
    }

    func testCacheReplaysAfterLogsDisappearBeforeLedgerReceivesRecords() throws {
        let paths = try fixture()
        try (line() + "\n").write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        let first = try source.collect(cacheURL: paths.cache)
        try FileManager.default.removeItem(at: paths.root.appendingPathComponent(".claude/projects"))
        let replayed = try source.collect(cacheURL: paths.cache)
        XCTAssertFalse(replayed.available)
        XCTAssertEqual(replayed.records, first.records, "索引提交后账本未提交，仍必须能恢复全部记录")
    }

    func testLegalZeroAndMalformedFieldsKeepTheirStatusAfterReopen() throws {
        let paths = try fixture()
        let zero = line(output: 0).replacingOccurrences(of: "\"input_tokens\":10", with: "\"input_tokens\":0")
            .replacingOccurrences(of: "\"cache_read_input_tokens\":3", with: "\"cache_read_input_tokens\":0")
            .replacingOccurrences(of: "\"cache_creation_input_tokens\":2", with: "\"cache_creation_input_tokens\":0")
        try (zero + "\n").write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        let first = try source.collect(cacheURL: paths.cache)
        XCTAssertTrue(first.available); XCTAssertFalse(first.hasErrors); XCTAssertTrue(first.records.isEmpty)
        XCTAssertFalse(try source.collect(cacheURL: paths.cache).hasErrors)
        for invalid in ["-1", "true", "\"broken\"", "1.5"] {
            let bad = zero.replacingOccurrences(of: "\"input_tokens\":0", with: "\"input_tokens\":\(invalid)")
            try (bad + "\n").write(to: paths.log, atomically: true, encoding: .utf8)
            XCTAssertTrue(try source.collect(cacheURL: paths.cache).hasErrors)
            XCTAssertTrue(try source.collect(cacheURL: paths.cache).hasErrors, "缓存重放不能抹掉非法字段错误")
        }
    }

    func testCancelledReadDoesNotAdvancePersistedCache() async throws {
        let paths = try fixture()
        try (line() + "\n").write(to: paths.log, atomically: false, encoding: .utf8)
        let source = ClaudeClientUsageSource(homeDirectory: paths.root.path, environment: [:])
        _ = try source.collect(cacheURL: paths.cache)
        let databaseURL = AnalyticsDatabase.storeURL(forLegacyURL: paths.cache)
        let before = try ClientUsageSQLiteStore(databaseURL: databaseURL).loadLineCache(source: .claude, legacyURL: nil)
        try append(String(repeating: line(id: "append-only") + "\n", count: 6000), to: paths.log)
        let task = Task.detached {
            try source.collect(cacheURL: paths.cache, progress: { state in
                if state.bytesRead > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; XCTFail("块读取期间取消应向上传递") }
        catch is CancellationError { }
        let after = try ClientUsageSQLiteStore(databaseURL: databaseURL).loadLineCache(source: .claude, legacyURL: nil)
        XCTAssertEqual(after, before, "取消不能写入前进后的游标或未完成解析记录")
        XCTAssertEqual(try source.collect(cacheURL: paths.cache).records.count, 2)
    }
}
