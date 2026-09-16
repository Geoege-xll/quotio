import XCTest
import SQLite3
import Synchronization
@testable import QuotioPlus

/// 使用独立临时 Home 和真实 SQLite 写锁复现删除等待，绝不删除本机客户端会话。
/// 检查等待期间主线程能否继续响应，比只断言删除最终成功更能覆盖界面卡顿回归。
final class WorkspaceSessionPerformanceTests: XCTestCase {
    @MainActor
    func testDeletionKeepsMainActorResponsiveWhileDatabaseIsLocked() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDeletionPerformance-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(".codex/sessions/main.jsonl").path
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"main\",\"source\":\"cli\"}}\n".write(toFile: path, atomically: true, encoding: .utf8)
        let database = home.appendingPathComponent(".codex/state_5.sqlite").path
        try Self.withDatabase(database) { handle in
            try Self.execute(handle, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT)")
            try Self.execute(handle, "INSERT INTO threads VALUES ('main', '\(path)', 'cli')")
        }

        let locked = expectation(description: "独立连接已持有 SQLite 写锁")
        let probe = DeletionHeartbeatProbe()
        let holding = Task.detached {
            try Self.withDatabase(database) { handle in
                try Self.execute(handle, "BEGIN IMMEDIATE")
                probe.setLocked(true)
                locked.fulfill()
                // 固定的锁占用模拟真实客户端写入；计时只制造阻塞，不用毫秒阈值断言机器性能。
                Thread.sleep(forTimeInterval: 0.4)
                probe.setLocked(false)
                try Self.execute(handle, "COMMIT")
            }
        }
        await fulfillment(of: [locked], timeout: 3)
        let heartbeat = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(50))
            probe.recordHeartbeat()
        }
        let service = WorkspaceSessionService(homeDir: home.path)
        let deleted = try await service.deleteSession(Self.session("main", path: path))
        try await holding.value
        try await heartbeat.value
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(probe.respondedWhileLocked, "SQLite 等待期间主线程必须继续处理事件，不能等删除结束才恢复响应")
    }

    @MainActor
    func testSessionListDerivationForLargeWorkflow() {
        let vm = WorkspaceViewModel()
        vm.selectedAgentFilter = .codex
        let records = (0..<120).flatMap { index in
            [Self.session("root-\(index)")] + (0..<20).map { child in
                Self.session("child-\(index)-\(child)", parent: "root-\(index)")
            }
        }
        vm.sessions = records
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            // 与列表真实读取方式一致：每个主会话都需要子任务计数，选中和折叠会再次读取。
            for _ in 0..<3 {
                XCTAssertEqual(vm.projectGroups.flatMap(\.sessions).count, 120)
                XCTAssertEqual(vm.rootFilteredSessions.reduce(0) { $0 + vm.descendantRows(for: $1).count }, 2_400)
            }
        }
        print("Workspace session list: 2520 records, 3 render reads, \(elapsed)")
        // 删除、搜索和切换客户端都必须使派生数据失效，不能为了缓存保留旧行。
        vm.sessions.removeAll { $0.id == "root-0" || $0.parentSessionID == "root-0" }
        XCTAssertEqual(vm.rootFilteredSessions.count, 119)
        vm.sessionSearchText = "child-1-0"
        XCTAssertEqual(vm.rootFilteredSessions.map(\.id), ["root-1"])
        vm.selectedAgentFilter = .claude
        XCTAssertTrue(vm.rootFilteredSessions.isEmpty)
        XCTAssertTrue(vm.projectGroups.isEmpty)
    }

    private nonisolated static func session(_ id: String, path: String = "/fixture.jsonl", parent: String? = nil) -> WorkspaceSession {
        WorkspaceSession(id: id, agent: .codex, title: id, projectName: "agent_workflow", lastActiveAt: .distantPast,
                         filePath: path, fileSizeBytes: 0, messageCount: 0, resumeCommand: "", parentSessionID: parent)
    }

    private nonisolated static func withDatabase(_ path: String, body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(handle) }
        try body(handle)
    }

    private nonisolated static func execute(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}

/// 锁状态与心跳由不同执行器写入，使用 Mutex 保证检测本身没有数据竞争。
private nonisolated final class DeletionHeartbeatProbe: Sendable {
    private let state = Mutex((locked: false, responded: false))
    func setLocked(_ value: Bool) { state.withLock { $0.locked = value } }
    func recordHeartbeat() { state.withLock { $0.responded = $0.locked } }
    var respondedWhileLocked: Bool { state.withLock { $0.responded } }
}
