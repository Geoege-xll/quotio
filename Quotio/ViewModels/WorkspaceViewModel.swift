//
//  WorkspaceViewModel.swift
//  Quotio - Unified Workspace State Management (Sessions, Skills, Storage)
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
public final class WorkspaceViewModel {
    public static let shared = WorkspaceViewModel()

    private let sessionService: any WorkspaceSessionServicing
    private let skillService: any WorkspaceSkillServicing
    private let storageService: any WorkspaceStorageServicing

    // 每类异步读取独立计代：慢请求不能覆盖新选择，也不能结束新请求的加载状态。
    private var sessionRevision = 0
    private var messageRevision = 0
    private var repositoryRevision = 0
    private var repositoryDataRevision = 0
    private var skillRevision = 0
    private var storageRevision = 0
    private var hasStartedInitialLoad = false
    private var isSavingRepositories = false
    public private(set) var isDeletingSessions = false
    public private(set) var isMutatingSkills = false

    // MARK: - Top Navigation
    public var selectedTab: WorkspaceTab = .storage

    // MARK: - Sessions State
    public var sessions: [WorkspaceSession] = []
    public var selectedSession: WorkspaceSession? = nil
    public var selectedSessionMessages: [WorkspaceSessionMessage] = []
    public var isLoadingSessions = false
    public var isLoadingMessages = false
    public var sessionSearchText = ""
    public var selectedAgentFilter: WorkspaceAgent = .claude
    public var isGroupedView = true
    public var batchDeleteMode = false
    public var selectedSessionIDs: Set<String> = []
    public var expandedParentSessionIDs: Set<String> = []

    // MARK: - Skills State
    public var selectedSkillSubTab: WorkspaceSkillSubTab = .installed
    public var installedSkills: [WorkspaceSkill] = []
    public var discoverableSkills: [DiscoverableSkill] = []
    public var repos: [SkillRepo] = []
    public var selectedRepo: SkillRepo? = nil
    public var unmanagedSkills: [UnmanagedSkill] = []
    public var skillSearchText = ""
    public var isLoadingSkills = false
    public var isUpdatingAllSkills = false
    public var isDiscoveringSkills = false
    public var isExportingSkills = false
    public var selectedSkillForPreview: WorkspaceSkill? = nil
    public var previewContent: String? = nil
    public var showAddRepoSheet = false
    public var newRepoURL = ""

    // MARK: - Storage State
    public var storageReport: WorkspaceStorageReport? = nil
    public var isAnalyzingStorage = false
    public var isCleaningStorage = false
    public var toastMessage: String? = nil
    public var errorMessage: String? = nil

    /// 构造只保存依赖；磁盘建库和迁移必须通过显式启动操作执行。
    public init(
        sessionService: any WorkspaceSessionServicing = WorkspaceSessionService.shared,
        skillService: any WorkspaceSkillServicing = WorkspaceSkillService.shared,
        storageService: any WorkspaceStorageServicing = WorkspaceStorageService.shared
    ) {
        self.sessionService = sessionService
        self.skillService = skillService
        self.storageService = storageService
    }

    // MARK: - Lifecycle

    public func loadInitialDataIfNeeded() async {
        guard !hasStartedInitialLoad else { return }
        hasStartedInitialLoad = true
        // 子任务跟随页面任务取消；空数据也是有效结果，不能每次打开都重新下载仓库。
        async let storage: Void = analyzeStorage()
        async let sessions: Void = refreshSessions()
        async let skills: Void = refreshSkills()
        _ = await (storage, sessions, skills)
        if Task.isCancelled { hasStartedInitialLoad = false }
    }

    // MARK: - Sessions Actions

    public func refreshSessions() async {
        sessionRevision += 1
        let revision = sessionRevision
        let agent = selectedAgentFilter
        isLoadingSessions = true
        defer { if revision == sessionRevision { isLoadingSessions = false } }

        let loaded = await sessionService.scanAllSessions(agentFilter: agent)
        guard revision == sessionRevision, agent == selectedAgentFilter, !Task.isCancelled else { return }
        sessions = loaded

        if let current = selectedSession {
            if let refreshed = sessions.first(where: { $0.id == current.id && $0.agent == current.agent }) {
                selectedSession = refreshed
            } else {
                closeSelectedSession()
            }
        }

        if let selected = selectedSession {
            await loadMessages(for: selected)
        } else {
            selectedSessionMessages = []
        }
    }

