//
//  WorkspaceSessionService.swift
//  Quotio
//

import Foundation

/// 会话服务的原 actor 门面，仅保留原提供商装配、并发扫描汇总、消息／删除分发及终端恢复。
/// shared、私有依赖、TaskGroup、排序和调用顺序完整保留；Provider 分文件不建立第二个服务实例。
/// 删除仍由原统一引擎保护，门面在 await 期间可重入，不能作为全局删除锁使用。
public actor WorkspaceSessionService {
    public static let shared = WorkspaceSessionService()

    private let homeDir: String
    private let fileManager = FileManager.default
    private let providers: [WorkspaceAgent: any AgentSessionProviderProtocol]

    public init(homeDir: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDir = homeDir
        self.providers = [
            .claude: ClaudeSessionProvider(homeDir: homeDir),
            .codex: CodexSessionProvider(homeDir: homeDir),
            .opencode: OpenCodeSessionProvider(homeDir: homeDir),
            .pi: PiSessionProvider(homeDir: homeDir),
            .agy: AGYSessionProvider(homeDir: homeDir)
        ]
    }

    // MARK: - Scan Sessions

    public func scanAllSessions(agentFilter: WorkspaceAgent? = nil) async -> [WorkspaceSession] {
        var results: [WorkspaceSession] = []

        if let filter = agentFilter {
            if let provider = providers[filter] {
                results = await provider.scanSessions()
            }
        } else {
            // Concurrent scan across all providers
            await withTaskGroup(of: [WorkspaceSession].self) { group in
                for provider in providers.values {
                    group.addTask {
                        await provider.scanSessions()
                    }
                }
                for await agentSessions in group {
                    results.append(contentsOf: agentSessions)
                }
            }
        }

        // Sort descending by last active date
        return results.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    // MARK: - Load Messages

    public func loadSessionMessages(session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        guard let provider = providers[session.agent] else {
            throw NSError(
                domain: "WorkspaceSessionService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No provider found for agent \(session.agent.displayName)"]
            )
        }
        return try await provider.loadMessages(for: session)
    }

    // MARK: - Safe Delete Session

    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        guard let provider = providers[session.agent] else { return false }
        // 安全检查位于每个 Provider 共用的删除引擎中，直接调用 Provider 也不能绕过保护。
        // actor 在等待并发 Provider 时允许重入，不能把 Facade 当作删除操作的全局串行锁。
        // 当前页面写入由共享 ViewModel 的删除状态互斥；SQLite 写锁和回滚仍由事务引擎管理。
        return try await provider.deleteSession(session)
    }

    public func deleteSession(_ session: WorkspaceSession, constrainedBy constraint: WorkspaceSessionCleanupConstraint) async throws -> Bool {
        guard let provider = providers[session.agent] else { return false }
        let current = await provider.scanSessions()
        try constraint.validateObserved(current, root: session)
        // 此后引擎内部没有 await；SQLite 下仍在 BEGIN IMMEDIATE 之后重查后代、来源与活动字段。
        return try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: session.agent, homeDirectory: homeDir,
                                                          relatedSessions: current, cleanupConstraint: constraint)
    }

    // MARK: - Resume in Terminal

    public func resumeInTerminal(session: WorkspaceSession) async throws {
        // 不信任持久化的 resumeCommand；按客户端协议重新构造参数，缺失 cwd 时使用真实 home。
        let command = WorkspaceSessionCommandBuilder.terminalCommand(session: session, homeDirectory: homeDir)
        let directory = session.projectDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? homeDir
        do {
            try await TerminalLauncher.shared.launch(command: command, in: directory)
        } catch {
            throw WorkspaceSessionOperationError.terminal(error.localizedDescription)
        }
    }

}

