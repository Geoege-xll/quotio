import XCTest
import Observation
@testable import QuotioPlus

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
        XCTAssertEqual(vm.sessionDeletionProgress?.phase, .finished)
        XCTAssertEqual(vm.sessionDeletionProgress?.result.failures.count, 1)
        XCTAssertNil(vm.errorMessage, "删除失败在进度面板内展示，避免 Sheet 和 Alert 竞争")
        XCTAssertNil(vm.toastMessage)
    }

    @MainActor
    func testDeletionPublishesProgressAndRejectsRepeatedActionsForEveryAgent() async {
        for agent in WorkspaceAgent.allCases {
            let service = WorkspaceSessionStub()
            await service.setDeferredDeletes()
            let vm = makeViewModel(sessions: service)
            vm.selectedAgentFilter = agent
            let first = session("a", agent: agent)
            let second = session("b", agent: agent)
            vm.sessions = [first, second]
            let deleting = Task { await vm.deleteSession(first) }
            await service.waitForDelete()
            let operationID = vm.sessionDeletionProgress?.id
            XCTAssertTrue(vm.isDeletingSessions)
            XCTAssertEqual(vm.sessionDeletionProgress?.phase, .deleting)
            XCTAssertEqual(vm.sessionDeletionProgress?.totalCount, 1)
            XCTAssertEqual(vm.sessionDeletionProgress?.processedCount, 0)
            XCTAssertEqual(vm.sessionDeletionProgress?.currentSessionTitle, "a")
            XCTAssertEqual(vm.sessionDeletionProgress?.currentAgentName, agent.displayName)
            vm.dismissSessionDeletionProgress()
            await vm.deleteSession(second)
            let calls = await service.deletionCalls
            XCTAssertEqual(calls, ["a"], "提示框关闭尝试和重复点击不能重复提交删除")
            XCTAssertEqual(vm.sessionDeletionProgress?.id, operationID)
            await service.finishDelete()
            await deleting.value
            XCTAssertFalse(vm.isDeletingSessions)
            XCTAssertNil(vm.sessionDeletionProgress, "成功后自动收起，不等待容量扫描")
            XCTAssertEqual(vm.sessions.map(\.id), ["b"])
        }
    }

    @MainActor
    func testBatchProgressCountsUniqueRootsAndPreservesPartialFailures() async {
        let service = WorkspaceSessionStub()
        await service.setDeferredDeletes()
        await service.setFailedDeletes(["failed"])
        let vm = makeViewModel(sessions: service)
        vm.sessions = [session("good"), session("child", parent: "good"), session("failed"), session("missing")]
        vm.selectedSessionIDs = ["good", "child", "failed", "missing"]
        vm.batchDeleteMode = true
        let deleting = Task { await vm.deleteSelectedBatchSessions() }
        await service.waitForDelete()
        let operationID = vm.sessionDeletionProgress?.id
        XCTAssertEqual(vm.sessionDeletionProgress?.totalCount, 3, "父子同时勾选只算一次实际删除")
        XCTAssertEqual(vm.sessionDeletionProgress?.processedCount, 0)
        XCTAssertEqual(vm.sessionDeletionProgress?.includesDescendants, true)
        await service.finishDelete()
        // 中间一项抛出错误后继续处理下一项；失败也算已处理，但不能算删除成功。
        await service.waitForDelete()
        XCTAssertEqual(vm.sessionDeletionProgress?.id, operationID)
        XCTAssertEqual(vm.sessionDeletionProgress?.currentSessionTitle, "missing")
        XCTAssertEqual(vm.sessionDeletionProgress?.processedCount, 2)
        XCTAssertEqual(vm.sessionDeletionProgress?.result.succeededCount, 1)
        XCTAssertEqual(vm.sessionDeletionProgress?.result.failures.count, 1)
        await service.finishDelete(success: false)
        await deleting.value
        XCTAssertFalse(vm.isDeletingSessions)
        XCTAssertEqual(vm.sessionDeletionProgress?.phase, .finished)
        XCTAssertEqual(vm.sessionDeletionProgress?.processedCount, 3)
        XCTAssertEqual(vm.sessionDeletionProgress?.result.succeededCount, 1)
        XCTAssertEqual(vm.sessionDeletionProgress?.result.failures.count, 2)
        XCTAssertNotNil(vm.sessionDeletionProgress?.finishedAt)
        XCTAssertEqual(vm.sessions.map(\.id), ["failed", "missing"])
        XCTAssertEqual(vm.selectedSessionIDs, ["failed", "missing"])
        XCTAssertNil(vm.toastMessage)
        let calls = await service.deletionCalls
        XCTAssertEqual(calls, ["good", "failed", "missing"])
        vm.dismissSessionDeletionProgress()
        XCTAssertNil(vm.sessionDeletionProgress)
    }

    @MainActor
    func testDeletionKeepsRefreshingPhaseUntilNextSessionDetailIsReady() async {
        let service = WorkspaceSessionStub()
        await service.setDeferredMessages(true)
        let vm = makeViewModel(sessions: service)
        let first = session("a")
        vm.sessions = [first, session("b")]
        vm.selectedSession = first
        let deleting = Task { await vm.deleteSession(first) }
        await service.waitForMessage("b")
        XCTAssertTrue(vm.isDeletingSessions)
        XCTAssertEqual(vm.sessionDeletionProgress?.phase, .refreshing)
        XCTAssertEqual(vm.sessionDeletionProgress?.processedCount, 1)
        XCTAssertEqual(vm.sessions.map(\.id), ["b"])
        await service.finishMessage("b", text: "下一条会话")
        await deleting.value
        XCTAssertNil(vm.sessionDeletionProgress)
        XCTAssertFalse(vm.isDeletingSessions)
        XCTAssertEqual(vm.selectedSessionMessages.first?.content, "下一条会话")
    }

    @MainActor
    func testSuccessfulDeletionPreservesFollowingDetailErrorForAfterSheetDismissal() async {
        let service = WorkspaceSessionStub()
        await service.setDeferredMessages(true)
        let vm = makeViewModel(sessions: service)
        let first = session("a")
        vm.sessions = [first, session("b")]
        vm.selectedSession = first
        let deleting = Task { await vm.deleteSession(first) }
        await service.waitForMessage("b")
        XCTAssertEqual(vm.sessionDeletionProgress?.phase, .refreshing)
        await service.failMessage("b")
        await deleting.value
        XCTAssertNil(vm.sessionDeletionProgress)
        XCTAssertFalse(vm.isDeletingSessions)
        XCTAssertEqual(vm.sessions.map(\.id), ["b"])
        XCTAssertTrue(vm.errorMessage?.contains("详情读取失败") == true,
                      "删除结束不能吞掉后续详情读取错误，界面在 Sheet 关闭后展示它")
        XCTAssertTrue(vm.toastMessage?.contains("成功删除") == true)
    }

    @MainActor
    func testEmptyOrStaleBatchSelectionDoesNotShowDeletionProgress() async {
        let service = WorkspaceSessionStub()
        let vm = makeViewModel(sessions: service)
        await vm.deleteSelectedBatchSessions()
        vm.selectedSessionIDs = ["no-longer-present"]
        await vm.deleteSelectedBatchSessions()
        XCTAssertNil(vm.sessionDeletionProgress)
        XCTAssertFalse(vm.isDeletingSessions)
        XCTAssertNil(vm.toastMessage)
        let calls = await service.deletionCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDeletionElapsedTimeFreezesAtCompletion() {
        let start = Date(timeIntervalSince1970: 100)
        var progress = WorkspaceSessionDeletionProgress(startedAt: start)
        XCTAssertEqual(progress.elapsedText(at: start.addingTimeInterval(65)), "已用时 1 分 5 秒")
        progress.finishedAt = start.addingTimeInterval(70)
        progress.phase = .finished
        XCTAssertEqual(progress.elapsedText(at: start.addingTimeInterval(200)), "已用时 1 分 10 秒")
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
    func testDeletionDoesNotWaitForStorageAndCoalescesRefreshes() async {
        let storage = WorkspaceStorageStub()
        await storage.setDeferredAnalysis()
        let vm = makeViewModel(storage: storage)
        vm.sessions = [session("a"), session("b"), session("c")]
        let refreshing = Task { await vm.analyzeStorage() }
        await storage.waitForAnalysis(1)

        // 容量读取刻意不返回；实际删除完成后必须立即解锁，允许继续删除下一项。
        for id in ["a", "b", "c"] {
            await vm.deleteSession(session(id))
            XCTAssertFalse(vm.isDeletingSessions)
        }
        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertTrue(vm.isAnalyzingStorage)
        let firstCount = await storage.analysisCount
        XCTAssertEqual(firstCount, 1, "连续删除不应并发启动多个容量扫描")

        await storage.finishAnalysis(.init(oldSessionsCount: 3))
        await storage.waitForAnalysis(2)
        XCTAssertNil(vm.storageReport, "删除之前开始读取的旧报告不能覆盖当前状态")
        await storage.finishAnalysis(.init(oldSessionsCount: 0))
        await refreshing.value
        let finalCount = await storage.analysisCount
        XCTAssertEqual(finalCount, 2, "多个删除请求只需补一次最新扫描")
        XCTAssertEqual(vm.storageReport?.oldSessionsCount, 0)
        XCTAssertFalse(vm.isAnalyzingStorage)
    }

    @MainActor
    func testCachedListStillObservesInputChanges() async {
        let vm = makeViewModel()
        vm.sessions = [session("a"), session("b")]
        _ = vm.rootFilteredSessions
        let changed = expectation(description: "命中缓存后的视图仍订阅 sessions")
        withObservationTracking {
            _ = vm.rootFilteredSessions
            _ = vm.projectGroups
        } onChange: {
            changed.fulfill()
        }
        vm.sessions.removeFirst()
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(vm.rootFilteredSessions.map(\.id), ["b"])
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
    func testSearchRetainsAncestorsWithoutPromotingOrphanSubagents() {
        let vm = makeViewModel()
        vm.sessions = [session("root"), session("child", parent: "root"), session("needle", parent: "child"), session("orphan", parent: "missing")]
        XCTAssertEqual(vm.rootFilteredSessions.map(\.id), ["root"])
        vm.sessionSearchText = "needle"
        XCTAssertEqual(vm.rootFilteredSessions.map(\.id), ["root"])
        XCTAssertEqual(vm.descendantRows(for: session("root")).map { $0.session.id }, ["child", "needle"])
        vm.sessionSearchText = "orphan"
        XCTAssertTrue(vm.rootFilteredSessions.isEmpty, "搜索不能把缺失父会话的子任务提升为主会话")
        XCTAssertEqual(vm.sessions.count, 4, "浏览筛选不能删除原始会话记录")
    }

    @MainActor
    func testMainSessionListExcludesUnlinkedHelpersAndBrokenRelationshipsForEveryAgent() {
        // 所有客户端共用主会话规则；guardian、缺失父节点和环只能保留在完整数据中。
        // 主会话目录即使叫 agent_workflow 也应正常显示，不能按项目名做黑名单。
        for agent in WorkspaceAgent.allCases {
            let vm = makeViewModel()
            vm.selectedAgentFilter = agent
            let main = WorkspaceSession(id: "main", agent: agent, title: "工作流开发",
                projectDirectory: "/projects/agent_workflow", projectName: "agent_workflow",
                lastActiveAt: Date(), filePath: "/fixture/main.jsonl", fileSizeBytes: 1,
                messageCount: 1, resumeCommand: "")
            let guardian = WorkspaceSession(id: "guardian", agent: agent, title: "辅助审查",
                projectDirectory: "/projects/agent_workflow", projectName: "agent_workflow",
                lastActiveAt: Date(), filePath: "/fixture/guardian.jsonl", fileSizeBytes: 1,
                messageCount: 1, resumeCommand: "", isSubagent: true)
            let conflicting = WorkspaceSession(id: "conflicting", agent: agent, title: "关系不一致",
                projectName: "test", lastActiveAt: Date(), filePath: "/fixture/conflicting.jsonl",
                fileSizeBytes: 1, messageCount: 1, resumeCommand: "", parentSessionID: "missing", isSubagent: false)
            vm.sessions = [main, guardian, session("child", parent: "main", agent: agent),
                session("orphan", parent: "missing", agent: agent), session("self", parent: "self", agent: agent),
                session("a", parent: "b", agent: agent), session("b", parent: "a", agent: agent), conflicting]

            XCTAssertEqual(vm.rootFilteredSessions.map(\.id), ["main"])
            XCTAssertEqual(vm.projectGroups.map(\.projectName), ["agent_workflow"])
            XCTAssertEqual(vm.projectGroups.flatMap(\.sessions).map(\.id), ["main"])
            XCTAssertEqual(vm.descendantRows(for: main).map { $0.session.id }, ["child"])
            vm.sessionSearchText = "辅助审查"
            XCTAssertTrue(vm.rootFilteredSessions.isEmpty)
            XCTAssertTrue(vm.projectGroups.isEmpty)
            XCTAssertEqual(vm.sessions.count, 8)
        }
    }

    func testTreeTerminatesCyclesAndKeepsDifferentAgentsSeparate() {
        let tree = WorkspaceSessionTree(sessions: [session("a", parent: "b"), session("b", parent: "a"), session("a", agent: .codex)])
        XCTAssertEqual(tree.roots.count, 2)
        XCTAssertEqual(tree.descendants(of: session("a")).map { $0.session.id }, ["b"])
    }

    @MainActor
    private func makeViewModel(
        sessions: WorkspaceSessionStub? = nil,
        skills: WorkspaceSkillStub? = nil,
        storage: WorkspaceStorageStub? = nil
    ) -> WorkspaceViewModel {
        // 默认替身在明确的 MainActor 函数体内创建，避免 Swift 6.4 对默认参数中的 actor
        // 构造表达式推导出无效的 nonisolated 初始化标记；每次调用仍使用独立的测试依赖。
        WorkspaceViewModel(sessionService: sessions ?? WorkspaceSessionStub(),
                           skillService: skills ?? WorkspaceSkillStub(),
                           storageService: storage ?? WorkspaceStorageStub())
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
    private var deferredDeletes = false
    private(set) var deletionCalls: [String] = []
    func setDeferredDeletes() { deferredDeletes = true }
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
    func finishDelete(success: Bool = true) { deletion?.resume(returning: success); deletion = nil }
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
    func failMessage(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: NSError(domain: "Fixture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "模拟详情读取失败"]))
    }
    func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        deletionCalls.append(session.id)
        if failedDeletes.contains(session.id) { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟删除失败"]) }
        if deferredScanAndDelete || deferredDeletes {
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
    private var deferredAnalysis = false
    private var pendingAnalysis: CheckedContinuation<WorkspaceStorageReport, Never>?
    private var analysisObservers: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var analysisCount = 0
    func setDeferredAnalysis() { deferredAnalysis = true }
    func analyzeStorage() async -> WorkspaceStorageReport {
        analysisCount += 1
        guard deferredAnalysis else { return .init() }
        return await withCheckedContinuation {
            pendingAnalysis = $0
            analysisObservers.removeValue(forKey: analysisCount)?.resume()
        }
    }
    func waitForAnalysis(_ count: Int) async {
        guard analysisCount < count else { return }
        await withCheckedContinuation { analysisObservers[count] = $0 }
    }
    func finishAnalysis(_ report: WorkspaceStorageReport) {
        pendingAnalysis?.resume(returning: report)
        pendingAnalysis = nil
    }
    func clearCachesReport(for agent: WorkspaceAgent?) async -> WorkspaceOperationResult { cacheResult }
    func cleanOldSessionsReport(olderThanDays: Int) async -> WorkspaceOperationResult { .init() }
}