    public func selectAgentFilter(_ agent: WorkspaceAgent) async {
        guard selectedAgentFilter != agent else { return }
        selectedAgentFilter = agent
        closeSelectedSession()
        selectedSessionIDs.removeAll()
        expandedParentSessionIDs.removeAll()
        batchDeleteMode = false
        await refreshSessions()
    }

    public func selectSession(_ session: WorkspaceSession) async {
        guard session.agent == selectedAgentFilter else { return }
        selectedSession = session
        selectedSessionMessages = []
        await loadMessages(for: session)
    }

    public func closeSelectedSession() {
        messageRevision += 1
        selectedSession = nil
        selectedSessionMessages = []
        isLoadingMessages = false
    }

    public func loadMessages(for session: WorkspaceSession) async {
        messageRevision += 1
        let revision = messageRevision
        isLoadingMessages = true
        defer { if revision == messageRevision { isLoadingMessages = false } }

        do {
            let messages = try await sessionService.loadSessionMessages(session: session)
            guard isCurrentMessageRequest(revision, session: session) else { return }
            selectedSessionMessages = messages
        } catch {
            guard isCurrentMessageRequest(revision, session: session) else { return }
            selectedSessionMessages = []
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrentMessageRequest(_ revision: Int, session: WorkspaceSession) -> Bool {
        revision == messageRevision && !Task.isCancelled && selectedSession?.id == session.id && selectedSession?.agent == session.agent
    }

    public func resumeSelectedSession() async {
        guard let session = selectedSession else { return }
        await resumeSession(session)
    }

    public func resumeSession(_ session: WorkspaceSession) async {
        do {
            try await sessionService.resumeInTerminal(session: session)
            showToast("已在终端中拉起继续会话")
        } catch {
            errorMessage = "恢复会话失败: \(error.localizedDescription)"
        }
    }

    public func deleteSession(_ session: WorkspaceSession) async {
        guard !isDeletingSessions else { return }
        isDeletingSessions = true
        defer { isDeletingSessions = false }
        let removedKeys = deletionKeys(for: session, in: sessions)
        do {
            let success = try await sessionService.deleteSession(session)
            if success {
                await reconcileDeletedSessions(removedKeys)
                showToast("已成功删除会话")
                await analyzeStorage()
            } else {
                errorMessage = "删除会话失败：未找到对应的会话记录或文件"
            }
        } catch {
            errorMessage = "删除失败: \(error.localizedDescription)"
        }
    }

    public func deleteSelectedBatchSessions() async {
        guard !selectedSessionIDs.isEmpty, !isDeletingSessions else { return }
        isDeletingSessions = true
        defer { isDeletingSessions = false }
        let snapshot = sessions
        let agent = selectedAgentFilter
        let selectedIDs = selectedSessionIDs
        let selected = snapshot.filter { $0.agent == agent && selectedIDs.contains($0.id) }
        let tree = WorkspaceSessionTree(sessions: snapshot)
        // 父会话的删除包含后代；同时勾选父子时只向服务提交最高层的候选。
        let toDelete = selected.filter { session in
            !tree.ancestors(of: session).contains { selectedIDs.contains($0.id) }
        }
        var removedKeys = Set<String>()
        var result = WorkspaceOperationResult()
        for session in toDelete {
            do {
                if try await sessionService.deleteSession(session) {
                    removedKeys.formUnion(deletionKeys(for: session, in: snapshot))
                    result.succeededCount += 1
                } else {
                    result.failures.append("\(session.title)：未找到可删除的会话")
                }
            } catch {
                result.failures.append("\(session.title)：\(error.localizedDescription)")
            }
        }
        await reconcileDeletedSessions(removedKeys)
        if selectedSessionIDs.isEmpty { batchDeleteMode = false }
        presentOperationResult(result, success: "已成功批量删除 \(result.succeededCount) 个会话")
        await analyzeStorage()
    }

    private func deletionKeys(for session: WorkspaceSession, in snapshot: [WorkspaceSession]) -> Set<String> {
        var keys: Set<String> = [WorkspaceSessionTree.key(session)]
        keys.formUnion(WorkspaceSessionTree(sessions: snapshot).descendants(of: session).map { WorkspaceSessionTree.key($0.session) })
        return keys
    }

    /// 只移除服务已经确认删除的会话。失败项目保留，方便重试；旧扫描结果同时失效。
    private func reconcileDeletedSessions(_ keys: Set<String>) async {
        guard !keys.isEmpty else { return }
        // 删除旧客户端的会话不应废弃用户刚切换到新客户端的扫描。
        let affectsCurrentAgent = keys.contains { $0.hasPrefix(selectedAgentFilter.rawValue + ":") }
        let needsFreshScan = affectsCurrentAgent && isLoadingSessions
        if affectsCurrentAgent {
            sessionRevision += 1
            isLoadingSessions = false
        }
        let removedIDs = Set(sessions.filter { $0.agent == selectedAgentFilter && keys.contains(WorkspaceSessionTree.key($0)) }.map(\.id))
        sessions.removeAll { keys.contains(WorkspaceSessionTree.key($0)) }
        selectedSessionIDs.subtract(removedIDs)
        expandedParentSessionIDs.subtract(removedIDs)
        if let selected = selectedSession, keys.contains(WorkspaceSessionTree.key(selected)) {
            closeSelectedSession()
            if let next = rootFilteredSessions.first { await selectSession(next) }
        }
        if needsFreshScan { await refreshSessions() }
    }

    public func copyResumeCommand(session: WorkspaceSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.resumeCommand, forType: .string)
        showToast("已复制恢复命令: \(session.resumeCommand)")
    }

    public func revealInFinder(session: WorkspaceSession) {
        if session.filePath.hasPrefix("sqlite:") {
            let parts = session.filePath.split(separator: ":")
            if parts.count >= 2 {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: String(parts[1]))])
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.filePath)])
        }
    }

    // Filtered Sessions
    public var filteredSessions: [WorkspaceSession] {
        let source = sessions.filter { $0.agent == selectedAgentFilter }
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return source }
        let matched = source.filter { session in
            session.title.localizedLowercase.contains(query) ||
                   session.projectName.localizedLowercase.contains(query) ||
                   (session.projectDirectory?.localizedLowercase.contains(query) ?? false) ||
                   (session.summary?.localizedLowercase.contains(query) ?? false) ||
                   session.id.localizedLowercase.contains(query)
        }
        let tree = WorkspaceSessionTree(sessions: source)
        var visibleIDs = Set(matched.map(\.id))
        // 命中子任务时保留其祖先路径，否则搜索结果会因父行消失而无法访问。
        for session in matched { visibleIDs.formUnion(tree.ancestors(of: session).map(\.id)) }
        return source.filter { visibleIDs.contains($0.id) }
    }

    /// 仅展示主根会话，子任务 (subagent) 会话在左侧以折叠树的形式挂载在主会话下
    public var rootFilteredSessions: [WorkspaceSession] {
        WorkspaceSessionTree(sessions: filteredSessions).roots
    }

    public func isSubagentExpanded(_ parentID: String) -> Bool {
        expandedParentSessionIDs.contains(parentID)
    }

    public func toggleSubagentExpansion(_ parentID: String) {
        if expandedParentSessionIDs.contains(parentID) {
            expandedParentSessionIDs.remove(parentID)
        } else {
            expandedParentSessionIDs.insert(parentID)
        }
    }

    public func subagents(for parentID: String) -> [WorkspaceSession] {
        filteredSessions.filter { $0.parentSessionID == parentID }
    }

    /// 原有折叠控件展开后展示全部层级，行样式复用既有子任务行。
    public func descendantRows(for parent: WorkspaceSession) -> [(session: WorkspaceSession, depth: Int)] {
        WorkspaceSessionTree(sessions: filteredSessions).descendants(of: parent)
    }

    // Grouped Sessions by Project (仅对主会话按项目归组)
    public var projectGroups: [(id: String, projectName: String, directory: String?, sessions: [WorkspaceSession])] {
        let dictionary = Dictionary(grouping: rootFilteredSessions) { session in
            session.projectDirectory ?? "unknown:\(session.projectName)"
        }
        return dictionary.map { (identity, items) in
            (id: identity, projectName: items.first?.projectName ?? "Unknown", directory: items.first?.projectDirectory, sessions: items)
        }.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
    }

    // MARK: - Skills Actions

    public func refreshSkills() async {
        skillRevision += 1
        let revision = skillRevision
        let reposRevision = repositoryDataRevision
        isLoadingSkills = true
        defer { if revision == skillRevision { isLoadingSkills = false } }
        do {
            try await skillService.prepareStorage()
            let loadedRepos = try await skillService.loadRepos()
            let installed = try await skillService.loadInstalledSkills()
            let unmanaged = try await skillService.scanUnmanagedSkills()
            guard revision == skillRevision, !Task.isCancelled else { return }
            // 仓库保存可能在下面两个磁盘读取的挂起期间完成；只提交仍然有效的仓库快照。
            // 技能内容仍可独立刷新，避免为了保护仓库而丢掉整次本地读取。
            if reposRevision == repositoryDataRevision { repos = loadedRepos }
            if !repos.contains(where: { $0.id == selectedRepo?.id }) { selectedRepo = repos.first }
            installedSkills = installed
            unmanagedSkills = unmanaged
            if let repo = selectedRepo { await fetchDiscoverableSkills(repo: repo) }
        } catch {
            guard revision == skillRevision, !Task.isCancelled else { return }
            errorMessage = "读取技能失败: \(error.localizedDescription)"
        }
    }

    public func toggleSkillAgent(skill: WorkspaceSkill, agent: WorkspaceAgent, enable: Bool) async {
        guard !isMutatingSkills else { return }
        isMutatingSkills = true
        defer { isMutatingSkills = false }
        do {
            try await skillService.toggleAgent(skillDirectory: skill.directory, agent: agent, enable: enable)
            try await reloadLocalSkills()
            showToast("\(skill.name) 已\(enable ? "启用" : "停用") \(agent.displayName)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func bulkToggleSkillAll(skill: WorkspaceSkill, enable: Bool) async {
        guard !isMutatingSkills else { return }
        isMutatingSkills = true
        defer { isMutatingSkills = false }
        do {
            try await skillService.bulkToggleAllAgents(skillDirectory: skill.directory, enable: enable)
            try await reloadLocalSkills()
            showToast("\(skill.name) 已在全部智能体中\(enable ? "启用" : "停用")")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func uninstallSkill(skill: WorkspaceSkill) async {
        guard !isMutatingSkills else { return }
        isMutatingSkills = true
        defer { isMutatingSkills = false }
        do {
            try await skillService.uninstallSkill(skillDirectory: skill.directory)
            try await reloadLocalSkills()
            showToast("已卸载技能: \(skill.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updateAllSkills() async {
        guard !isMutatingSkills else { return }
        isMutatingSkills = true
        isUpdatingAllSkills = true
        defer { isUpdatingAllSkills = false; isMutatingSkills = false }
        let result = await skillService.updateAllSkillsReport()
        do {
            try await reloadLocalSkills()
            presentOperationResult(result, success: "一键更新完成，共更新 \(result.succeededCount) 个技能")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func fetchDiscoverableSkills(repo: SkillRepo) async {
        selectedRepo = repo
        repositoryRevision += 1
        let revision = repositoryRevision
        isDiscoveringSkills = true
        discoverableSkills = []
        defer { if revision == repositoryRevision { isDiscoveringSkills = false } }
        do {
            let skills = try await skillService.discoverSkills(repo: repo)
            guard revision == repositoryRevision, selectedRepo?.id == repo.id, !Task.isCancelled else { return }
            discoverableSkills = skills
        } catch {
            guard revision == repositoryRevision, selectedRepo?.id == repo.id, !Task.isCancelled else { return }
            discoverableSkills = []
            errorMessage = "获取技能列表失败: \(error.localizedDescription)"
        }
    }

    public func installSkill(_ skill: DiscoverableSkill, targetAgents: Set<WorkspaceAgent>) async {
        guard !isMutatingSkills else { return }
        isMutatingSkills = true
        defer { isMutatingSkills = false }
        do {
            try await skillService.installSkill(skill: skill, targetAgents: targetAgents)
            try await reloadLocalSkills()
            showToast("已安装技能: \(skill.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func importUnmanagedSkill(_ unmanaged: UnmanagedSkill) async {
        guard !isMutatingSkills else { return }
        isMutatingSkills = true
        defer { isMutatingSkills = false }
        do {
            try await skillService.importUnmanagedSkill(unmanaged)
            try await reloadLocalSkills()
            showToast("已纳管本地技能: \(unmanaged.name)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func importAllUnmanagedSkills() async {
        guard !unmanagedSkills.isEmpty, !isMutatingSkills else { return }
        isMutatingSkills = true
        defer { isMutatingSkills = false }
        let snapshot = unmanagedSkills
        var result = WorkspaceOperationResult()
        for unmanaged in snapshot {
            do {
                try await skillService.importUnmanagedSkill(unmanaged)
                result.succeededCount += 1
            } catch {
                result.failures.append("\(unmanaged.name)（\(unmanaged.agent.displayName)）：\(error.localizedDescription)")
            }
        }
        do { try await reloadLocalSkills() }
        catch { result.failures.append("刷新技能列表：\(error.localizedDescription)") }
        presentOperationResult(result, success: "已批量纳管 \(result.succeededCount) 个本地技能至 ~/.quotio/skills/")
    }

    private func reloadLocalSkills() async throws {
        skillRevision += 1
        let revision = skillRevision
        let installed = try await skillService.loadInstalledSkills()
        let unmanaged = try await skillService.scanUnmanagedSkills()
        guard revision == skillRevision else { return }
        installedSkills = installed
        unmanagedSkills = unmanaged
        isLoadingSkills = false
    }

    public func exportSkillsBackup() async {
        guard !isMutatingSkills, !isExportingSkills else { return }
        isMutatingSkills = true
        isExportingSkills = true
        defer { isExportingSkills = false; isMutatingSkills = false }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        panel.nameFieldStringValue = "quotio-skills-backup-\(df.string(from: Date())).zip"
        panel.title = "导出技能备份包"
        panel.message = "选择保存技能备份 ZIP 归档文件的位置"

        let response = panel.runModal()
        guard response == .OK, let targetURL = panel.url else { return }

        do {
            try await skillService.exportSkillsArchive(to: targetURL)
            showToast("已成功导出技能归档至: \(targetURL.lastPathComponent)")
        } catch {
            errorMessage = "导出备份失败: \(error.localizedDescription)"
        }
    }

    public func addRepo(url: String) async {
        guard !isSavingRepositories else { return }
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.contains("://") {
            guard let parsed = URL(string: cleaned), parsed.scheme == "https", parsed.host?.lowercased() == "github.com",
                  parsed.query == nil, parsed.fragment == nil else {
                errorMessage = "请输入有效的 GitHub HTTPS 仓库地址"
                return
            }
            cleaned = parsed.path
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.hasSuffix(".git") { cleaned.removeLast(4) }
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({
            $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
        }) else {
            errorMessage = "请输入有效的 GitHub 仓库 (例如: owner/repo)"
            return
        }
        let newRepo = SkillRepo(owner: String(parts[0]), name: String(parts[1]), branch: "HEAD", isEnabled: true)
        guard !repos.contains(where: { $0.id.lowercased() == newRepo.id.lowercased() }) else {
            errorMessage = "该仓库源已经存在"
            return
        }
        isSavingRepositories = true
        do {
            // 以最新持久化列表为基准，避免首次加载尚未结束时用空界面列表覆盖旧仓库。
            let current = try await skillService.loadRepos()
            guard !current.contains(where: { $0.id.lowercased() == newRepo.id.lowercased() }) else {
                isSavingRepositories = false
                errorMessage = "该仓库源已经存在"
                return
            }
            let updated = current + [newRepo]
            try await skillService.saveRepos(updated)
            repositoryDataRevision += 1
            repos = updated
            showAddRepoSheet = false
            newRepoURL = ""
            isSavingRepositories = false
            showToast("已添加仓库源: \(newRepo.id)")
            await fetchDiscoverableSkills(repo: newRepo)
        } catch {
            isSavingRepositories = false
            errorMessage = "保存仓库失败: \(error.localizedDescription)"
        }
    }

    public func removeRepo(_ repo: SkillRepo) async {
        guard !isSavingRepositories else { return }
        isSavingRepositories = true
        do {
            let current = try await skillService.loadRepos()
            let updated = current.filter { $0.id != repo.id }
            try await skillService.saveRepos(updated)
            repositoryDataRevision += 1
            repos = updated
        } catch {
            isSavingRepositories = false
            errorMessage = "移除仓库失败: \(error.localizedDescription)"
            return
        }
        isSavingRepositories = false
        repositoryRevision += 1
        isDiscoveringSkills = false
        if selectedRepo?.id == repo.id {
            selectedRepo = repos.first
        }
        if let next = selectedRepo {
            await fetchDiscoverableSkills(repo: next)
        } else {
            discoverableSkills = []
        }
        showToast("已移除仓库源: \(repo.id)")
    }

    public var filteredInstalledSkills: [WorkspaceSkill] {
        if skillSearchText.isEmpty { return installedSkills }
        let query = skillSearchText.localizedLowercase
        return installedSkills.filter {
            $0.name.localizedLowercase.contains(query) ||
            $0.description.localizedLowercase.contains(query) ||
            $0.directory.localizedLowercase.contains(query)
        }
    }

    public var filteredDiscoverableSkills: [DiscoverableSkill] {
        if skillSearchText.isEmpty { return discoverableSkills }
        let query = skillSearchText.localizedLowercase
        return discoverableSkills.filter {
            $0.name.localizedLowercase.contains(query) ||
            $0.description.localizedLowercase.contains(query) ||
            $0.directory.localizedLowercase.contains(query)
        }
    }

    public func selectSkillSubTab(_ tab: WorkspaceSkillSubTab) async {
        selectedSkillSubTab = tab
        if tab == .discover && discoverableSkills.isEmpty && !isDiscoveringSkills, let repo = selectedRepo {
            await fetchDiscoverableSkills(repo: repo)
        }
    }

    // MARK: - Storage Actions

    public func analyzeStorage() async {
        storageRevision += 1
        let revision = storageRevision
        isAnalyzingStorage = true
        defer { if revision == storageRevision { isAnalyzingStorage = false } }
        let report = await storageService.analyzeStorage()
        guard revision == storageRevision, !Task.isCancelled else { return }
        storageReport = report
    }

    public func clearAllCaches() async {
        await clearCaches(for: nil)
    }

    public func clearAgentCaches(_ agent: WorkspaceAgent) async {
        await clearCaches(for: agent)
    }

    private func clearCaches(for agent: WorkspaceAgent?) async {
        guard !isCleaningStorage else { return }
        isCleaningStorage = true
        defer { isCleaningStorage = false }
        let result = await storageService.clearCachesReport(for: agent)
        await analyzeStorage()
        let formatted = ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)
        presentOperationResult(result, success: "已清理\(agent.map { " \($0.displayName) " } ?? "")缓存，释放 \(formatted)")
    }

    public func cleanOldSessions(days: Int = 30) async {
        guard !isCleaningStorage, !isDeletingSessions else { return }
        isCleaningStorage = true
        isDeletingSessions = true
        defer { isCleaningStorage = false; isDeletingSessions = false }
        let result = await storageService.cleanOldSessionsReport(olderThanDays: days)
        await refreshSessions()
        await analyzeStorage()
        let formatted = ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)
        presentOperationResult(result, success: "已清理 \(result.succeededCount) 个 \(days) 天前的旧会话，释放 \(formatted)")
    }

    /// 部分完成不展示“全部成功”；保留成功数量和失败原因，供用户决定是否重试。
    private func presentOperationResult(_ result: WorkspaceOperationResult, success: String) {
        if result.failures.isEmpty {
            showToast(success)
        } else {
            errorMessage = "已完成 \(result.succeededCount) 项，\(result.failures.count) 项失败：\n" + result.failures.joined(separator: "\n")
        }
    }

    // MARK: - Toast helper

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toastMessage == msg {
                self?.toastMessage = nil
            }
        }
    }
}
