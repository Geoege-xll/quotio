import XCTest
@testable import Quotio

/// 全部依赖使用内存替身；异步返回顺序由 continuation 控制，
/// 不使用真实 Home、网络或时间等待验证竞态。
final class WorkspaceViewModelSafetyTests: XCTestCase {
    @MainActor
    func testLateRepositoryResponseCannotReplaceCurrentSelection() async {
        let skills = WorkspaceSkillStub()
        await skills.setDeferredDiscovery(true)
        let vm = makeViewModel(skills: skills)
        let first = SkillRepo(owner: "test", name: "slow")
        let second = SkillRepo(owner: "test", name: "fast")
        let firstTask = Task { await vm.fetchDiscoverableSkills(repo: first) }
        await skills.waitForDiscovery(first.id)
        let secondTask = Task { await vm.fetchDiscoverableSkills(repo: second) }
        await skills.waitForDiscovery(second.id)
        await skills.finishDiscovery(second, name: "correct")
        await secondTask.value
        await skills.finishDiscovery(first, name: "stale")
        await firstTask.value
        XCTAssertEqual(vm.selectedRepo?.id, second.id)
        XCTAssertEqual(vm.discoverableSkills.map(\.name), ["correct"])
        XCTAssertFalse(vm.isDiscoveringSkills)
    }

    @MainActor
    func testLateMessageResponseCannotReplaceNewSession() async {
        let service = WorkspaceSessionStub()
        await service.setDeferredMessages(true)
        let vm = makeViewModel(sessions: service)
        let first = session("a")
        let second = session("b")
        let firstTask = Task { await vm.selectSession(first) }
        await service.waitForMessage(first.id)
        let secondTask = Task { await vm.selectSession(second) }
        await service.waitForMessage(second.id)
        await service.finishMessage(second.id, text: "B 的正文")
        await secondTask.value
        await service.finishMessage(first.id, text: "A 的旧正文")
        await firstTask.value
        XCTAssertEqual(vm.selectedSession?.id, "b")
        XCTAssertEqual(vm.selectedSessionMessages.map(\.content), ["B 的正文"])
        XCTAssertFalse(vm.isLoadingMessages)
    }

    @MainActor
    func testClosingDetailInvalidatesPendingMessage() async {
        let service = WorkspaceSessionStub()
        await service.setDeferredMessages(true)
        let vm = makeViewModel(sessions: service)
        let task = Task { await vm.selectSession(session("a")) }
        await service.waitForMessage("a")
        vm.closeSelectedSession()
        await service.finishMessage("a", text: "不应重新显示")
        await task.value
        XCTAssertNil(vm.selectedSession)
        XCTAssertTrue(vm.selectedSessionMessages.isEmpty)
        XCTAssertFalse(vm.isLoadingMessages)
    }

    @MainActor
    func testBatchDeleteKeepsFailedRecordsAndRemovesSuccessfulDescendants() async {
        let service = WorkspaceSessionStub()
        await service.setFailedDeletes(["failed"])
        let vm = makeViewModel(sessions: service)
        vm.sessions = [session("good"), session("child", parent: "good"), session("grandchild", parent: "child"), session("failed")]
        vm.selectedSessionIDs = ["good", "failed"]
        vm.batchDeleteMode = true
        await vm.deleteSelectedBatchSessions()
        XCTAssertEqual(vm.sessions.map(\.id), ["failed"])
        XCTAssertEqual(vm.selectedSessionIDs, ["failed"])
        XCTAssertTrue(vm.batchDeleteMode)
        XCTAssertTrue(vm.errorMessage?.contains("1 项失败") == true)
        XCTAssertNil(vm.toastMessage)
    }

    @MainActor
    func testDeletingPreviousAgentDoesNotDiscardCurrentAgentScan() async {
        let service = WorkspaceSessionStub()
        await service.deferScanAndDelete()
        let vm = makeViewModel(sessions: service)
        let old = session("old")
        vm.sessions = [old]
        let deleting = Task { await vm.deleteSession(old) }
        await service.waitForDelete()
        let switching = Task { await vm.selectAgentFilter(.codex) }
        await service.waitForScan()
        await service.finishDelete()
        await deleting.value
        XCTAssertTrue(vm.isLoadingSessions)
        await service.finishScan([session("new", agent: .codex)])
        await switching.value
        XCTAssertEqual(vm.sessions.map(\.id), ["new"])
        XCTAssertEqual(vm.selectedAgentFilter, .codex)
        XCTAssertFalse(vm.isLoadingSessions)
    }

