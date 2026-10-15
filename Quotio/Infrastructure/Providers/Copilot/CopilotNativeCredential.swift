import Foundation
import Yams

/// 原生 Copilot／gh 凭据与其主机必须成对读取；令牌不能脱离来源域名再统一发送到 github.com。
nonisolated struct CopilotNativeCredential: Sendable {
    let host: GitHubHost
    let token: String
    let username: String?
    let path: String
}

extension CopilotQuotaFetcher {
    /// 路径保持调用者的原始 Unicode 拼写，不套用 Claude 的 NFC 或标准路径处理。
    /// 不读环境变量来决定 token 目的地；仅接受文件中的受支持主机键或显式主机元数据。
    nonisolated static func nativeCredentials(paths: [String]) -> [CopilotNativeCredential] {
        var result: [CopilotNativeCredential] = []
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let object: Any?
            if path.hasSuffix(".yml") || path.hasSuffix(".yaml") {
                object = String(data: data, encoding: .utf8).flatMap { try? Yams.load(yaml: $0) }
            } else { object = try? JSONSerialization.jsonObject(with: data) }
            if path.hasSuffix(".yml") || path.hasSuffix(".yaml") {
                // gh 的顶层一律是主机映射；名为 tokens／hosts 的单标签 GHES 也不能冒充 JSON 包装层。
                if let hosts = object as? [String: Any] {
                    for (name, value) in hosts {
                        guard let host = GitHubHost(name) else { continue }
                        collectNativeCredentials(value, host: host, path: path, into: &result)
                    }
                }
            } else if let object { collectNativeCredentials(object, host: nil, path: path, into: &result) }
        }
        // 同一原生令牌可能同时在 apps.json 与 hosts.yml 出现；同 token 的不同主机仍是不同来源。
        var seen = Set<String>()
        return result.filter { seen.insert($0.host.value + "\u{0}" + $0.token).inserted }
    }

    nonisolated private static func collectNativeCredentials(_ value: Any, host inherited: GitHubHost?, path: String,
                                                            into result: inout [CopilotNativeCredential]) {
        if let dictionary = value as? [String: Any] {
            let context: GitHubHost?
            if dictionary["host"] != nil || dictionary["github_host"] != nil {
                guard (dictionary["host"] == nil || dictionary["host"] is String),
                      (dictionary["github_host"] == nil || dictionary["github_host"] is String),
                      let selected = GitHubHost.saved(dictionary["host"] as? String, alternate: dictionary["github_host"] as? String),
                      inherited == nil || inherited == selected else { return }
                context = selected
            } else { context = inherited }
            // 未限定主机的兼容叶子才使用旧 github.com；普通包装层不提前绑定公共主机。
            let host = context ?? .githubCom
            let token = ["oauth_token", "oauthToken", "access_token"].compactMap { dictionary[$0] as? String }
                .first { !$0.isEmpty }
            if let token {
                let username = ["user", "username", "login"].compactMap { dictionary[$0] as? String }
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                result.append(CopilotNativeCredential(host: host, token: token, username: username, path: path))
            }
            for (key, child) in dictionary where child is [String: Any] || child is [Any] {
                // apps.json 常用 github.com:OAuthClientID；gh 的顶层键是主机名。
                let candidate = String(key.split(separator: ":", maxSplits: 1).first ?? "")
                if let selected = GitHubHost(candidate) {
                    guard context == nil || context == selected else { continue }
                    collectNativeCredentials(child, host: selected, path: path, into: &result)
                } else if key == "users", let context, let users = child as? [String: Any] {
                    // gh 多账号格式：已校验主机下的 users.<login>.oauth_token。
                    // 登录名取映射键，复用同一主机与 token 解析；仅识别这个明确容器，
                    // 不恢复任意递归，避免未知企业主机中的令牌被误当成公共账号。
                    for (login, value) in users {
                        guard !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              var user = value as? [String: Any] else { continue }
                        user["user"] = login
                        collectNativeCredentials(user, host: context, path: path, into: &result)
                    }
                } else if ["accounts", "apps", "hosts", "tokens"].contains(key) {
                    // 只识别已知包装层。localhost／corp-github 也是未支持的主机，
                    // 不能因为没有点号就当作普通容器，将其令牌降级发送给公共站点。
                    collectNativeCredentials(child, host: context, path: path, into: &result)
                }
                // 未识别的域名节点整体跳过，不能把其 token 降级成 GitHub.com 凭据。
            }
        } else if let array = value as? [Any] {
            for child in array { collectNativeCredentials(child, host: inherited, path: path, into: &result) }
        }
    }
}
