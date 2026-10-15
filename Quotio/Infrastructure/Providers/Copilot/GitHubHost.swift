import Foundation

/// Copilot 的 GitHub 路由契约，授权、凭据身份和额度请求共同使用。
/// 仅接受 GitHub.com 或单层企业 slug.ghe.com；自建 Enterprise Server 需要独立 OAuth App，
/// 因此不能把任意地址当成兼容企业站点，更不能在解析失败后把令牌回退发给公共站点。
nonisolated struct GitHubHost: Hashable, Sendable {
    static let githubCom = GitHubHost(value: "github.com")
    let value: String
    private init(value: String) { self.value = value }

    /// UI 可粘贴 HTTPS 首页；端口、路径、用户信息、查询、非 ASCII 和嵌套子域均拒绝。
    init?(_ raw: String) {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("https://") { host.removeFirst(8) }
        if host.hasSuffix("/") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253, host.allSatisfy(\.isASCII) else { return nil }
        if host == "github.com" { self = .githubCom; return }
        guard host.hasSuffix(".ghe.com") else { return nil }
        let slug = host.dropLast(8)
        guard !slug.isEmpty, slug.count <= 63, slug.first != "-", slug.last != "-",
              slug.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        self.init(value: host)
    }

    var isGitHubCom: Bool { self == .githubCom }
    func webURL(_ path: String) -> URL { URL(string: "https://\(value)\(path)")! }
    func apiURL(_ path: String) -> URL { URL(string: "https://api.\(value)\(path)")! }
    var modelsURL: URL {
        URL(string: isGitHubCom ? "https://api.githubcopilot.com/models" : "https://copilot-api.\(value)/models")!
    }

    /// 公共站点保持全部旧账号键；企业同名用户按主机隔离，避免覆盖个人账号或另一企业账号。
    func accountKey(_ login: String) -> String { isGitHubCom ? login : "\(login)@\(value)" }

    /// 无用户名的原生凭据占位也按主机隔离；调用方只在同一合法主机已有真实账号时隐藏它。
    /// 公共占位保留原键，企业占位不因另一企业或个人账号出现就被清除。
    static func placeholderHost(accountKey: String) -> GitHubHost? {
        let key = accountKey.lowercased()
        if key == "github copilot" { return .githubCom }
        let prefix = "github copilot@"
        guard key.hasPrefix(prefix) else { return nil }
        return GitHubHost(String(key.dropFirst(prefix.count)))
    }

    static func accountHost(accountKey: String) -> GitHubHost? {
        guard let separator = accountKey.lastIndex(of: "@") else { return .githubCom }
        return GitHubHost(String(accountKey[accountKey.index(after: separator)...]))
    }

    /// 只有字段缺失才表示旧版 GitHub.com 凭据；空值、非法值及冲突元数据都不能悄悄回退。
    static func saved(_ primary: String?, alternate: String? = nil) -> GitHubHost? {
        guard primary != nil || alternate != nil else { return .githubCom }
        if let primary, let alternate {
            guard let first = GitHubHost(primary), first == GitHubHost(alternate) else { return nil }
            return first
        }
        return GitHubHost(primary ?? alternate ?? "")
    }
}

/// GitHub 携带 token／device_code 的请求不跟随重定向，防止 307/308 转发认证正文到其他来源。
/// 使用原注入的会话及代理配置，只给当前请求提供无状态 delegate，不增加网络单例或缓存。
nonisolated enum GitHubHTTP {
    static func data(for request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        try await session.data(for: request, delegate: NoRedirect())
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