    @MainActor
    func testRefreshingOldRepositorySnapshotCannotUndoRemovalOrPersistItAgain() async {
        let skills = WorkspaceSkillStub()
        let old = SkillRepo(owner: "test", name: "removed")
        await skills.saveRepos([old])
        await skills.setDeferredLocalLoad(true)
        let vm = makeViewModel(skills: skills)
        vm.repos = [old]
        let refreshing = Task { await vm.refreshSkills() }
        await skills.waitForLocalLoad()
        await vm.removeRepo(old)
        await skills.finishLocalLoad()
        await refreshing.value
        XCTAssertTrue(vm.repos.isEmpty)
        XCTAssertNil(vm.selectedRepo)
        await vm.addRepo(url: "test/new")
        let saved = try? await skills.loadRepos()
        XCTAssertEqual(saved?.map(\.name), ["new"])
        XCTAssertEqual(vm.repos.map(\.name), ["new"])
    }

    @MainActor
    func testAddingRepositoryDuringFirstRefreshPreservesExistingRepositories() async {
        let skills = WorkspaceSkillStub()
        await skills.saveRepos([SkillRepo(owner: "test", name: "existing")])
        await skills.setDeferredLocalLoad(true)
        let vm = makeViewModel(skills: skills)
        let refreshing = Task { await vm.refreshSkills() }
        await skills.waitForLocalLoad()
        await vm.addRepo(url: "test/new")
        await skills.finishLocalLoad()
        await refreshing.value
        let saved = try? await skills.loadRepos()
        XCTAssertEqual(saved?.map(\.name), ["existing", "new"])
        XCTAssertEqual(vm.repos.map(\.name), ["existing", "new"])
    }

    @MainActor
    func testStorageFailureDoesNotShowSuccessfulRelease() async {
        let storage = WorkspaceStorageStub(cacheResult: .init(failures: ["缓存目录不可写"]))
        let vm = makeViewModel(storage: storage)
        await vm.clearAllCaches()
        XCTAssertTrue(vm.errorMessage?.contains("缓存目录不可写") == true)
        XCTAssertNil(vm.toastMessage)
        XCTAssertFalse(vm.isCleaningStorage)
    }

    @MainActor
    func testEmptyInitialDataDoesNotRepeatedlyInitializeServices() async {
        let skills = WorkspaceSkillStub()
        let vm = makeViewModel(skills: skills)
        await vm.loadInitialDataIfNeeded()
        await vm.loadInitialDataIfNeeded()
        let count = await skills.prepareCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSearchRetainsAncestorsAndOrphansRemainVisible() {
        let vm = makeViewModel()
        vm.sessions = [session("root"), session("child", parent: "root"), session("needle", parent: "child"), session("orphan", parent: "missing")]
        XCTAssertEqual(Set(vm.rootFilteredSessions.map(\.id)), ["root", "orphan"])
        vm.sessionSearchText = "needle"
        XCTAssertEqual(vm.rootFilteredSessions.map(\.id), ["root"])
        XCTAssertEqual(vm.descendantRows(for: session("root")).map { $0.session.id }, ["child", "needle"])
    }

    func testTreeTerminatesCyclesAndKeepsDifferentAgentsSeparate() {
        let tree = WorkspaceSessionTree(sessions: [session("a", parent: "b"), session("b", parent: "a"), session("a", agent: .codex)])
        XCTAssertEqual(tree.roots.count, 2)
        XCTAssertEqual(tree.descendants(of: session("a")).map { $0.session.id }, ["b"])
    }

    @MainActor
    private func makeViewModel(
        sessions: WorkspaceSessionStub = WorkspaceSessionStub(),
        skills: WorkspaceSkillStub = WorkspaceSkillStub(),
        storage: WorkspaceStorageStub = WorkspaceStorageStub()
    ) -> WorkspaceViewModel {
        WorkspaceViewModel(sessionService: sessions, skillService: skills, storageService: storage)
    }

    private func session(_ id: String, parent: String? = nil, agent: WorkspaceAgent = .claude) -> WorkspaceSession {
        WorkspaceSession(id: id, agent: agent, title: id, projectName: "test", lastActiveAt: Date(timeIntervalSince1970: 1), filePath: "/fixture/\(id).jsonl", fileSizeBytes: 1, messageCount: 1, resumeCommand: "", parentSessionID: parent)
    }
}

private actor WorkspaceSessionStub: WorkspaceSessionServicing {
    private var deferredMessages = false
    private var failedDeletes: Set<String> = []
    private var pending: [String: CheckedContinuation<[WorkspaceSessionMessage], Error>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]
    func setDeferredMessages(_ value: Bool) { deferredMessages = value }
    func setFailedDeletes(_ ids: Set<String>) { failedDeletes = ids }
    private var deferredScanAndDelete = false
    private var scan: CheckedContinuation<[WorkspaceSession], Never>?
    private var scanObserver: CheckedContinuation<Void, Never>?
    private var deletion: CheckedContinuation<Bool, Never>?
    private var deleteObserver: CheckedContinuation<Void, Never>?
    func deferScanAndDelete() { deferredScanAndDelete = true }
    func scanAllSessions(agentFilter: WorkspaceAgent?) async -> [WorkspaceSession] {
        guard deferredScanAndDelete else { return [] }
        return await withCheckedContinuation {
            scan = $0
            scanObserver?.resume(); scanObserver = nil
        }
    }
    func waitForScan() async {
        guard scan == nil else { return }
        await withCheckedContinuation { scanObserver = $0 }
    }
    func finishScan(_ sessions: [WorkspaceSession]) { scan?.resume(returning: sessions); scan = nil }
    func waitForDelete() async {
        guard deletion == nil else { return }
        await withCheckedContinuation { deleteObserver = $0 }
    }
    func finishDelete() { deletion?.resume(returning: true); deletion = nil }
    func loadSessionMessages(session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        guard deferredMessages else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            pending[session.id] = continuation
            observers.removeValue(forKey: session.id)?.resume()
        }
    }
    func waitForMessage(_ id: String) async {
        guard pending[id] == nil else { return }
        await withCheckedContinuation { observers[id] = $0 }
    }
    func finishMessage(_ id: String, text: String) {
        pending.removeValue(forKey: id)?.resume(returning: [.init(role: .assistant, content: text)])
    }
    func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        if failedDeletes.contains(session.id) { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟删除失败"]) }
        if deferredScanAndDelete {
            return await withCheckedContinuation {
                deletion = $0
                deleteObserver?.resume(); deleteObserver = nil
            }
        }
        return true
    }
    func resumeInTerminal(session: WorkspaceSession) async throws {}
}

