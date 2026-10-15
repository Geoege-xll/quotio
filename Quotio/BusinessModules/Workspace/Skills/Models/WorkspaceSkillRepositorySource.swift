import Foundation

/// GitHub 直装与 skills.sh 安装共享同一仓库身份；技能页面、分支路径和 .git 后缀不产生新分组。
/// 只解析明确的来源字段，不从技能名称、说明文字或功能分类推断仓库。
nonisolated enum WorkspaceSkillRepositorySource {
    static func repository(owner: String?, name: String?, sourceURL: String?) -> SkillRepo? {
        if let owner, let name, let repository = parse("\(owner)/\(name)") { return repository }
        return sourceURL.flatMap(parse)
    }

    static func parse(_ source: String) -> SkillRepo? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else if value.contains("://") {
            guard let url = URLComponents(string: value), let host = url.host?.lowercased(),
                  url.password == nil, url.port == nil else { return nil }
            switch host {
            case "github.com", "www.github.com":
                guard (url.scheme == "https" && url.user == nil) || (url.scheme == "ssh" && url.user == "git") else { return nil }
            case "skills.sh", "www.skills.sh":
                guard url.scheme == "https", url.user == nil else { return nil }
            default: return nil
            }
            path = url.path
        } else {
            // 裸地址只接受 owner/repo，不能把本地路径或不明服务的标识当成 GitHub 仓库。
            guard !value.hasPrefix("/"), value.split(separator: "/", omittingEmptySubsequences: false).count == 2 else { return nil }
            path = value
        }
        let components = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        let owner = String(components[0])
        var name = String(components[1])
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        let repository = SkillRepo(owner: owner, name: name)
        return repository.repositoryURL == nil ? nil : repository
    }
}
