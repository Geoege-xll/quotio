// Codex 用量解析回归仅使用临时 JSONL，不读取开发机账号、会话和 API key。
import XCTest
@testable import Quotio

final class CodexClientUsageTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quotio-codex-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ lines: [[String: Any]], at relative: String, home: URL) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try lines.reduce(into: Data()) { data, object in
            data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])); data.append(10)
        }
        try data.write(to: url)
    }
    private func metadata(_ id: String, parent: String? = nil, date: String = "2026-09-05T10:00:00Z") -> [String: Any] {
        var payload: [String: Any] = ["id": id, "timestamp": date, "model_provider": "aiusage-proxy"]
        if let parent { payload["forked_from_id"] = parent }
        return ["type": "session_meta", "timestamp": date, "payload": payload]
    }
    private func context(_ model: String) -> [String: Any] { ["type": "turn_context", "payload": ["model": model]] }
    private func usage(_ input: Int, _ output: Int, cached: Int = 0, reasoning: Int = 0,
                       time: String = "2026-09-05T10:01:00Z", cumulative: Bool = true, model: String? = nil) -> [String: Any] {
        var info: [String: Any] = [cumulative ? "total_token_usage" : "last_token_usage": [
            "input_tokens": input, "output_tokens": output, "cached_input_tokens": cached,
            "reasoning_output_tokens": reasoning, "total_tokens": input + output]]
        if let model { info["model"] = model }
        return ["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": info]]
    }
    private func scan(_ home: URL) throws -> ClientUsageScan {
        try CodexClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
    }

    func testCumulativeSnapshotsUseDeltasAndDoNotExcludeProxyProvider() throws {
        let root = try home()
        try write([metadata("s1"), context("real-model"), usage(100, 20), usage(100, 20, time: "2026-09-05T10:02:00Z"),
                   usage(160, 70, time: "2026-09-05T10:03:00Z")], at: ".codex/sessions/one.jsonl", home: root)
        let result = try scan(root)
        XCTAssertFalse(result.hasErrors)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.map(\.input), [100, 60])
        XCTAssertEqual(result.records.map(\.output), [20, 50])
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 230)
    }

    func testModelSwitchAttributesOnlyNewDeltaAndInfoOverridesContext() throws {
        let root = try home()
        try write([metadata("s1"), context("model-a"), usage(100, 20), context("model-b"),
                   usage(140, 30, time: "2026-09-05T10:02:00Z"),
                   usage(150, 35, time: "2026-09-05T10:03:00Z", model: "model-override")], at: ".codex/sessions/one.jsonl", home: root)
        let result = try scan(root)
        XCTAssertEqual(result.records.map(\.model), ["model-a", "model-b", "model-override"])
        XCTAssertEqual(result.records.map(\.total), [120, 50, 15])
    }

    func testActiveAndArchivedPartialCopiesAreMergedBeforeComputingDeltas() throws {
        let root = try home()
        let first = usage(100, 20), second = usage(160, 70, time: "2026-09-05T10:02:00Z")
        try write([metadata("s1"), context("model-a"), first, second], at: ".codex/sessions/full.jsonl", home: root)
        try write([metadata("s1"), context("model-a"), second], at: ".codex/archived_sessions/partial.jsonl", home: root)
        let result = try scan(root)
        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 230)
        XCTAssertEqual(Set(result.records.map(\.id)).count, result.records.count)
    }

    func testLastUsageFallbackIsNotAddedAgainWhenCumulativeArrives() throws {
        let root = try home()
        let last = usage(12, 7, time: "2026-09-05T10:01:00Z", cumulative: false)
        var both = usage(20, 10, time: "2026-09-05T10:02:00Z")
        var payload = try XCTUnwrap(both["payload"] as? [String: Any])
        var info = try XCTUnwrap(payload["info"] as? [String: Any])
        info["last_token_usage"] = ["input_tokens": 8, "output_tokens": 3]
        payload["info"] = info; both["payload"] = payload
        try write([metadata("s1"), context("model-a"), last, last, both], at: ".codex/sessions/one.jsonl", home: root)
        let result = try scan(root)
        XCTAssertEqual(result.records.map(\.total), [19, 11])
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 30)
    }

    func testCachedAndReasoningAreSubsetsRatherThanAdditionalTokens() throws {
        let root = try home()
        try write([metadata("s1"), context("model-a"), usage(100, 20, cached: 40, reasoning: 15),
                   usage(160, 70, cached: 50, reasoning: 35, time: "2026-09-05T10:02:00Z")], at: ".codex/sessions/one.jsonl", home: root)
        let result = try scan(root)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.input }, 160)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.cached }, 50)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.output }, 70)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.reasoning }, 35)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 230)
    }

    func testForkSubtractsParentAtForkTimeAndSkipsCopiedHistory() throws {
        let root = try home()
        let inherited = usage(100, 20, cached: 40, time: "2026-09-05T10:01:00Z")
        try write([metadata("parent"), context("model-a"), inherited,
                   usage(200, 50, time: "2026-09-05T10:05:00Z")], at: ".codex/sessions/parent.jsonl", home: root)
        try write([metadata("child", parent: "parent", date: "2026-09-05T10:02:00Z"), context("model-a"), inherited,
                   usage(130, 30, cached: 50, time: "2026-09-05T10:03:00Z")], at: ".codex/sessions/child.jsonl", home: root)
        let result = try scan(root)
        XCTAssertFalse(result.hasErrors)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 290)
        let childRecord = try XCTUnwrap(result.records.first { $0.timestamp == ISO8601DateFormatter().date(from: "2026-09-05T10:03:00Z") })
        XCTAssertEqual(childRecord.total, 40)
        XCTAssertEqual(childRecord.cached, 10)
    }

    func testMissingForkParentMarksPartialAndCountsOnlyProvenNewDelta() throws {
        let root = try home()
        try write([metadata("child", parent: "missing"), context("model-a"), usage(100, 20),
                   usage(130, 30, time: "2026-09-05T10:02:00Z")], at: ".codex/sessions/child.jsonl", home: root)
        let result = try scan(root)
        XCTAssertTrue(result.hasErrors)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.total, 40)
    }

    func testUnknownModelAndMalformedFileDoNotHideHealthyRecords() throws {
        let root = try home()
        try write([metadata("good"), usage(10, 3)], at: ".codex/sessions/good.jsonl", home: root)
        let broken = root.appendingPathComponent(".codex/sessions/bad.jsonl")
        try Data("{broken json\n".utf8).write(to: broken)
        let result = try scan(root)
        XCTAssertTrue(result.available)
        XCTAssertTrue(result.hasErrors)
        XCTAssertEqual(result.records.first?.model, "unknown")
        XCTAssertEqual(result.records.first?.total, 13)
    }

    func testOversizedFileIsPartialButOtherSessionStillLoads() throws {
        let root = try home()
        try write([metadata("good"), usage(10, 3)], at: ".codex/sessions/good.jsonl", home: root)
        try Data((String(repeating: "x", count: 4 * 1024 * 1024 + 1) + "\n").utf8)
            .write(to: root.appendingPathComponent(".codex/sessions/huge.jsonl"))
        let result = try scan(root)
        XCTAssertTrue(result.hasErrors)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 13)
    }

    func testMissingSourceHasNoRecordsAndNoSyntheticZeroScan() throws {
        let root = try home()
        let result = try scan(root)
        XCTAssertFalse(result.available)
        XCTAssertFalse(result.hasErrors)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testCustomCodexHomeAndRecordProjectionDoNotPersistRawContent() throws {
        let root = try home()
        var meta = metadata("private-session-id")
        var payload = try XCTUnwrap(meta["payload"] as? [String: Any])
        payload["cwd"] = "SECRET_WORKSPACE_PATH"; payload["api_key"] = "SECRET_CREDENTIAL"
        meta["payload"] = payload
        try write([meta, context("model-a"), usage(10, 3)], at: "custom/sessions/a.jsonl", home: root)
        let result = try CodexClientUsageSource(homeDirectory: root.path, environment: ["CODEX_HOME": root.appendingPathComponent("custom").path]).collect()
        let persisted = String(decoding: try JSONEncoder().encode(result.records), as: UTF8.self)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertFalse(persisted.contains("SECRET_"))
        XCTAssertFalse(persisted.contains("private-session-id"))
    }

    func testCheckpointProjectionRecomputesSmallerDeltaWhenPredecessorArrives() throws {
        let root = try home()
        let later = usage(100, 0, time: "2026-09-05T10:02:00Z")
        try write([metadata("s1"), context("model-a"), later], at: ".codex/sessions/later.jsonl", home: root)
        let first = try scan(root)
        let previousID = try XCTUnwrap(first.records.first?.id)
        XCTAssertEqual(first.records.first?.input, 100)
        try write([metadata("s1"), context("model-a"), usage(60, 0)], at: ".codex/sessions/earlier.jsonl", home: root)
        let second = try scan(root)
        let projection = CodexClientUsageSource.project(checkpoints: first.codexCheckpoints + second.codexCheckpoints)
        XCTAssertFalse(projection.hasErrors)
        XCTAssertEqual(projection.records.reduce(0) { $0 + $1.input }, 100)
        XCTAssertEqual(projection.records.first { $0.id == previousID }?.input, 40)
    }

    func testArchivedCheckpointsKeepBaselineAfterOriginalFilesAreDeleted() throws {
        let root = try home()
        try write([metadata("s1"), context("model-a"), usage(60, 0), usage(100, 0, time: "2026-09-05T10:02:00Z")],
            at: ".codex/sessions/old.jsonl", home: root)
        let saved = try scan(root).codexCheckpoints
        try FileManager.default.removeItem(at: root.appendingPathComponent(".codex/sessions/old.jsonl"))
        try write([metadata("s1"), context("model-a"), usage(130, 0, time: "2026-09-05T10:03:00Z")],
            at: ".codex/sessions/new.jsonl", home: root)
        let fresh = try scan(root)
        let projection = CodexClientUsageSource.project(checkpoints: saved + fresh.codexCheckpoints)
        XCTAssertEqual(projection.records.map(\.input), [60, 40, 30])
        XCTAssertEqual(projection.records.reduce(0) { $0 + $1.input }, 130)
    }

    func testLateParentCheckpointResolvesForkWithoutPersistingFalseReadFailure() throws {
        let root = try home()
        try write([metadata("child", parent: "parent", date: "2026-09-05T10:02:00Z"), context("model-a"),
            usage(130, 30, time: "2026-09-05T10:03:00Z")], at: ".codex/sessions/child.jsonl", home: root)
        let orphan = try scan(root)
        XCTAssertTrue(orphan.hasErrors)
        XCTAssertFalse(orphan.codexReadErrors)
        try write([metadata("parent"), context("model-a"), usage(100, 20)], at: ".codex/sessions/parent.jsonl", home: root)
        let complete = try scan(root)
        let projection = CodexClientUsageSource.project(checkpoints: orphan.codexCheckpoints + complete.codexCheckpoints)
        XCTAssertFalse(projection.hasErrors)
        XCTAssertEqual(projection.records.reduce(0) { $0 + $1.total }, 160)
        XCTAssertEqual(projection.records.last?.total, 40)
    }

    func testCheckpointCodableRoundTripPreservesHashedIdentityAndHidesSessionIdentifiers() throws {
        let root = try home()
        try write([metadata("PRIVATE_RAW_SESSION"), context("model-a"), usage(10, 3)], at: ".codex/sessions/one.jsonl", home: root)
        let original = try scan(root)
        let data = try JSONEncoder().encode(original.codexCheckpoints)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_RAW_SESSION"))
        let decoded = try JSONDecoder().decode([CodexUsageCheckpoint].self, from: data)
        XCTAssertEqual(decoded, original.codexCheckpoints)
        let projected = CodexClientUsageSource.project(checkpoints: decoded)
        XCTAssertEqual(projected.records.map(\.id), original.records.map(\.id))
        XCTAssertEqual(projected.records.first?.id, decoded.first?.id)
        let legacy = Data(#"{"version":1,"records":[],"statuses":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ClientUsageSnapshot.self, from: legacy).codexCheckpoints)
    }

    func testMatchingLastOnlyAndCompletedCumulativeCheckpointAreOneEvent() throws {
        let root = try home()
        let onlyLast = usage(100, 20, cumulative: false)
        try write([metadata("s1"), context("model-a"), onlyLast], at: ".codex/sessions/one.jsonl", home: root)
        let first = try scan(root)
        var completed = usage(100, 20)
        var payload = try XCTUnwrap(completed["payload"] as? [String: Any])
        var info = try XCTUnwrap(payload["info"] as? [String: Any])
        info["last_token_usage"] = ["input_tokens": 100, "output_tokens": 20, "total_tokens": 120]
        payload["info"] = info; completed["payload"] = payload
        try write([metadata("s1"), context("model-a"), completed], at: ".codex/sessions/one.jsonl", home: root)
        let second = try scan(root)
        let projection = CodexClientUsageSource.project(checkpoints: first.codexCheckpoints + second.codexCheckpoints)
        XCTAssertFalse(projection.hasErrors)
        XCTAssertEqual(projection.records.count, 1)
        XCTAssertEqual(projection.records.first?.total, 120)
    }

    func testDistinctLastUsagesAtSameTimestampAreNotGenerallyMerged() throws {
        let root = try home()
        try write([metadata("s1"), context("model-a"), usage(5, 0, cumulative: false), usage(7, 0, cumulative: false)],
            at: ".codex/sessions/one.jsonl", home: root)
        let result = try scan(root)
        XCTAssertFalse(result.hasErrors)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 12)
    }

    func testAmbiguousLastAndTotalAtSameTimestampRemainPartialWithoutInflatingTotal() throws {
        let root = try home()
        try write([metadata("s1"), context("model-a"), usage(100, 0), usage(7, 0, cumulative: false)],
            at: ".codex/sessions/one.jsonl", home: root)
        let result = try scan(root)
        XCTAssertTrue(result.hasErrors)
        XCTAssertFalse(result.codexReadErrors)
        XCTAssertEqual(result.codexCheckpoints.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.total }, 100)
    }

}
