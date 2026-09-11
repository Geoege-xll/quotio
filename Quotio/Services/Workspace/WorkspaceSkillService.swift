//
//  WorkspaceSkillService.swift
//  Quotio - 私有统一库 (~/.quotio/skills)、完整技能分发与元数据管理
//

import Foundation
import CryptoKit
import Yams

public actor WorkspaceSkillService {
    public static let shared = WorkspaceSkillService()

    private let fileManager = FileManager.default
    private let homeDir: String
    private let ssotSkillsDir: String
    private let dbPath: String
    private let backupsDir: String
    private let session: URLSession
    private var prepared = false
    /// actor 在网络 await 时允许重入，因此显式锁住同一个技能的整个操作，
    /// 防止更新等待下载时被卸载，随后又把已卸载的目录写回来。
    private var busySkills: Set<String> = []
    /// 短时复用同一仓库快照，发现→安装及一键更新不为每个文件重复消耗 GitHub API 配额。
    private var repositoryTrees: [String: (Date, [TreeEntry])] = [:]

    /// 构造只保存依赖；不创建目录、不迁移用户文件，测试和页面状态初始化均无磁盘副作用。
    public init(homeDir: String = FileManager.default.homeDirectoryForCurrentUser.path, session: URLSession = .shared) {
        let homeDir = URL(fileURLWithPath: homeDir).resolvingSymlinksInPath().path
        self.homeDir = homeDir
        self.ssotSkillsDir = (homeDir as NSString).appendingPathComponent(".quotio/skills")
        self.dbPath = (homeDir as NSString).appendingPathComponent(".quotio/quotio.db")
        self.backupsDir = (homeDir as NSString).appendingPathComponent(".quotio/skill_backups")
        self.session = session
    }

    /// 唯一的显式启动入口。只初始化 Quotio 自有存储，不自动搬动 ~/.agents/skills。
    /// 用迁移标记区分“首次使用”和“用户删空仓库”，避免刷新重新加入已经移除的仓库。
    public func prepareStorage() async throws {
        guard !prepared else { return }
        for path in [ssotSkillsDir, backupsDir] {
            try validatePrivateRoot(path)
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try validatePrivateRoot(dbPath)
        let db = try WorkspaceSkillDatabase(path: dbPath, create: true)
        try db.transaction {
            let hadRepos = try !db.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='skill_repos'").isEmpty
            try db.execute("CREATE TABLE IF NOT EXISTS skill_repos (owner TEXT NOT NULL, name TEXT NOT NULL, branch TEXT NOT NULL DEFAULT 'main', enabled INTEGER NOT NULL DEFAULT 1, source TEXT DEFAULT 'custom', created_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(owner,name))")
            try db.execute("CREATE TABLE IF NOT EXISTS skills_metadata (directory TEXT PRIMARY KEY, name TEXT, description TEXT, repo_owner TEXT, repo_name TEXT, repo_branch TEXT DEFAULT 'main', readme_url TEXT, installed_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, content_hash TEXT, repository_path TEXT)")
            if try !db.rows("PRAGMA table_info(skills_metadata)").contains(where: { $0["name"] == "repository_path" }) {
                try db.execute("ALTER TABLE skills_metadata ADD COLUMN repository_path TEXT")
            }
            try db.execute("CREATE TABLE IF NOT EXISTS workspace_migrations (name TEXT PRIMARY KEY)")
            if try db.rows("SELECT name FROM workspace_migrations WHERE name=?", ["private_skill_store_v1"]).isEmpty {
                if !hadRepos {
                    let legacyURL = URL(fileURLWithPath: homeDir).appendingPathComponent(".quotio/skill_repos.json")
                    let repos: [SkillRepo]
                    if fileManager.fileExists(atPath: legacyURL.path) {
                        repos = try JSONDecoder().decode([SkillRepo].self, from: Data(contentsOf: legacyURL))
                    } else { repos = defaultRepos() }
                    for repo in repos { try insertRepo(db, repo, source: "initial") }
                }
                try importSkillLockMetadata(db: db)
                try db.execute("INSERT INTO workspace_migrations(name) VALUES (?)", ["private_skill_store_v1"])
            }
        }
        prepared = true
    }

    public nonisolated func agentSkillDirectory(for agent: WorkspaceAgent) -> String {
        let suffix: String
        switch agent {
        case .claude: suffix = ".claude/skills"
        case .codex: suffix = ".agents/skills"
        case .opencode: suffix = ".config/opencode/skills"
        case .pi: suffix = ".pi/agent/skills"
        case .agy: suffix = ".gemini/skills"
        }
        return (homeDir as NSString).appendingPathComponent(suffix)
    }

    public nonisolated func defaultRepos() -> [SkillRepo] {
        [SkillRepo(owner: "anthropics", name: "skills"),
         SkillRepo(owner: "vercel-labs", name: "skills", branch: "HEAD"),
         SkillRepo(owner: "ComposioHQ", name: "awesome-claude-skills", branch: "master")]
    }

    // MARK: - 元数据（读取不执行迁移、修复或重新写入）

    public func loadRepos() throws -> [SkillRepo] {
        let db = try database(readOnly: true)
        return try db.rows("SELECT owner,name,branch,enabled FROM skill_repos ORDER BY rowid").map {
            SkillRepo(owner: $0["owner"]!, name: $0["name"]!, branch: $0["branch"] ?? "main", isEnabled: $0["enabled"] != "0")
        }
    }

    public func saveRepos(_ repos: [SkillRepo]) throws {
        let db = try database()
        try db.transaction {
            try db.execute("DELETE FROM skill_repos")
            for repo in repos { try insertRepo(db, repo, source: "user") }
        }
    }

    public func addRepo(_ repo: SkillRepo) throws { try insertRepo(database(), repo, source: "user") }

    public func removeRepo(_ repo: SkillRepo) throws {
        try database().execute("DELETE FROM skill_repos WHERE owner=? AND name=?", [repo.owner, repo.name])
    }

    public func loadInstalledSkills() async throws -> [WorkspaceSkill] {
        let metadata = try loadMetadata()
        guard fileManager.fileExists(atPath: ssotSkillsDir) else { return [] }
        var skills: [WorkspaceSkill] = []
        for directory in try fileManager.contentsOfDirectory(atPath: ssotSkillsDir).sorted() where !directory.hasPrefix(".") {
            let path = try managedPath(directory)
            guard isRegularDirectory(path), fileManager.fileExists(atPath: path + "/SKILL.md") else { continue }
            let parsed = try parseSkill(at: path, defaultName: directory)
            var enabled: Set<WorkspaceAgent> = []
            for agent in WorkspaceAgent.allCases where try isEnabled(directory: directory, name: parsed.name, agent: agent) {
                enabled.insert(agent)
            }
            let meta = metadata[directory]
            // 如果元数据没有有效时间戳，尝试从文件系统获取 SKILL.md 或技能目录的真实修改时间
            let fileModDate: Date? = {
                let skillFile = path + "/SKILL.md"
                if let attrs = try? fileManager.attributesOfItem(atPath: skillFile),
                   let date = attrs[.modificationDate] as? Date,
                   date.timeIntervalSince1970 > 86400 {
                    return date
                }
                if let dirAttrs = try? fileManager.attributesOfItem(atPath: path),
                   let date = dirAttrs[.modificationDate] as? Date,
                   date.timeIntervalSince1970 > 86400 {
                    return date
                }
                return nil
            }()

            let effectiveUpdatedAt: Date? = {
                if let d = meta?.updatedAt, d.timeIntervalSince1970 > 86400 {
                    return d
                }
                return fileModDate
            }()

            let effectiveInstalledAt: Date? = {
                if let d = meta?.installedAt, d.timeIntervalSince1970 > 86400 {
                    return d
                }
                return fileModDate
            }()

            skills.append(WorkspaceSkill(name: parsed.name, description: parsed.description, directory: directory,
                readmeURL: meta?.readmeURL, repoOwner: meta?.repoOwner, repoName: meta?.repoName, repoBranch: meta?.repoBranch,
                installedAt: effectiveInstalledAt, updatedAt: effectiveUpdatedAt,
                contentHash: meta?.contentHash, enabledAgents: enabled, repositoryRelativePath: meta?.repositoryPath))
        }
        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 受管链接与客户端原生配置

    public func toggleAgent(skillDirectory: String, agent: WorkspaceAgent, enable: Bool) throws {
        try requireIdle(skillDirectory)
        try toggleAgentInternal(directory: skillDirectory, agent: agent, enable: enable)
    }

    public func bulkToggleAllAgents(skillDirectory: String, enable: Bool) throws {
        try requireIdle(skillDirectory)
        let snapshot = try snapshotDistribution(directory: skillDirectory)
        do {
            for agent in WorkspaceAgent.allCases { try toggleAgentInternal(directory: skillDirectory, agent: agent, enable: enable) }
        } catch { try restoreOrReport(snapshot, original: error) }
    }

    private func toggleAgentInternal(directory: String, agent: WorkspaceAgent, enable: Bool) throws {
        let path = try managedPath(directory)
        guard isRegularDirectory(path) else { throw WorkspaceSkillError.invalidPath(path) }
        let name = try parseSkill(at: path, defaultName: directory).name
        let links = distributionPaths(directory: directory, agent: agent)
        // 无论启用还是停用，独立目录与指向其他来源的链接都不能由本服务删除。
        for link in links { try validateLinkOwnership(link, target: path) }
        let clientConfiguration = WorkspaceSkillClientConfiguration(homeDir: homeDir)
        var config = try clientConfiguration.change(agent: agent, skillDirectory: directory, skillName: name, enabled: enable)
        if agent == .claude || agent == .codex {
            // 创建兼容扫描目录中的链接之前固定 OpenCode 原状态；否则仅启用 Claude
            // 就会在 OpenCode 中意外新增一个技能，破坏独立开关的语义。
            let keepOpenCodeEnabled = try isEnabled(directory: directory, name: name, agent: .opencode)
            config += try clientConfiguration.change(agent: .opencode, skillDirectory: directory, skillName: name, enabled: keepOpenCodeEnabled)
        }
        let snapshot = try snapshot(paths: links + config.map(\.path))
        do {
            for change in config { try writeConfiguration(change) }
            for link in links where isOwnedLink(link, target: path) { try fileManager.removeItem(atPath: link) }
            if enable {
                let link = links[0]
                try ensureDistributionParent(link)
                try fileManager.createSymbolicLink(atPath: link, withDestinationPath: path)
            }
        } catch { try restoreOrReport(snapshot, original: error) }
    }

    private func isEnabled(directory: String, name: String, agent: WorkspaceAgent) throws -> Bool {
        let target = try managedPath(directory)
        let links: [String]
        if agent == .opencode {
            links = [.opencode, .claude, .codex].flatMap { distributionPaths(directory: directory, agent: $0) }
        } else { links = distributionPaths(directory: directory, agent: agent) }
        guard links.contains(where: { isOwnedLink($0, target: target) }) else { return false }
        return try WorkspaceSkillClientConfiguration(homeDir: homeDir).isEnabled(agent: agent, skillDirectory: directory, skillName: name)
    }

    // MARK: - 备份与卸载

    /// 备份属于破坏性操作的前置条件；创建失败立即抛错，UUID 避免同秒多次操作互相覆盖。
    public func backupSkillBeforeAction(skillDirectory: String) throws {
        let source = try managedPath(skillDirectory)
        guard isRegularDirectory(source) else { throw WorkspaceSkillError.invalidPath(source) }
        try backupDirectory(source, name: skillDirectory)
    }

    public func uninstallSkill(skillDirectory: String) throws {
        try requireIdle(skillDirectory)
        let path = try managedPath(skillDirectory)
        guard isRegularDirectory(path) else { throw WorkspaceSkillError.invalidPath(path) }
        try backupSkillBeforeAction(skillDirectory: skillDirectory)
        let links = WorkspaceAgent.allCases.flatMap { distributionPaths(directory: skillDirectory, agent: $0) }
            .filter { isOwnedLink($0, target: path) }
        let snapshot = try snapshot(paths: links)
        let quarantine = ssotSkillsDir + "/.uninstall-" + UUID().uuidString
        let db = try database()
        do {
            try db.transaction {
                try fileManager.moveItem(atPath: path, toPath: quarantine)
                for link in links { try fileManager.removeItem(atPath: link) }
                try db.execute("DELETE FROM skills_metadata WHERE directory=?", [skillDirectory])
            }
        } catch {
            if fileManager.fileExists(atPath: quarantine), !fileManager.fileExists(atPath: path) {
                do { try fileManager.moveItem(atPath: quarantine, toPath: path) }
                catch { throw WorkspaceSkillError.incompleteOperation("恢复目录失败，备份保存在 \(backupsDir)：\(error.localizedDescription)") }
            }
            try restoreOrReport(snapshot, original: error)
        }
        // 正式目录、元数据与受管链接已一致提交；备份仍保留，即使清理暂存失败也明确报告。
        try fileManager.removeItem(atPath: quarantine)
    }

    // MARK: - 仓库发现与完整目录安装

    private struct TreeEntry: Decodable, Sendable {
        let path: String
        let mode: String
        let type: String
        let sha: String
        let size: Int?
        var revision: String?
    }
    private struct TreeResponse: Decodable, Sendable { let tree: [TreeEntry]; let truncated: Bool? }
    private struct CommitResponse: Decodable, Sendable { let sha: String }

    public func discoverSkills(repo: SkillRepo) async throws -> [DiscoverableSkill] {
        let tree = try await fetchTree(repo)
        var result: [DiscoverableSkill] = []
        for entry in tree where entry.type == "blob" && (entry.path as NSString).lastPathComponent == "SKILL.md" {
            guard entry.mode == "100644" || entry.mode == "100755" else { continue }
            let relative = (entry.path as NSString).deletingLastPathComponent
            let directory = relative.isEmpty ? repo.name : (relative as NSString).lastPathComponent
            let text = try await fetchBlob(entry, repo: repo)
            guard let content = String(data: text, encoding: .utf8) else { throw WorkspaceSkillError.invalidRepository(entry.path) }
            let parsed = try parseSkillText(content, defaultName: directory)
            result.append(DiscoverableSkill(name: parsed.name, description: parsed.description, directory: directory,
                repoOwner: repo.owner, repoName: repo.name, repoBranch: repo.branch,
                readmeURL: "https://github.com/\(repo.owner)/\(repo.name)/tree/\(repo.branch)/\(relative)", repositoryRelativePath: relative))
        }
        return result
    }

    public func installSkill(skill: DiscoverableSkill, targetAgents: Set<WorkspaceAgent>) async throws {
        try requireIdle(skill.directory)
        busySkills.insert(skill.directory)
        defer { busySkills.remove(skill.directory) }
        let old = try loadMetadata()[skill.directory]
        let target = try managedPath(skill.directory)
        if fileManager.fileExists(atPath: target) {
            guard let old, old.repoOwner == skill.repoOwner, old.repoName == skill.repoName,
                  old.repositoryPath == skill.repositoryRelativePath else { throw WorkspaceSkillError.conflict(target) }
        }
        try await installCompleteDirectory(skill: skill, targetAgents: targetAgents, previous: old)
    }

    private func installCompleteDirectory(skill: DiscoverableSkill, targetAgents: Set<WorkspaceAgent>, previous: SkillMetadata?) async throws {
        let repo = SkillRepo(owner: skill.repoOwner, name: skill.repoName, branch: skill.repoBranch)
        let tree = try await fetchTree(repo)
        let relative = try resolveRepositoryPath(skill: skill, tree: tree)
        let selected = tree.filter { relative.isEmpty || $0.path.hasPrefix(relative + "/") }
        guard selected.contains(where: { $0.path == (relative.isEmpty ? "SKILL.md" : relative + "/SKILL.md") }) else {
            throw WorkspaceSkillError.invalidRepository(relative)
        }
        let stage = ssotSkillsDir + "/.download-" + UUID().uuidString
        try fileManager.createDirectory(atPath: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(atPath: stage) }
        var totalBytes = 0
        for entry in selected {
            guard entry.type == "blob" || entry.type == "tree" else { throw WorkspaceSkillError.invalidRepository("不支持子模块：\(entry.path)") }
            if entry.type == "tree" { continue }
            // Git 软链接不能当普通文件安装；拒绝整个包，避免落地后逃出技能边界。
            guard entry.mode == "100644" || entry.mode == "100755" else { throw WorkspaceSkillError.invalidPath(entry.path) }
            let subpath = relative.isEmpty ? entry.path : String(entry.path.dropFirst(relative.count + 1))
            try validateRelativePath(subpath)
            let data = try await fetchBlob(entry, repo: repo)
            totalBytes += data.count
            guard totalBytes <= 100 * 1_024 * 1_024 else { throw WorkspaceSkillError.invalidRepository("技能目录超过 100 MB") }
            let file = URL(fileURLWithPath: stage).appendingPathComponent(subpath)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            if entry.mode == "100755" { try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
        let parsed = try parseSkill(at: stage, defaultName: skill.directory)
        let destination = try managedPath(skill.directory)
        let exists = fileManager.fileExists(atPath: destination)
        let distribution = try snapshotDistribution(directory: skill.directory)
        let rollback = ssotSkillsDir + "/.previous-" + UUID().uuidString
        let db = try database()
        if exists { try backupSkillBeforeAction(skillDirectory: skill.directory) }
        let meta = SkillMetadata(readmeURL: skill.readmeURL, repoOwner: repo.owner, repoName: repo.name,
            repoBranch: repo.branch, repositoryPath: relative, installedAt: previous?.installedAt ?? Date(),
            updatedAt: Date(), contentHash: try directoryHash(stage))
        var movedNew = false
        do {
            try db.transaction {
                if exists { try fileManager.moveItem(atPath: destination, toPath: rollback) }
                try fileManager.moveItem(atPath: stage, toPath: destination)
                movedNew = true
                // 全部客户端都写入明确开关，避免启用 Claude 时 OpenCode 因兼容扫描被连带启用。
                for agent in WorkspaceAgent.allCases {
                    if targetAgents.contains(agent) || agent == .opencode || agent == .codex {
                        try toggleAgentInternal(directory: skill.directory, agent: agent, enable: targetAgents.contains(agent))
                    }
                }
                try saveMetadata(db, directory: skill.directory, meta: meta, name: parsed.name, description: parsed.description)
            }
        } catch {
            do {
                if movedNew { try fileManager.removeItem(atPath: destination) }
                if fileManager.fileExists(atPath: rollback) { try fileManager.moveItem(atPath: rollback, toPath: destination) }
            } catch { throw WorkspaceSkillError.incompleteOperation("恢复技能目录失败；请使用 \(backupsDir) 中的备份：\(error.localizedDescription)") }
            try restoreOrReport(distribution, original: error)
        }
        if exists { try fileManager.removeItem(atPath: rollback) }
    }

    public func updateAllSkillsReport() async -> WorkspaceOperationResult {
        var count = 0
        var failures: [String] = []
        repositoryTrees.removeAll() // 每次一键更新从新提交开始，同一批内复用固定快照。
        do {
            for skill in try await loadInstalledSkills() {
                guard let owner = skill.repoOwner, let repo = skill.repoName else { continue }
                do {
                    try requireIdle(skill.directory)
                    busySkills.insert(skill.directory)
                    defer { busySkills.remove(skill.directory) }
                    guard let current = try loadMetadata()[skill.directory],
                          isRegularDirectory(try managedPath(skill.directory)) else {
                        throw WorkspaceSkillError.incompleteOperation("技能已被移除，跳过过期更新：\(skill.directory)")
                    }
                    let candidate = DiscoverableSkill(name: skill.name, description: skill.description, directory: skill.directory,
                        repoOwner: owner, repoName: repo, repoBranch: skill.repoBranch ?? "main", readmeURL: skill.readmeURL,
                        repositoryRelativePath: skill.repositoryRelativePath)
                    try await installCompleteDirectory(skill: candidate, targetAgents: skill.enabledAgents, previous: current)
                    count += 1
                } catch { failures.append("\(skill.name)：\(error.localizedDescription)") }
            }
        } catch { failures.append(error.localizedDescription) }
        return WorkspaceOperationResult(succeededCount: count, freedBytes: 0, failures: failures)
    }

    public func updateAllSkills() async throws -> Int {
        let report = await updateAllSkillsReport()
        guard report.failures.isEmpty else { throw WorkspaceSkillError.incompleteOperation(report.failures.joined(separator: "\n")) }
        return report.succeededCount
    }

    // MARK: - 本地技能纳管与导出

    public func scanUnmanagedSkills() async throws -> [UnmanagedSkill] {
        _ = try database(readOnly: true)
        var result: [UnmanagedSkill] = []
        for agent in WorkspaceAgent.allCases {
            for directory in Set(distributionPaths(directory: "placeholder", agent: agent).map { ($0 as NSString).deletingLastPathComponent }) {
                guard fileManager.fileExists(atPath: directory) else { continue }
                for name in try fileManager.contentsOfDirectory(atPath: directory).sorted() {
                    let path = directory + "/" + name
                    if isRegularDirectory(path), fileManager.fileExists(atPath: path + "/SKILL.md") {
                        result.append(UnmanagedSkill(name: name, agent: agent, directoryPath: path))
                    }
                }
            }
        }
        return result
    }

    public func importUnmanagedSkill(_ unmanaged: UnmanagedSkill) throws {
        try requireIdle(unmanaged.name)
        let destination = try managedPath(unmanaged.name)
        let allowedSources = distributionPaths(directory: unmanaged.name, agent: unmanaged.agent)
        guard allowedSources.contains(unmanaged.directoryPath), isRegularDirectory(unmanaged.directoryPath) else {
            throw WorkspaceSkillError.invalidPath(unmanaged.directoryPath)
        }
        let source = unmanaged.directoryPath
        try ensureDistributionParent(source, create: false)
        let parsed = try parseSkill(at: source, defaultName: unmanaged.name)
        let previous = try loadMetadata()[unmanaged.name]
        let exists = fileManager.fileExists(atPath: destination)
        if !exists, previous?.repoOwner != nil {
            // 旧 lock 以目录名为键，不能把其他客户端碰巧同名的本地技能当成该仓库版本。
            // 只接受 lock 对应的共享目录本身，或经完整内容（含执行位）校验一致的副本；
            // 无法证明同源时先报告冲突，保留两份原内容与来源信息，避免未来更新覆盖本地版本。
            let sharedSource = homeDir + "/.agents/skills/" + unmanaged.name
            let isRecordedSource = URL(fileURLWithPath: source).standardizedFileURL.path
                == URL(fileURLWithPath: sharedSource).standardizedFileURL.path
            if !isRecordedSource {
                guard isRegularDirectory(sharedSource), try directoryHash(source) == directoryHash(sharedSource) else {
                    throw WorkspaceSkillError.conflict("\(source) 与旧技能记录 \(sharedSource) 来源不一致")
                }
            }
        }
        // 同名且内容不同必须保留双方，不以“备份统一库旧版本”代替备份待纳管内容。
        if exists, try directoryHash(source) != directoryHash(destination) { throw WorkspaceSkillError.conflict(destination) }
        try backupDirectory(source, name: unmanaged.name)
        let snapshot = try snapshotDistribution(directory: unmanaged.name, excluding: [source])
        let rollbackSource = (source as NSString).deletingLastPathComponent + "/.quotio-import-" + UUID().uuidString
        var copied = false
        let db = try database()
        do {
            try db.transaction {
                if !exists {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                    copied = true
                }
                try fileManager.moveItem(atPath: source, toPath: rollbackSource)
                try toggleAgentInternal(directory: unmanaged.name, agent: unmanaged.agent, enable: true)
                if !exists {
                    // prepareStorage 可能已从旧 skill-lock 导入来源；纳管内容不能覆盖掉
                    // repo/path/installedAt，否则迁入私有库后会失去自动更新能力。
                    let meta = SkillMetadata(readmeURL: previous?.readmeURL, repoOwner: previous?.repoOwner,
                        repoName: previous?.repoName, repoBranch: previous?.repoBranch,
                        repositoryPath: previous?.repositoryPath, installedAt: previous?.installedAt ?? Date(),
                        updatedAt: Date(), contentHash: try directoryHash(destination))
                    try saveMetadata(db, directory: unmanaged.name, meta: meta, name: parsed.name, description: parsed.description)
                }
            }
        } catch {
            do {
                if isOwnedLink(source, target: destination) { try fileManager.removeItem(atPath: source) }
                if fileManager.fileExists(atPath: rollbackSource) { try fileManager.moveItem(atPath: rollbackSource, toPath: source) }
                if copied { try fileManager.removeItem(atPath: destination) }
            } catch { throw WorkspaceSkillError.incompleteOperation("恢复纳管来源失败；备份：\(backupsDir)") }
            try restoreOrReport(snapshot, original: error)
        }
        try fileManager.removeItem(atPath: rollbackSource)
    }

    public func exportSkillsArchive(to destinationURL: URL) throws {
        _ = try database(readOnly: true)
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(".quotio-export-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = URL(fileURLWithPath: ssotSkillsDir)
        // 只导出已安装的正式目录，不将正在下载、回滚或卸载的隐藏暂存目录写入归档。
        let names = try fileManager.contentsOfDirectory(atPath: ssotSkillsDir).filter { !$0.hasPrefix(".") && isRegularDirectory(ssotSkillsDir + "/" + $0) }
        guard !names.isEmpty else { throw WorkspaceSkillError.incompleteOperation("没有可导出的技能") }
        process.arguments = ["-rq", temporary.path, "--"] + names
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkspaceSkillError.incompleteOperation("ZIP 导出失败，原目标文件已保留") }
        // 同目录临时文件保证最终替换在同一文件系统；ZIP 成功前不删除用户已有归档。
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporary)
        } else { try fileManager.moveItem(at: temporary, to: destinationURL) }
    }

    // MARK: - 安全路径与文件恢复

    private func database(readOnly: Bool = false) throws -> WorkspaceSkillDatabase {
        guard prepared else { throw WorkspaceSkillError.notPrepared }
        return try WorkspaceSkillDatabase(path: dbPath, readOnly: readOnly)
    }

    private func requireIdle(_ directory: String) throws {
        _ = try database(readOnly: true)
        _ = try managedPath(directory)
        guard !busySkills.contains(directory) else { throw WorkspaceSkillError.busy(directory) }
    }

    private func validatePrivateRoot(_ path: String) throws {
        let expected = URL(fileURLWithPath: path).standardizedFileURL.path
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected else { throw WorkspaceSkillError.invalidPath(path) }
    }

    private func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkspaceSkillError.invalidPath(path)
        }
    }

    private func managedPath(_ directory: String) throws -> String {
        try validateRelativePath(directory)
        guard !directory.contains("/"), !directory.hasPrefix(".") else { throw WorkspaceSkillError.invalidPath(directory) }
        try validatePrivateRoot(ssotSkillsDir)
        let path = ssotSkillsDir + "/" + directory
        guard !isSymlink(path) else { throw WorkspaceSkillError.invalidPath(path) }
        return path
    }

    private func isSymlink(_ path: String) -> Bool { (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil }
    private func isRegularDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return !isSymlink(path) && fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func isOwnedLink(_ path: String, target: String) -> Bool {
        guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: path) else { return false }
        let resolved = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)).standardizedFileURL.path
        return resolved == URL(fileURLWithPath: target).standardizedFileURL.path
    }

    private func validateLinkOwnership(_ link: String, target: String) throws {
        try ensureDistributionParent(link, create: false)
        if (fileManager.fileExists(atPath: link) || isSymlink(link)), !isOwnedLink(link, target: target) {
            throw WorkspaceSkillError.conflict(link)
        }
    }

    private func ensureDistributionParent(_ link: String, create: Bool = true) throws {
        let parent = (link as NSString).deletingLastPathComponent
        // 禁止整个技能目录软链到统一库；否则删除“客户端链接”实际上会删除统一库内容。
        guard URL(fileURLWithPath: parent).standardizedFileURL.path == URL(fileURLWithPath: parent).resolvingSymlinksInPath().path else {
            throw WorkspaceSkillError.conflict(parent)
        }
        if create { try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true) }
    }

    private func distributionPaths(directory: String, agent: WorkspaceAgent) -> [String] {
        var paths = [agentSkillDirectory(for: agent) + "/" + directory]
        if agent == .codex { paths.append(homeDir + "/.codex/skills/" + directory) }
        return paths
    }

    private func backupDirectory(_ source: String, name: String) throws {
        try validatePrivateRoot(backupsDir)
        try fileManager.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)
        _ = try directoryHash(source) // 同时拒绝越界软链接、设备文件和不可读的内容。
        let destination = backupsDir + "/\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)-\(name)"
        try fileManager.copyItem(atPath: source, toPath: destination)
        guard try directoryHash(source) == directoryHash(destination) else {
            throw WorkspaceSkillError.incompleteOperation("备份校验失败：\(destination)")
        }
    }

    private func directoryHash(_ path: String) throws -> String {
        guard isRegularDirectory(path) else { throw WorkspaceSkillError.invalidPath(path) }
        var hasher = SHA256()
        func visit(_ folder: String, relative: String) throws {
            for name in try fileManager.contentsOfDirectory(atPath: folder).sorted() {
                let full = folder + "/" + name
                let part = relative + name
                guard !isSymlink(full) else { throw WorkspaceSkillError.invalidPath(full) }
                let attributes = try fileManager.attributesOfItem(atPath: full)
                hasher.update(data: Data(part.utf8))
                hasher.update(data: Data([0]))
                // 执行位也是技能内容契约；脚本字节相同但权限不同不能视为可丢弃的重复版本。
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                hasher.update(data: Data(String(permissions & 0o777).utf8))
                hasher.update(data: Data([0]))
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    hasher.update(data: Data("directory".utf8))
                    try visit(full, relative: part + "/")
                } else if attributes[.type] as? FileAttributeType == .typeRegular {
                    hasher.update(data: Data("file".utf8))
                    hasher.update(data: try Data(contentsOf: URL(fileURLWithPath: full)))
                } else { throw WorkspaceSkillError.invalidPath(full) }
            }
        }
        try visit(path, relative: "")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum FileSnapshot { case absent(String), file(String, Data), link(String, String) }
    private func snapshot(paths: [String]) throws -> [FileSnapshot] {
        try Array(Set(paths)).sorted().map { path in
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: path) { return .link(path, target) }
            if !fileManager.fileExists(atPath: path) { return .absent(path) }
            if isRegularDirectory(path) { throw WorkspaceSkillError.conflict(path) }
            return .file(path, try Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }

    private func snapshotDistribution(directory: String, excluding: Set<String> = []) throws -> [FileSnapshot] {
        let target = try managedPath(directory)
        let links = WorkspaceAgent.allCases.flatMap { distributionPaths(directory: directory, agent: $0) }
            .filter { !excluding.contains($0) && (!fileManager.fileExists(atPath: $0) && !isSymlink($0) || isOwnedLink($0, target: target)) }
        return try snapshot(paths: links + WorkspaceSkillClientConfiguration(homeDir: homeDir).configurationPaths)
    }

    private func restoreOrReport(_ snapshots: [FileSnapshot], original: Error) throws -> Never {
        var failures: [String] = []
        for item in snapshots {
            do {
                switch item {
                case .absent(let path):
                    if fileManager.fileExists(atPath: path) || isSymlink(path) { try fileManager.removeItem(atPath: path) }
                case .file(let path, let data): try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                case .link(let path, let target):
                    if fileManager.fileExists(atPath: path) || isSymlink(path) { try fileManager.removeItem(atPath: path) }
                    try fileManager.createSymbolicLink(atPath: path, withDestinationPath: target)
                }
            } catch { failures.append(error.localizedDescription) }
        }
        if failures.isEmpty { throw original }
        throw WorkspaceSkillError.incompleteOperation(original.localizedDescription + "；恢复失败：" + failures.joined(separator: "；"))
    }

    private func writeConfiguration(_ change: WorkspaceSkillClientConfiguration.Change) throws {
        let url = URL(fileURLWithPath: change.path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try change.data.write(to: url, options: .atomic)
    }

    // MARK: - GitHub API（固定提交 SHA，防止同一次安装混入不同提交的文件）

    private func fetchTree(_ repo: SkillRepo) async throws -> [TreeEntry] {
        for value in [repo.owner, repo.name] {
            guard value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil, value != ".", value != ".." else {
                throw WorkspaceSkillError.invalidRepository(repo.id)
            }
        }
        guard let branch = repo.branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) else {
            throw WorkspaceSkillError.invalidRepository(repo.branch)
        }
        let cacheKey = repo.id + "@" + repo.branch
        if let cached = repositoryTrees[cacheKey], Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        let commitData = try await fetchData("https://api.github.com/repos/\(repo.owner)/\(repo.name)/commits/\(branch)")
        let revision = try JSONDecoder().decode(CommitResponse.self, from: commitData).sha
        guard revision.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil else {
            throw WorkspaceSkillError.invalidRepository("仓库提交 SHA 无效")
        }
        let data = try await fetchData("https://api.github.com/repos/\(repo.owner)/\(repo.name)/git/trees/\(revision)?recursive=1")
        let result = try JSONDecoder().decode(TreeResponse.self, from: data)
        guard result.truncated != true, result.tree.count <= 50_000 else { throw WorkspaceSkillError.invalidRepository("仓库目录树不完整或过大") }
        for entry in result.tree { try validateRelativePath(entry.path) }
        let entries = result.tree.map { entry in var entry = entry; entry.revision = revision; return entry }
        if repositoryTrees.count >= 20, let oldest = repositoryTrees.min(by: { $0.value.0 < $1.value.0 })?.key {
            repositoryTrees.removeValue(forKey: oldest)
        }
        repositoryTrees[cacheKey] = (Date(), entries)
        return entries
    }

    private func fetchBlob(_ entry: TreeEntry, repo: SkillRepo) async throws -> Data {
        guard entry.sha.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil,
              (entry.size ?? 0) <= 50 * 1_024 * 1_024 else { throw WorkspaceSkillError.invalidRepository(entry.path) }
        guard let revision = entry.revision,
              let path = entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) else {
            throw WorkspaceSkillError.invalidRepository(entry.path)
        }
        // 固定 commit SHA 的 raw 内容与目录树属于同一次快照；下载脚本/资源不再逐个
        // 调用受每小时 60 次匿名额度限制的 GitHub Blob API。
        let data = try await fetchData("https://raw.githubusercontent.com/\(repo.owner)/\(repo.name)/\(revision)/\(path)")
        guard data.count <= 50 * 1_024 * 1_024 else { throw WorkspaceSkillError.requestFailed(entry.path) }
        return data
    }

    private func fetchData(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw WorkspaceSkillError.invalidRepository(urlString) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Quotio-MacApp", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkspaceSkillError.requestFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private func resolveRepositoryPath(skill: DiscoverableSkill, tree: [TreeEntry]) throws -> String {
        if let path = skill.repositoryRelativePath {
            if !path.isEmpty { try validateRelativePath(path) }
            return path
        }
        // 旧记录缺失真实路径时，仅允许树中唯一同名 SKILL.md 目录；禁止猜测仓库根文档。
        let matches = tree.filter { $0.type == "blob" && ($0.path as NSString).lastPathComponent == "SKILL.md" }
            .map { ($0.path as NSString).deletingLastPathComponent }
            .filter { ($0 as NSString).lastPathComponent == skill.directory }
        guard matches.count == 1 else { throw WorkspaceSkillError.invalidRepository("\(skill.directory) 缺少唯一仓库路径，请重新选择来源") }
        return matches[0]
    }

    private func parseSkill(at path: String, defaultName: String) throws -> (name: String, description: String) {
        try parseSkillText(String(contentsOfFile: path + "/SKILL.md", encoding: .utf8), defaultName: defaultName)
    }

    private func parseSkillText(_ content: String, defaultName: String) throws -> (name: String, description: String) {
        let lines = content.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
            let yaml = lines[1..<end].joined(separator: "\n")
            if let values = try Yams.load(yaml: yaml) as? [String: Any] {
                let name = (values["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultName
                guard !name.isEmpty else { throw WorkspaceSkillError.invalidRepository("SKILL.md name 为空") }
                return (name, values["description"] as? String ?? "本地技能")
            }
        }
        return (defaultName, lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) ?? "本地技能")
    }

    // MARK: - SQLite 元数据与旧 lock 一次导入

    private struct SkillMetadata {
        let readmeURL: String?
        let repoOwner: String?
        let repoName: String?
        let repoBranch: String?
        let repositoryPath: String?
        let installedAt: Date
        let updatedAt: Date
        let contentHash: String?
    }

    private func insertRepo(_ db: WorkspaceSkillDatabase, _ repo: SkillRepo, source: String) throws {
        try db.execute("INSERT INTO skill_repos(owner,name,branch,enabled,source,created_at) VALUES(?,?,?,?,?,?) ON CONFLICT(owner,name) DO UPDATE SET branch=excluded.branch,enabled=excluded.enabled,source=excluded.source",
            [repo.owner, repo.name, repo.branch, repo.isEnabled ? "1" : "0", source, String(Int(Date().timeIntervalSince1970))])
    }

    private func loadMetadata() throws -> [String: SkillMetadata] {
        var result: [String: SkillMetadata] = [:]
        for row in try database(readOnly: true).rows("SELECT * FROM skills_metadata") {
            guard let directory = row["directory"] else { continue }
            result[directory] = SkillMetadata(readmeURL: row["readme_url"], repoOwner: row["repo_owner"], repoName: row["repo_name"], repoBranch: row["repo_branch"],
                repositoryPath: row["repository_path"], installedAt: Date(timeIntervalSince1970: Double(row["installed_at"] ?? "0") ?? 0),
                updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "0") ?? 0), contentHash: row["content_hash"])
        }
        return result
    }

    private func saveMetadata(_ db: WorkspaceSkillDatabase, directory: String, meta: SkillMetadata, name: String? = nil, description: String? = nil, ignoreExisting: Bool = false) throws {
        let mode = ignoreExisting ? "IGNORE" : "REPLACE"
        try db.execute("INSERT OR \(mode) INTO skills_metadata(directory,name,description,repo_owner,repo_name,repo_branch,repository_path,readme_url,installed_at,updated_at,content_hash) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            [directory, name, description, meta.repoOwner, meta.repoName, meta.repoBranch, meta.repositoryPath, meta.readmeURL,
             String(Int(meta.installedAt.timeIntervalSince1970)), String(Int(meta.updatedAt.timeIntervalSince1970)), meta.contentHash])
    }

    private func importSkillLockMetadata(db: WorkspaceSkillDatabase) throws {
        let path = homeDir + "/.agents/.skill-lock.json"
        guard fileManager.fileExists(atPath: path) else { return }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        guard let skills = json?["skills"] as? [String: [String: Any]] else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (directory, item) in skills {
            let source = (item["source"] as? String ?? "").split(separator: "/")
            guard source.count == 2 else { continue }
            let rawPath = item["skillPath"] as? String
            let relative = rawPath.map { ($0 as NSString).lastPathComponent == "SKILL.md" ? ($0 as NSString).deletingLastPathComponent : $0 }
            let installed = (item["installedAt"] as? String).flatMap(formatter.date(from:)) ?? .distantPast
            let meta = SkillMetadata(readmeURL: item["sourceUrl"] as? String, repoOwner: String(source[0]), repoName: String(source[1]),
                repoBranch: item["branch"] as? String ?? "main", repositoryPath: relative, installedAt: installed,
                updatedAt: (item["updatedAt"] as? String).flatMap(formatter.date(from:)) ?? installed, contentHash: item["skillFolderHash"] as? String)
            try saveMetadata(db, directory: directory, meta: meta, ignoreExisting: true)
            // 仅补齐旧记录缺失的真实路径，不覆盖 Quotio 后续更新保存的来源、时间或内容哈希。
            try db.execute("UPDATE skills_metadata SET repository_path=? WHERE directory=? AND repository_path IS NULL", [relative, directory])
        }
    }
}
