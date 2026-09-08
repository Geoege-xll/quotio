import XCTest
@testable import Quotio

/// 三客户端数据层的回归只使用临时文件与内存事件，绝不读取真实会话或写入用户账本。
final class ClientUsageTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func line(id: String = "private-message-id", output: Int = 20, model: String = "claude-test") -> String {
        """
        {"type":"assistant","timestamp":"2026-09-05T03:00:00Z","message":{"id":"\(id)","model":"\(model)","content":[{"type":"text","text":"private prompt never retained"}],"usage":{"input_tokens":100,"output_tokens":\(output),"cache_read_input_tokens":30,"cache_creation_input_tokens":5}}}
        """
    }
    private func write(_ lines: [String], root: URL, filename: String = "one.jsonl") throws {
        let dir = root.appendingPathComponent(".claude/projects/project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }
    func testClaudeStreamingMessageAndCopiedLogsOnlyCountOnceWithCacheIncluded() throws {
        let root = try temporary()
        try write([line(output: 2), line(output: 20)], root: root)
        try write([line(output: 20)], root: root, filename: "copy.jsonl")
        let scan = try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect()
        XCTAssertTrue(scan.available); XCTAssertFalse(scan.hasErrors)
        XCTAssertEqual(scan.filesScanned, 2); XCTAssertEqual(scan.records.count, 1)
        let row = try XCTUnwrap(scan.records.first)
        XCTAssertEqual(row.input, 135); XCTAssertEqual(row.cached, 35)
        XCTAssertEqual(row.output, 20); XCTAssertEqual(row.total, 155)
        let data = try JSONEncoder().encode(row)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("private-message-id")); XCTAssertFalse(text.contains("private prompt"))
    }
    func testClaudeMissingAndMalformedSourcesAreNotConfirmedZero() throws {
        let root = try temporary()
        let missing = try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect()
        XCTAssertFalse(missing.available)
        try write([line(), "{\"usage\":broken"], root: root)
        let partial = try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect()
        XCTAssertTrue(partial.hasErrors); XCTAssertEqual(partial.records.count, 1)
    }
    func testClaudeCustomDirectoryAndSyntheticMessages() throws {
        let root = try temporary()
        try write([line(model: "<synthetic>"), line(id: "actual")], root: root)
        let scan = try ClaudeClientUsageSource(homeDirectory: "/unused", environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent(".claude").path]).collect()
        XCTAssertEqual(scan.records.count, 1)
    }
    func testClaudeInvalidTokenFieldsArePartialButLegalZeroIsKnown() throws {
        let root = try temporary()
        let validZero = line(output: 0).replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":0")
            .replacingOccurrences(of: "\"cache_read_input_tokens\":30", with: "\"cache_read_input_tokens\":0")
            .replacingOccurrences(of: "\"cache_creation_input_tokens\":5", with: "\"cache_creation_input_tokens\":0")
        try write([validZero], root: root)
        let zero = try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect()
        XCTAssertTrue(zero.available); XCTAssertFalse(zero.hasErrors); XCTAssertTrue(zero.records.isEmpty)
        for invalid in ["-1", "true", "\"broken\"", "1.5"] {
            try write([validZero.replacingOccurrences(of: "\"input_tokens\":0", with: "\"input_tokens\":\(invalid)")], root: root)
            let failed = try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect()
            XCTAssertTrue(failed.hasErrors, "非法Token不得当作成功扫描的零值")
            XCTAssertTrue(failed.records.isEmpty)
        }
    }
    private func record(_ source: ClientUsageSource, output: Int = 10) -> ClientUsageRecord {
        ClientUsageRecord(identity: "same-message-id", source: source, timestamp: Date(timeIntervalSince1970: 1000),
                          model: "same-model", input: 100, output: output, cached: 20)
    }
    func testClientLedgerRepeatedScansUpdateAndPersistWithoutDoubleCounting() async throws {
        let root = try temporary(); let url = root.appendingPathComponent("usage/ledger.json")
        let engine = ClientUsageEngine(url: url, homeDirectory: root.path, environment: [:])
        let scans = [ClientUsageScan(source: .claude, records: [record(.claude)], filesScanned: 1, available: true)]
        _ = try await engine.merge(scans: scans, at: Date())
        _ = try await engine.merge(scans: scans, at: Date())
        let updated = try await engine.merge(scans: [ClientUsageScan(source: .claude, records: [record(.claude, output: 15)], filesScanned: 1, available: true)], at: Date())
        XCTAssertEqual(updated.records.count, 1); XCTAssertEqual(updated.records.first?.total, 115)
        let reopened = try await ClientUsageEngine(url: url, homeDirectory: root.path, environment: [:]).load()
        XCTAssertEqual(reopened.records, updated.records)
        let databaseURL = AnalyticsDatabase.storeURL(forLegacyURL: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "新账本只写 SQLite，不创建旧 JSON")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
    }
    func testSourcesRemainIndependentAndCombinedHasNoCPACopy() async throws {
        let root = try temporary()
        let engine = ClientUsageEngine(url: root.appendingPathComponent("ledger.json"), homeDirectory: root.path, environment: [:])
        let scans = ClientUsageSource.allCases.map { ClientUsageScan(source: $0, records: [record($0)], filesScanned: 1, available: true) }
        let snapshot = try await engine.merge(scans: scans, at: Date())
        XCTAssertEqual(snapshot.records.count, ClientUsageSource.allCases.count, "同名模型和相同消息ID在不同客户端保持独立")
        XCTAssertEqual(UsageTotals(buckets: snapshot.buckets(source: nil)).totalTokens, 110 * ClientUsageSource.allCases.count)
        for source in ClientUsageSource.allCases {
            XCTAssertEqual(UsageTotals(buckets: snapshot.buckets(source: source)).totalTokens, 110)
            XCTAssertEqual(snapshot.buckets(source: source).first?.provider, source.title)
        }
    }
    func testMissingSourcePreservesHistoryAndFailedEmptySourceIsUnknown() async throws {
        let root = try temporary()
        let engine = ClientUsageEngine(url: root.appendingPathComponent("ledger.json"), homeDirectory: root.path, environment: [:])
        _ = try await engine.merge(scans: [ClientUsageScan(source: .claude, records: [record(.claude)], available: true)], at: Date())
        let snapshot = try await engine.merge(scans: [ClientUsageScan(source: .claude), ClientUsageScan(source: .codex, available: true, hasErrors: true)], at: Date())
        XCTAssertTrue(snapshot.hasData(source: .claude))
        XCTAssertFalse(snapshot.hasData(source: .codex)); XCTAssertFalse(snapshot.hasData(source: .opencode))
        XCTAssertEqual(snapshot.records.count, 1)
    }
    func testCorruptArchiveIsNotOverwrittenByEmptyImport() async throws {
        let root = try temporary(); let url = root.appendingPathComponent("ledger.json")
        let original = Data("broken".utf8); try original.write(to: url)
        let engine = ClientUsageEngine(url: url, homeDirectory: root.path, environment: [:])
        do { _ = try await engine.merge(scans: [], at: Date()); XCTFail("损坏应报错") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testCodexLatePredecessorReprojectsPersistedDeltasAndSurvivesLogDeletion() async throws {
        let root = try temporary(); let url = root.appendingPathComponent("ledger.json")
        let engine = ClientUsageEngine(url: url, homeDirectory: root.path, environment: [:])
        func checkpoint(_ time: Double, total: Int) -> CodexUsageCheckpoint {
            CodexUsageCheckpoint(rawSessionID: "private-session", rawParentSessionID: nil,
                timestamp: Date(timeIntervalSince1970: time), forkDate: nil, model: "model",
                cumulative: .init(input: total, output: 0, cached: 0, reasoning: 0, total: total), last: nil, ordinal: 0)
        }
        let late = checkpoint(200, total: 100)
        var first = ClientUsageScan(source: .codex, available: true)
        first.codexCheckpoints = [late]
        let original = try await engine.merge(scans: [first], at: Date())
        XCTAssertEqual(original.records.reduce(0) { $0 + $1.total }, 100)
        var second = first
        second.codexCheckpoints = [checkpoint(100, total: 60), late]
        let corrected = try await engine.merge(scans: [second], at: Date())
        XCTAssertEqual(corrected.records.map(\.total).sorted(), [40, 60])
        XCTAssertEqual(corrected.records.reduce(0) { $0 + $1.total }, 100, "迟到前驱不应变成160")
        // 重开后原始前驱文件消失，已保存的检查点仍参加差额重算。
        let reopened = ClientUsageEngine(url: url, homeDirectory: root.path, environment: [:])
        first.codexCheckpoints.append(checkpoint(300, total: 120))
        let retained = try await reopened.merge(scans: [first], at: Date())
        XCTAssertEqual(retained.records.map(\.total).sorted(), [20, 40, 60])
        XCTAssertEqual(retained.records.reduce(0) { $0 + $1.total }, 120)
        let database = AnalyticsDatabase(url: AnalyticsDatabase.storeURL(forLegacyURL: url))
        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM client_usage_checkpoints WHERE session_id='private-session'"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testClientLedgerRejectsSymlinkDestination() async throws {
        let root = try temporary(); let other = root.appendingPathComponent("other.json")
        try Data("keep".utf8).write(to: other)
        let link = root.appendingPathComponent("ledger.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        do { _ = try await ClientUsageEngine(url: link, homeDirectory: root.path).merge(scans: [], at: Date()); XCTFail("不能写入链接") } catch {}
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "keep")
    }
}
