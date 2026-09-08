import Foundation

/// 仪表盘目录的单次读取事务：服务已运行不等于共享 ViewModel 的 API key 缓存已加载。
/// 先等待本次管理接口返回凭据，再读取模型，避免首次启动抢跑或继承配置页/隧道的临时配置。
nonisolated struct DashboardModelCatalogLoader: Sendable {
    let fetchAPIKeys: @Sendable () async throws -> [String]
    let fetchModels: @Sendable (String) async throws -> [ModelCatalogEntry]

    func load() async throws -> [ModelCatalogEntry] {
        try Task.checkCancellation()
        let keys = try await fetchAPIKeys()
        // 即使底层管理请求不响应取消，停止/切换会话后也不能继续发出旧模型请求。
        try Task.checkCancellation()
        // 管理密钥与客户端密钥职责不同，不能互相回退；未配置客户端密钥时使用空认证值。
        let entries = try await fetchModels(keys.first ?? "")
        try Task.checkCancellation()
        return entries
    }

    /// 调用方冻结当前会话的 loopback 地址和管理密钥；整个事务不读取用户配置页或共享 key 缓存。
    static func local(baseURL: String, managementKey: String) -> Self {
        let modelService = AgentConfigurationService()
        return Self(
            fetchAPIKeys: {
                let client = ManagementAPIClient(baseURL: baseURL + "/v0/management", authKey: managementKey)
                do {
                    let keys = try await client.fetchAPIKeys()
                    await client.invalidate()
                    return keys
                } catch {
                    await client.invalidate()
                    throw error
                }
            },
            fetchModels: { apiKey in
                let configuration = AgentConfiguration(agent: .claudeCode, proxyURL: baseURL + "/v1", apiKey: apiKey)
                return try await modelService.fetchModelCatalog(config: configuration)
            }
        )
    }
}
