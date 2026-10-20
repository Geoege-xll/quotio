import Foundation

/// 连接来源只描述已保存的服务，不通过是否含 localhost 决定用户是否要撤下代理配置。
/// 隧道、局域网及远程 CPA 都是有效代理来源；只有明确的 Anthropic 官方主机属于官方端点。
nonisolated enum ClaudeConfigurationSource {
    static func isProxyEndpoint(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        // 无法识别的旧地址不能被误判为“恢复官方”并触发清理，保留代理模式交给连接校验处理。
        guard let host = URLComponents(string: value)?.host else { return true }
        return host.lowercased() != "api.anthropic.com"
    }

    /// settings.json 的 Messages 基址与模型目录的 /v1 基址是同一服务的两种协议入口。
    /// 只处理末尾版本段，保留部署前缀、主机和查询参数，不全局替换字符串。
    static func modelAPIBaseURL(_ storedBaseURL: String) -> String {
        guard var parts = URLComponents(string: storedBaseURL) else { return storedBaseURL }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if !parts.path.hasSuffix("/v1") { parts.path += "/v1" }
        return parts.url?.absoluteString ?? storedBaseURL
    }
}
