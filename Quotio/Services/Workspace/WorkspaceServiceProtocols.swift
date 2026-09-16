import Foundation

/// 页面依赖操作契约，不直接绑定全局服务；测试可注入临时目录实现或可控异步替身，
/// 从而验证请求乱序和删除失败，而不会初始化、迁移真实用户目录。
/// 服务由各自的 actor 实现；显式声明协议不绑定 MainActor，避免默认隔离传递到服务和测试替身。
public nonisolated protocol WorkspaceSessionServicing: Sendable {
    func scanAllSessions(agentFilter: WorkspaceAgent?) async -> [WorkspaceSession]
    func loadSessionMessages(session: WorkspaceSession) async throws -> [WorkspaceSessionMessage]
    func deleteSession(_ session: WorkspaceSession) async throws -> Bool
    func deleteSession(_ session: WorkspaceSession, constrainedBy constraint: WorkspaceSessionCleanupConstraint) async throws -> Bool
    func resumeInTerminal(session: WorkspaceSession) async throws
}

public extension WorkspaceSessionServicing {
    /// 清理不能悄悄退回普通级联删除；未实现事务约束的替身或客户端必须明确拒绝。
    func deleteSession(_ session: WorkspaceSession, constrainedBy constraint: WorkspaceSessionCleanupConstraint) async throws -> Bool {
        throw NSError(domain: "WorkspaceCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "会话服务不支持受约束清理，已保留会话。"])
    }
}

/// 技能操作通过异步契约跨 actor 调用，协议本身不要求在主线程执行。
public nonisolated protocol WorkspaceSkillServicing: Sendable {
    func prepareStorage() async throws
    func loadRepos() async throws -> [SkillRepo]
    func saveRepos(_ repos: [SkillRepo]) async throws
    func loadInstalledSkills() async throws -> [WorkspaceSkill]
    func scanUnmanagedSkills() async throws -> [UnmanagedSkill]
    func toggleAgent(skillDirectory: String, agent: WorkspaceAgent, enable: Bool) async throws
    func bulkToggleAllAgents(skillDirectory: String, enable: Bool) async throws
    func uninstallSkill(skillDirectory: String) async throws
    func updateAllSkillsReport() async -> WorkspaceOperationResult
    func discoverSkills(repo: SkillRepo) async throws -> [DiscoverableSkill]
    func installSkill(skill: DiscoverableSkill, targetAgents: Set<WorkspaceAgent>) async throws
    func importUnmanagedSkill(_ unmanaged: UnmanagedSkill) async throws
    func exportSkillsArchive(to destinationURL: URL) async throws
}

/// 存储服务保留自身 actor 的串行保护，不继承 UI 模块默认的 MainActor 隔离。
public nonisolated protocol WorkspaceStorageServicing: Sendable {
    func analyzeStorage() async -> WorkspaceStorageReport
    func clearCachesReport(for agent: WorkspaceAgent?) async -> WorkspaceOperationResult
    func cleanOldSessionsReport(olderThanDays: Int) async -> WorkspaceOperationResult
}

extension WorkspaceSessionService: WorkspaceSessionServicing {}
extension WorkspaceSkillService: WorkspaceSkillServicing {}
extension WorkspaceStorageService: WorkspaceStorageServicing {}
