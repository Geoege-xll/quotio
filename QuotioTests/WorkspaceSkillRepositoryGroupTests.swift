import XCTest
@testable import QuotioPlus

/// 来源归组只改变展示，必须保留不同目录、分支和挂载状态，不能把同仓库技能去重为一个技能。
final class WorkspaceSkillRepositoryGroupTests: XCTestCase {
    func testRepositoryGroupingKeepsEachSkillAndSeparatesDifferentOwners() throws {
        let first = WorkspaceSkill(name: "检查", description: "", directory: "review", repoOwner: "team", repoName: "skills",
                                   repoBranch: "main", enabledAgents: [.claude], repositoryRelativePath: "development/review")
        let second = WorkspaceSkill(name: "部署", description: "", directory: "deploy", repoOwner: "TEAM", repoName: "skills",
                                    repoBranch: "next", enabledAgents: [.codex], repositoryRelativePath: "release/deploy")
        let other = WorkspaceSkill(name: "另一来源", description: "", directory: "other", repoOwner: "another", repoName: "skills")
        let groups = WorkspaceSkillRepositoryGroup.groups(in: [first, second, other], matching: "")
        XCTAssertEqual(groups.count, 2)
        let group = try XCTUnwrap(groups.first { $0.id == "github:team/skills" })
        XCTAssertEqual(group.totalCount, 2)
        XCTAssertEqual(Set(group.skills.map(\.directory)), ["review", "deploy"])
        XCTAssertEqual(group.skills.first { $0.directory == "deploy" }?.repoBranch, "next")
        XCTAssertEqual(group.skills.first { $0.directory == "review" }?.enabledAgents, [.claude])
        let filtered = WorkspaceSkillRepositoryGroup.groups(in: [first, second, other], matching: "部署")
        XCTAssertEqual(filtered.first?.id, group.id, "搜索或数量变化不能重置仓库身份与折叠状态")
        XCTAssertEqual(filtered.first?.skills.count, 1)
        XCTAssertEqual(filtered.first?.totalCount, 2)
        XCTAssertEqual(WorkspaceSkillRepositoryGroup.groups(in: [first, second, other], matching: "TEAM/skills").first?.skills.count, 2)
    }

    func testLocalAndIncompleteSourcesRemainVisibleWithoutInventingRepository() throws {
        let local = WorkspaceSkill(name: "本地技能", description: "说明", directory: "local")
        let incomplete = WorkspaceSkill(name: "仅作者", description: "", directory: "partial", repoOwner: "team")
        let malformed = WorkspaceSkill(name: "旧元数据", description: "", directory: "legacy", repoOwner: "../team", repoName: "skills")
        let groups = WorkspaceSkillRepositoryGroup.groups(in: [local, incomplete, malformed], matching: "  ")
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertNil(group.repository)
        XCTAssertEqual(group.totalCount, 3)
        XCTAssertEqual(Set(group.skills.map(\.directory)), ["local", "partial", "legacy"])
        XCTAssertTrue(WorkspaceSkillRepositoryGroup.groups(in: [local], matching: "不存在").isEmpty)
    }

    func testAddressOpensRepositoryRootAndRejectsInvalidComponents() {
        let repository = SkillRepo(owner: "team-name", name: "agent.skills", branch: "feature/new")
        XCTAssertEqual(repository.repositoryURL?.absoluteString, "https://github.com/team-name/agent.skills")
        for invalid in ["", ".", "..", "owner/repo", "team?tab=1", "https://example.com"] {
            XCTAssertNil(SkillRepo(owner: invalid, name: "skills").repositoryURL)
            XCTAssertNil(SkillRepo(owner: "team", name: invalid).repositoryURL)
        }
    }

    func testGitHubAndSkillsDirectoryURLsShareOneRepositoryIdentity() throws {
        let sources = ["Dimillian/Skills", "https://github.com/Dimillian/Skills.git",
                       "git@github.com:Dimillian/Skills.git", "ssh://git@github.com/Dimillian/Skills.git",
                       "https://github.com/Dimillian/Skills/tree/main/swiftui-ui-patterns",
                       "https://skills.sh/dimillian/skills/swiftui-ui-patterns"]
        let skills = sources.enumerated().map { index, source in
            WorkspaceSkill(name: "技能 \(index)", description: "", directory: "skill-\(index)", readmeURL: source)
        }
        let groups = WorkspaceSkillRepositoryGroup.groups(in: skills, matching: "")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "github:dimillian/skills")
        XCTAssertEqual(groups.first?.totalCount, sources.count)
        XCTAssertEqual(groups.first?.repository?.repositoryURL?.absoluteString, "https://github.com/Dimillian/Skills")
        for source in ["https://skills.sh", "https://example.com/team/skills", "file:///team/skills", "/team/skills",
                       "team/skills/extra", "https://user:password@github.com/team/skills", "https://github.com/team/.."] {
            XCTAssertNil(WorkspaceSkillRepositorySource.parse(source), source)
        }
    }
}
