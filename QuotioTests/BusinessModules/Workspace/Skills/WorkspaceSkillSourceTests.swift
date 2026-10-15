import Foundation
import XCTest
@testable import QuotioPlus

/// 使用真实临时文件、客户端链接和 SQLite，验证后装技能能归组，同时避免同名误认和读取写库。
final class WorkspaceSkillSourceTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("QuotioSkillSource-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    private func installFixture(sharedLink: Bool = true) throws {
        let managed = home.appendingPathComponent(".quotio/skills/review")
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("---\nname: review\ndescription: fixture\n---\n正文".utf8).write(to: managed.appendingPathComponent("SKILL.md"))
        if sharedLink {
            let shared = home.appendingPathComponent(".agents/skills/review")
            try fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: shared, withDestinationURL: managed)
        }
    }

    private func writeReceipt(source: String = "Dimillian/Skills", type: String = "github", path: String = "skills/review/SKILL.md",
                              to destination: URL? = nil) throws -> URL {
        let url = destination ?? home.appendingPathComponent(".agents/.skill-lock.json")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // ref、两种 ISO 时间以及 skillFolderHash 都使用 skills CLI 官方记录字段。
        let receipt: [String: Any] = ["version": 3, "skills": ["review": [
            "source": source, "sourceType": type, "ref": "release/next", "skillPath": path,
            "installedAt": "2026-08-08T03:49:22Z", "updatedAt": "2026-08-09T03:49:22.152Z",
            "skillFolderHash": String(repeating: "a", count: 40)
        ]]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: url)
        return url
    }

    private func database() throws -> WorkspaceSkillDatabase {
        try WorkspaceSkillDatabase(path: home.appendingPathComponent(".quotio/quotio.db").path)
    }

    func testReceiptInstalledAfterPreparationIsReadWithoutPersistingOrChangingRepos() async throws {
        let service = WorkspaceSkillService(homeDir: home.path)
        try await service.prepareStorage()
        try await service.saveRepos([])
        try installFixture()
        let before = try await service.loadInstalledSkills()
        XCTAssertNil(before.first?.repoOwner)
        let lock = try writeReceipt()
        let lockData = try Data(contentsOf: lock)
        let installed = try await service.loadInstalledSkills()
        let skill = try XCTUnwrap(installed.first)
        XCTAssertEqual(skill.repoOwner, "Dimillian")
        XCTAssertEqual(skill.repoName, "Skills")
        XCTAssertEqual(skill.repoBranch, "release/next")
        XCTAssertEqual(skill.repositoryRelativePath, "skills/review")
        XCTAssertEqual(skill.readmeURL, "https://github.com/Dimillian/Skills")
        XCTAssertEqual(skill.installedAt, ISO8601DateFormatter().date(from: "2026-08-08T03:49:22Z"))
        XCTAssertNil(skill.contentHash, "Git tree SHA 不能冒充 Quotio 目录哈希")
        XCTAssertTrue(try database().rows("SELECT * FROM skills_metadata").isEmpty)
        let repos = try await service.loadRepos()
        XCTAssertTrue(repos.isEmpty, "读取来源不能复活用户已移除的发现仓库")
        XCTAssertEqual(try Data(contentsOf: lock), lockData)
    }

    func testExternalReceiptCannotReplaceSavedRepositoryOrBranch() async throws {
        let service = WorkspaceSkillService(homeDir: home.path)
        try await service.prepareStorage()
        try installFixture()
        let db = try database()
        try db.execute("INSERT INTO skills_metadata(directory,repo_owner,repo_name,repo_branch,installed_at,updated_at,content_hash) VALUES ('review','original','skills','stable',123456,234567,'saved-hash')")
        _ = try writeReceipt()
        let original = try await service.loadInstalledSkills()
        XCTAssertEqual(original.first?.repoOwner, "original")
        XCTAssertNil(original.first?.repositoryRelativePath)
        _ = try writeReceipt(source: "ORIGINAL/Skills")
        let differentBranch = try await service.loadInstalledSkills()
        XCTAssertNil(differentBranch.first?.repositoryRelativePath, "不能把其它分支的路径用于 stable 下载")
        XCTAssertEqual(differentBranch.first?.repoBranch, "stable")
        try db.execute("UPDATE skills_metadata SET repo_branch='release/next' WHERE directory='review'")
        let sameBranch = try await service.loadInstalledSkills()
        XCTAssertEqual(sameBranch.first?.repositoryRelativePath, "skills/review")
        XCTAssertEqual(sameBranch.first?.contentHash, "saved-hash")
        XCTAssertNil(try db.rows("SELECT repository_path FROM skills_metadata").first?["repository_path"])
    }

    func testSameNameIndependentManagedSkillDoesNotInheritReceipt() async throws {
        let service = WorkspaceSkillService(homeDir: home.path)
        try await service.prepareStorage()
        try installFixture(sharedLink: false)
        _ = try writeReceipt()
        let shared = home.appendingPathComponent(".agents/skills/review")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("其它仓库的同名技能".utf8).write(to: shared.appendingPathComponent("SKILL.md"))
        let installed = try await service.loadInstalledSkills()
        XCTAssertNil(installed.first?.repoOwner)
        XCTAssertTrue(try database().rows("SELECT * FROM skills_metadata").isEmpty)
    }

    func testIncompleteSavedSourceCannotBeReassignedByExternalReceipt() async throws {
        let service = WorkspaceSkillService(homeDir: home.path)
        try await service.prepareStorage()
        try installFixture()
        _ = try writeReceipt()
        let db = try database()
        try db.execute("INSERT INTO skills_metadata(directory,repo_owner) VALUES ('review','original')")
        let partial = try await service.loadInstalledSkills()
        XCTAssertEqual(partial.first?.repoOwner, "original")
        XCTAssertNil(partial.first?.repoName)
        try db.execute("UPDATE skills_metadata SET repo_owner=NULL,readme_url='https://example.invalid/original/source' WHERE directory='review'")
        let unsupported = try await service.loadInstalledSkills()
        XCTAssertNil(unsupported.first?.repoOwner)
        XCTAssertEqual(unsupported.first?.readmeURL, "https://example.invalid/original/source")
    }

    func testInvalidAndNonGitHubReceiptsDoNotPreventLocalBrowsing() async throws {
        let service = WorkspaceSkillService(homeDir: home.path)
        try await service.prepareStorage()
        try installFixture()
        for (type, path) in [("local", "skills/review/SKILL.md"), ("github", "../review/SKILL.md")] {
            _ = try writeReceipt(type: type, path: path)
            let installed = try await service.loadInstalledSkills()
            XCTAssertEqual(installed.count, 1)
            XCTAssertNil(installed.first?.repoOwner)
        }
        try Data("invalid JSON".utf8).write(to: home.appendingPathComponent(".agents/.skill-lock.json"))
        let installed = try await service.loadInstalledSkills()
        XCTAssertEqual(installed.count, 1)
        XCTAssertNil(installed.first?.repoOwner)
    }

    func testExplicitStateDirectoryReceiptIsUsedInsteadOfLegacyLocation() async throws {
        let lock = home.appendingPathComponent("state/skills/.skill-lock.json")
        let service = WorkspaceSkillService(homeDir: home.path, skillLockPath: lock.path)
        try await service.prepareStorage()
        try installFixture()
        _ = try writeReceipt(source: "wrong/repo")
        _ = try writeReceipt(to: lock)
        let installed = try await service.loadInstalledSkills()
        XCTAssertEqual(installed.first?.repoOwner, "Dimillian")
    }
}