private actor WorkspaceSkillStub: WorkspaceSkillServicing {
    private var deferredDiscovery = false
    private var pending: [String: CheckedContinuation<[DiscoverableSkill], Error>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var prepareCount = 0
    func prepareStorage() async throws { prepareCount += 1 }
    private var repos: [SkillRepo] = []
    private var deferredLocalLoad = false
    private var localLoad: CheckedContinuation<[WorkspaceSkill], Never>?
    private var localObserver: CheckedContinuation<Void, Never>?
    func loadRepos() async throws -> [SkillRepo] { repos }
    func saveRepos(_ repos: [SkillRepo]) async { self.repos = repos }
    func setDeferredLocalLoad(_ value: Bool) { deferredLocalLoad = value }
    func loadInstalledSkills() async throws -> [WorkspaceSkill] {
        guard deferredLocalLoad else { return [] }
        return await withCheckedContinuation {
            localLoad = $0
            localObserver?.resume(); localObserver = nil
        }
    }
    func waitForLocalLoad() async {
        guard localLoad == nil else { return }
        await withCheckedContinuation { localObserver = $0 }
    }
    func finishLocalLoad() { localLoad?.resume(returning: []); localLoad = nil; deferredLocalLoad = false }
    func scanUnmanagedSkills() async throws -> [UnmanagedSkill] { [] }
    func toggleAgent(skillDirectory: String, agent: WorkspaceAgent, enable: Bool) async throws {}
    func bulkToggleAllAgents(skillDirectory: String, enable: Bool) async throws {}
    func uninstallSkill(skillDirectory: String) async throws {}
    func updateAllSkillsReport() async -> WorkspaceOperationResult { .init() }
    func installSkill(skill: DiscoverableSkill, targetAgents: Set<WorkspaceAgent>) async throws {}
    func importUnmanagedSkill(_ unmanaged: UnmanagedSkill) async throws {}
    func exportSkillsArchive(to destinationURL: URL) async throws {}
    func setDeferredDiscovery(_ value: Bool) { deferredDiscovery = value }
    func discoverSkills(repo: SkillRepo) async throws -> [DiscoverableSkill] {
        guard deferredDiscovery else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            pending[repo.id] = continuation
            observers.removeValue(forKey: repo.id)?.resume()
        }
    }
    func waitForDiscovery(_ id: String) async {
        guard pending[id] == nil else { return }
        await withCheckedContinuation { observers[id] = $0 }
    }
    func finishDiscovery(_ repo: SkillRepo, name: String) {
        pending.removeValue(forKey: repo.id)?.resume(returning: [.init(name: name, description: "", directory: name, repoOwner: repo.owner, repoName: repo.name)])
    }
}

private actor WorkspaceStorageStub: WorkspaceStorageServicing {
    private let cacheResult: WorkspaceOperationResult
    init(cacheResult: WorkspaceOperationResult = .init()) { self.cacheResult = cacheResult }
    func analyzeStorage() async -> WorkspaceStorageReport { .init() }
    func clearCachesReport(for agent: WorkspaceAgent?) async -> WorkspaceOperationResult { cacheResult }
    func cleanOldSessionsReport(olderThanDays: Int) async -> WorkspaceOperationResult { .init() }
}
