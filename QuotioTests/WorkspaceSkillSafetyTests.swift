import XCTest
import Foundation
@testable import Quotio

/// 所有文件和配置都在每个测试独立的临时 HOME 下，网络由 URLProtocol fixture 接管，
/// 防止回归测试初始化真实技能库、修改用户 CLI 配置或访问外部仓库。
final class WorkspaceSkillSafetyTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("QuotioSkillSafety-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    private func service() async throws -> WorkspaceSkillService {
        let service = WorkspaceSkillService(homeDir: home.path)
        try await service.prepareStorage()
        return service
    }

    private func writeSkill(_ relative: String, name: String = "review", body: String = "fixture") throws -> URL {
        let directory = home.appendingPathComponent(relative)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: fixture\n---\n\(body)".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    func testInitializationHasNoIOAndPrepareDoesNotMoveSharedSkills() async throws {
        let shared = try writeSkill(".agents/skills/review")
        let service = WorkspaceSkillService(homeDir: home.path)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".quotio").path))
        try await service.prepareStorage()
        XCTAssertTrue(fm.fileExists(atPath: shared.path))
        let installed = try await service.loadInstalledSkills()
        XCTAssertTrue(installed.isEmpty)
    }

    func testToggleAndUninstallPreserveIndependentClientDirectory() async throws {
        let service = try await service()
        _ = try writeSkill(".quotio/skills/review", body: "managed")
        let independent = try writeSkill(".claude/skills/review", body: "private edits")
        let original = try Data(contentsOf: independent.appendingPathComponent("SKILL.md"))
        do {
            try await service.toggleAgent(skillDirectory: "review", agent: .claude, enable: true)
            XCTFail("独立目录必须报告冲突")
        } catch { XCTAssertTrue(error.localizedDescription.contains("保留")) }
        try await service.uninstallSkill(skillDirectory: "review")
        XCTAssertEqual(try Data(contentsOf: independent.appendingPathComponent("SKILL.md")), original)
    }

    func testImportConflictPreservesBothVersions() async throws {
        let service = try await service()
        let managed = try writeSkill(".quotio/skills/review", body: "managed")
        let independent = try writeSkill(".claude/skills/review", body: "private edits")
        let beforeManaged = try Data(contentsOf: managed.appendingPathComponent("SKILL.md"))
        let beforeIndependent = try Data(contentsOf: independent.appendingPathComponent("SKILL.md"))
        do {
            try await service.importUnmanagedSkill(UnmanagedSkill(name: "review", agent: .claude, directoryPath: independent.path))
            XCTFail("不同内容的同名技能必须报告冲突")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: managed.appendingPathComponent("SKILL.md")), beforeManaged)
        XCTAssertEqual(try Data(contentsOf: independent.appendingPathComponent("SKILL.md")), beforeIndependent)
    }

    func testBackupFailurePreventsUninstallAndImportDeletion() async throws {
        let service = try await service()
        let managed = try writeSkill(".quotio/skills/review")
        let backup = home.appendingPathComponent(".quotio/skill_backups")
        try fm.removeItem(at: backup)
        try Data("not a directory".utf8).write(to: backup)
        do { try await service.uninstallSkill(skillDirectory: "review"); XCTFail("备份失败必须中止") } catch { }
        XCTAssertTrue(fm.fileExists(atPath: managed.appendingPathComponent("SKILL.md").path))
        let source = try writeSkill(".claude/skills/another", name: "another")
        do {
            try await service.importUnmanagedSkill(UnmanagedSkill(name: "another", agent: .claude, directoryPath: source.path))
            XCTFail("备份失败必须保留纳管来源")
        } catch { }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".quotio/skills/another").path))
    }

    func testCodexDisableRemovesLegacyLinkAndNativeStateWhileClaudeRemainsEnabled() async throws {
        let service = try await service()
        let managed = try writeSkill(".quotio/skills/review")
        try await service.toggleAgent(skillDirectory: "review", agent: .claude, enable: true)
        var installed = try await service.loadInstalledSkills()
        XCTAssertTrue(installed[0].enabledAgents.contains(.claude))
        XCTAssertFalse(installed[0].enabledAgents.contains(.opencode), "Claude 链接不应意外启用 OpenCode")
        try await service.toggleAgent(skillDirectory: "review", agent: .codex, enable: true)
        let legacy = home.appendingPathComponent(".codex/skills/review")
        try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: legacy, withDestinationURL: managed)
        try await service.toggleAgent(skillDirectory: "review", agent: .codex, enable: false)
        installed = try await service.loadInstalledSkills()
        XCTAssertTrue(installed[0].enabledAgents.contains(.claude))
        XCTAssertFalse(installed[0].enabledAgents.contains(.codex))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".agents/skills/review").path))
        let config = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains(managed.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(config.contains("enabled = false"))
        XCTAssertFalse(config.contains("\\/"), "TOML 不允许 JSON 的斜杠转义")
    }

    func testOpenCodePermissionPreservesJSONCAndOverridesLaterWildcard() throws {
        let source = Data("""
        {
          // provider comment must survive
          "provider": {"private": {"name": "unchanged"}},
          "permission": {
            "bash": "ask",
            "skill": {"review": "allow", "*": "allow",},
          },
        }
        """.utf8)
        let disabled = try OpenCodeConfigEditor.mergingSkillPermission(existing: source, skillName: "review", enabled: false)
        let text = String(decoding: disabled, as: UTF8.self)
        XCTAssertTrue(text.contains("// provider comment must survive"))
        XCTAssertTrue(text.contains("\"provider\": {\"private\": {\"name\": \"unchanged\"}}"))
        XCTAssertEqual(try OpenCodeConfigEditor.skillPermission(existing: disabled, skillName: "review"), "deny")
        XCTAssertEqual(try OpenCodeConfigEditor.skillPermission(existing: disabled, skillName: "other"), "allow")
        let enabled = try OpenCodeConfigEditor.mergingSkillPermission(existing: disabled, skillName: "review", enabled: true)
        XCTAssertEqual(try OpenCodeConfigEditor.skillPermission(existing: enabled, skillName: "review"), "allow")
    }

    func testOpenCodeSkillPermissionSupportsScalarValuesAndGlobalShorthand() throws {
        let created = try OpenCodeConfigEditor.mergingSkillPermission(existing: nil, skillName: "review", enabled: false)
        XCTAssertEqual(try OpenCodeConfigEditor.skillPermission(existing: created, skillName: "review"), "deny")
        let shorthand = Data("{\"permission\":\"ask\",\"model\":\"private-model\"}".utf8)
        let merged = try OpenCodeConfigEditor.mergingSkillPermission(existing: shorthand, skillName: "review", enabled: true)
        XCTAssertEqual(try OpenCodeConfigEditor.skillPermission(existing: merged, skillName: "review"), "allow")
        XCTAssertEqual(try OpenCodeConfigEditor.skillPermission(existing: merged, skillName: "other"), "ask")
        XCTAssertEqual(try OpenCodeConfigEditor.parseObject(merged)["model"] as? String, "private-model")
    }

    func testCodexEditorPreservesUnrelatedSettingsAndMultilinePseudoHeaders() throws {
        let source = "model = \"private-model\"\nprompt = \"\"\"\n[[skills.config]]\npath = \"fake\"\n\"\"\"\n\n[[skills.config]]\npath = '/tmp/review/SKILL.md'\nenabled = true # user comment\n\n[mcp_servers.private]\ncommand = \"server\"\n"
        let output = try WorkspaceSkillCodexConfiguration.setting(source, paths: ["/tmp/review/SKILL.md"], enabled: false)
        XCTAssertTrue(output.contains("model = \"private-model\""))
        XCTAssertTrue(output.contains("path = \"fake\""))
        XCTAssertTrue(output.contains("enabled = false # user comment"))
        XCTAssertTrue(output.contains("[mcp_servers.private]\ncommand = \"server\""))
        XCTAssertFalse(try WorkspaceSkillCodexConfiguration.isEnabled(output, paths: ["/tmp/review/SKILL.md"]))
    }

    func testCodexEditorRefusesInlineSkillsTablesWithoutChangingInput() throws {
        for source in ["skills = {}", "skills = { config = [{ path = '/tmp/review/SKILL.md', enabled = true }] }"] {
            XCTAssertThrowsError(try WorkspaceSkillCodexConfiguration.setting(source, paths: ["/tmp/review/SKILL.md"], enabled: false))
        }
    }

    func testEmptyReposPersistAndFailedSaveRollsBack() async throws {
        let service = try await service()
        try await service.saveRepos([])
        let reopened = WorkspaceSkillService(homeDir: home.path)
        try await reopened.prepareStorage()
        let empty = try await reopened.loadRepos()
        XCTAssertTrue(empty.isEmpty)
        let repo = SkillRepo(owner: "kept", name: "repository")
        try await reopened.saveRepos([repo])
        let database = try WorkspaceSkillDatabase(path: home.appendingPathComponent(".quotio/quotio.db").path)
        try database.execute("CREATE TRIGGER reject_skill_repo_insert BEFORE INSERT ON skill_repos BEGIN SELECT RAISE(ABORT, 'fixture reject'); END")
        do { try await reopened.saveRepos([SkillRepo(owner: "new", name: "repository")]); XCTFail("SQL 错误必须抛出") } catch { }
        let after = try await reopened.loadRepos()
        XCTAssertEqual(after, [repo], "DELETE 和 INSERT 必须处于同一事务")
    }

    func testCompleteNestedSkillInstallPreservesExecutableAndRepositoryPath() async throws {
        let fixture = try networkFixture(failScript: false)
        let service = fixture.service
        try await service.prepareStorage()
        let discovered = try await service.discoverSkills(repo: fixture.repo)
        XCTAssertEqual(discovered.map(\.repositoryRelativePath), ["skills/productivity/review"])
        try await service.installSkill(skill: discovered[0], targetAgents: [.claude])
        let base = home.appendingPathComponent(".quotio/skills/review")
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("scripts/check.sh"), encoding: .utf8), "#!/bin/sh\necho complete\n")
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("references/guide.md"), encoding: .utf8), "reference data")
        let permissions = try fm.attributesOfItem(atPath: base.appendingPathComponent("scripts/check.sh").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o111, 0o111)
        let installed = try await service.loadInstalledSkills()
        XCTAssertEqual(installed[0].repositoryRelativePath, "skills/productivity/review")
        XCTAssertEqual(installed[0].enabledAgents, [.claude])
    }

    func testFailedDownloadDoesNotCreateFinalOrTemporarySkill() async throws {
        let fixture = try networkFixture(failScript: true)
        try await fixture.service.prepareStorage()
        let discovered = try await fixture.service.discoverSkills(repo: fixture.repo)
        do { try await fixture.service.installSkill(skill: discovered[0], targetAgents: [.claude]); XCTFail("失败下载应抛错") } catch { }
        let contents = try fm.contentsOfDirectory(atPath: home.appendingPathComponent(".quotio/skills").path)
        XCTAssertTrue(contents.isEmpty)
        let installed = try await fixture.service.loadInstalledSkills()
        XCTAssertTrue(installed.isEmpty)
    }

    func testInstallConflictRollsBackMetadataAndCompleteDirectory() async throws {
        let fixture = try networkFixture(failScript: false)
        try await fixture.service.prepareStorage()
        let independent = try writeSkill(".claude/skills/review", body: "private")
        let discovered = try await fixture.service.discoverSkills(repo: fixture.repo)
        do { try await fixture.service.installSkill(skill: discovered[0], targetAgents: [.claude]); XCTFail("独立目录冲突应抛出") } catch { }
        XCTAssertTrue(fm.fileExists(atPath: independent.appendingPathComponent("SKILL.md").path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".quotio/skills/review").path))
        let installed = try await fixture.service.loadInstalledSkills()
        XCTAssertTrue(installed.isEmpty)
    }

    func testSkillPathTraversalAndWholeDirectorySymlinkAreRejected() async throws {
        let service = try await service()
        _ = try writeSkill(".quotio/skills/review")
        do { try await service.uninstallSkill(skillDirectory: "../outside"); XCTFail("越界路径必须拒绝") } catch { }
        let claude = home.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: claude, withDestinationURL: home.appendingPathComponent(".quotio/skills"))
        do { try await service.toggleAgent(skillDirectory: "review", agent: .claude, enable: false); XCTFail("整目录软链不能当单项链接处理") } catch { }
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".quotio/skills/review/SKILL.md").path))
    }

    func testLockSourceSurvivesImportIntoPrivateLibrary() async throws {
        let source = try writeSkill(".agents/skills/review")
        let lock: [String: Any] = ["skills": ["review": ["source": "owner/repository", "skillPath": "skills/nested/review/SKILL.md", "installedAt": "2026-08-08T03:49:22.152Z"]]]
        try JSONSerialization.data(withJSONObject: lock).write(to: home.appendingPathComponent(".agents/.skill-lock.json"))
        let service = try await service()
        try await service.importUnmanagedSkill(UnmanagedSkill(name: "review", agent: .codex, directoryPath: source.path))
        let installed = try await service.loadInstalledSkills()
        XCTAssertEqual(installed[0].repoOwner, "owner")
        XCTAssertEqual(installed[0].repoName, "repository")
        XCTAssertEqual(installed[0].repositoryRelativePath, "skills/nested/review")
        // 导入应同时保留安装时间和生成更新时间；先验证可选字段存在，再比较先后关系。
        XCTAssertLessThan(try XCTUnwrap(installed[0].installedAt), try XCTUnwrap(installed[0].updatedAt))
        XCTAssertNotNil(installed[0].contentHash)
    }

    func testSameNameLocalSkillCannotInheritUnrelatedLockSource() async throws {
        let recorded = try writeSkill(".agents/skills/review", body: "repository A")
        let local = try writeSkill(".claude/skills/review", body: "private local B")
        let lock: [String: Any] = ["skills": ["review": ["source": "owner/repository-a", "skillPath": "skills/review/SKILL.md"]]]
        try JSONSerialization.data(withJSONObject: lock).write(to: home.appendingPathComponent(".agents/.skill-lock.json"))
        let service = try await service()
        let originalA = try Data(contentsOf: recorded.appendingPathComponent("SKILL.md"))
        let originalB = try Data(contentsOf: local.appendingPathComponent("SKILL.md"))
        do {
            try await service.importUnmanagedSkill(UnmanagedSkill(name: "review", agent: .claude, directoryPath: local.path))
            XCTFail("本地 B 不能按目录名继承仓库 A 的更新来源")
        } catch { XCTAssertTrue(error.localizedDescription.contains("来源不一致")) }
        XCTAssertEqual(try Data(contentsOf: recorded.appendingPathComponent("SKILL.md")), originalA)
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("SKILL.md")), originalB)
        let installed = try await service.loadInstalledSkills()
        XCTAssertTrue(installed.isEmpty)
        // 冲突不破坏真正来源，用户随后纳管共享目录中的 A 仍可保留准确更新元数据。
        try await service.importUnmanagedSkill(UnmanagedSkill(name: "review", agent: .codex, directoryPath: recorded.path))
        let imported = try await service.loadInstalledSkills()
        XCTAssertEqual(imported[0].repoName, "repository-a")
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("SKILL.md")), originalB)
    }

    func testFailedUpdatePreservesCompleteOldDirectoryAndReportsFailure() async throws {
        let fixture = try networkFixture(failScript: false)
        try await fixture.service.prepareStorage()
        let discovered = try await fixture.service.discoverSkills(repo: fixture.repo)
        try await fixture.service.installSkill(skill: discovered[0], targetAgents: [.claude])
        let old = try await fixture.service.loadInstalledSkills()
        let base = home.appendingPathComponent(".quotio/skills/review")
        let beforeScript = try Data(contentsOf: base.appendingPathComponent("scripts/check.sh"))
        let beforeReference = try Data(contentsOf: base.appendingPathComponent("references/guide.md"))
        let raw = "https://raw.githubusercontent.com/\(fixture.repo.owner)/\(fixture.repo.name)/" + String(repeating: "f", count: 40)
        WorkspaceSkillFixtureProtocol.store.set(raw + "/skills/productivity/review/scripts/check.sh", status: 503, data: Data())
        let report = await fixture.service.updateAllSkillsReport()
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("scripts/check.sh")), beforeScript)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("references/guide.md")), beforeReference)
        let after = try await fixture.service.loadInstalledSkills()
        XCTAssertEqual(after[0].updatedAt, old[0].updatedAt)
        XCTAssertEqual(after[0].enabledAgents, [.claude])
    }

    func testExportReplacesExistingArchiveOnlyAfterSuccessfulZip() async throws {
        let service = try await service()
        let destination = home.appendingPathComponent("backup.zip")
        let previous = Data("preserve until success".utf8)
        try previous.write(to: destination)
        do { try await service.exportSkillsArchive(to: destination); XCTFail("空库导出应失败") } catch { }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        _ = try writeSkill(".quotio/skills/review")
        try await service.exportSkillsArchive(to: destination)
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4b])
    }

    private func networkFixture(failScript: Bool) throws -> (service: WorkspaceSkillService, repo: SkillRepo) {
        let repo = SkillRepo(owner: "fixture-" + UUID().uuidString.lowercased(), name: "skills")
        let prefix = "https://api.github.com/repos/\(repo.owner)/\(repo.name)"
        let revision = String(repeating: "f", count: 40)
        let raw = "https://raw.githubusercontent.com/\(repo.owner)/\(repo.name)/" + revision
        WorkspaceSkillFixtureProtocol.store.set(prefix + "/commits/main", status: 200, data: try JSONSerialization.data(withJSONObject: ["sha": revision]))
        let files = [
            ("SKILL.md", "100644", "---\nname: review\ndescription: complete fixture\n---\nUse scripts/check.sh"),
            ("scripts/check.sh", "100755", "#!/bin/sh\necho complete\n"),
            ("references/guide.md", "100644", "reference data")
        ]
        var tree: [[String: Any]] = []
        for (index, file) in files.enumerated() {
            let sha = String(repeating: String(index + 1), count: 40)
            tree.append(["path": "skills/productivity/review/" + file.0, "mode": file.1, "type": "blob", "sha": sha, "size": file.2.utf8.count])
            WorkspaceSkillFixtureProtocol.store.set(raw + "/skills/productivity/review/" + file.0, status: failScript && index == 1 ? 503 : 200, data: Data(file.2.utf8))
        }
        WorkspaceSkillFixtureProtocol.store.set(prefix + "/git/trees/" + revision + "?recursive=1", status: 200,
            data: try JSONSerialization.data(withJSONObject: ["tree": tree, "truncated": false]))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceSkillFixtureProtocol.self]
        return (WorkspaceSkillService(homeDir: home.path, session: URLSession(configuration: config)), repo)
    }
}

nonisolated private final class WorkspaceSkillFixtureProtocol: URLProtocol, @unchecked Sendable {
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: (Int, Data)] = [:]
        func set(_ url: String, status: Int, data: Data) { lock.lock(); defer { lock.unlock() }; routes[url] = (status, data) }
        func get(_ url: String) -> (Int, Data)? { lock.lock(); defer { lock.unlock() }; return routes[url] }
    }
    static let store = Store()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (status, data) = Self.store.get(url.absoluteString),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
