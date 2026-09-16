import Foundation

extension SkillRepo {
    /// 仓库按钮统一打开 GitHub 仓库首页，不使用可能指向原始文件或旧分支的 readmeURL。
    /// 来源字段来自持久化元数据，沿用仓库下载入口的字符约束，避免损坏字段拼成错误链接。
    nonisolated var repositoryURL: URL? {
        for component in [owner, name] {
            guard component.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                  component != ".", component != ".." else { return nil }
        }
        return URL(string: "https://github.com/\(owner)/\(name)")
    }
}

/// 已纳管技能按仓库归组，技能本身的目录、分支、启用状态及卸载身份保持独立。
/// 分组只依据已保存的来源字段，不从技能名称或目录名猜测仓库；缺少来源的技能归入本地组。
nonisolated struct WorkspaceSkillRepositoryGroup: Identifiable, Sendable {
    let id: String
    let repository: SkillRepo?
    let skills: [WorkspaceSkill]
    let totalCount: Int

    var title: String { repository?.id ?? "本地 / 来源未记录" }

    static func groups(in skills: [WorkspaceSkill], matching searchText: String) -> [Self] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        var repositories: [String: SkillRepo] = [:]
        var members: [String: [WorkspaceSkill]] = [:]
        for skill in skills {
            let repository = sourceRepository(for: skill)
            // 同一 GitHub 仓库的大小写写法共享稳定身份；不同 owner 下的同名仓库不能合并。
            let key = repository.map { "github:\($0.id.lowercased())" } ?? "local"
            if let repository, repositories[key] == nil { repositories[key] = repository }
            members[key, default: []].append(skill)
        }

        return members.compactMap { key, items -> Self? in
            let repository = repositories[key]
            let repositoryMatches = repository?.id.localizedLowercase.contains(query) == true
            let visible = items.filter { skill in
                query.isEmpty || repositoryMatches || skill.name.localizedLowercase.contains(query) ||
                    skill.description.localizedLowercase.contains(query) || skill.directory.localizedLowercase.contains(query)
            }.sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return comparison == .orderedSame ? lhs.directory < rhs.directory : comparison == .orderedAscending
            }
            guard !visible.isEmpty else { return nil }
            return Self(id: key, repository: repository, skills: visible, totalCount: items.count)
        }.sorted { lhs, rhs in
            // 仓库按名称排序，本地来源放在最后；增删技能不会改变其余仓库的折叠身份。
            if (lhs.repository == nil) != (rhs.repository == nil) { return lhs.repository != nil }
            return lhs.id < rhs.id
        }
    }

    private static func sourceRepository(for skill: WorkspaceSkill) -> SkillRepo? {
        WorkspaceSkillRepositorySource.repository(
            owner: skill.repoOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
            name: skill.repoName?.trimmingCharacters(in: .whitespacesAndNewlines), sourceURL: skill.readmeURL)
    }
}
