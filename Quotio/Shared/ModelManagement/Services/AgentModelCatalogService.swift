import Foundation

/// 仪表盘、配置页和 Pi 配置提交共用的模型读取业务，不持有配置写入服务、页面状态或后台任务。
/// 实时目录、候选筛选和连接探测共用传输，但各自保留原成功条件、解析、错误和兜底边界。
/// @concurrent 保持读取及解析在通用执行器执行；原 ViewModel／配置 actor 继续负责提交、取消和状态校验。
nonisolated enum AgentModelCatalogService {
    /// 同一次后端读取的两种投影：注册目录证明请求身份，候选保留原 Copilot 可用性筛选。
    /// 后端是否支持完整 ID 不能由本机某个账号的可用模型集合推断；此值不持有任务或缓存。
    struct Selection: Sendable {
        let catalog: [AvailableModel]
        let candidates: [AvailableModel]
    }
    /// 只接受原 HTTP 200 及合法目录正文；空列表如实返回，错误如实抛出，不读取候选静态兜底。
    @concurrent
    static func fetchModelCatalog(proxyURL: String, apiKey: String, session: URLSession? = nil) async throws -> [ModelCatalogEntry] {
        guard let url = ModelCatalogClient.modelsURL(baseURL: proxyURL) else { throw URLError(.badURL) }
        let (data, response) = try await ModelCatalogClient.fetch(url: url, apiKey: apiKey, session: session)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try ModelCatalog.parse(data)
    }

    /// 候选映射后仍逐次查询 Copilot 可用模型：没有可用性证据时保留原候选，不能把账号缺失当作全部禁用。
    /// 离线回归仅注入本次查询闭包和会话，不把可用模型、密钥或请求句柄保存到新的状态宿主。
    @concurrent
    static func fetchAvailableModels(
        proxyURL: String, apiKey: String, session: URLSession? = nil,
        fetchCopilotModelIDs: @Sendable () async -> Set<String> = {
            await CopilotQuotaFetcher().fetchUserAvailableModelIds()
        }
    ) async throws -> [AvailableModel] {
        try await fetchModelSelection(proxyURL: proxyURL, apiKey: apiKey, session: session,
                                      fetchCopilotModelIDs: fetchCopilotModelIDs).candidates
    }

    @concurrent
    static func fetchModelSelection(
        proxyURL: String, apiKey: String, session: URLSession? = nil,
        fetchCopilotModelIDs: @Sendable () async -> Set<String> = {
            await CopilotQuotaFetcher().fetchUserAvailableModelIds()
        }
    ) async throws -> Selection {
        let parsedModels = ModelCatalog.agentSetupModels(from:
            try await fetchModelCatalog(proxyURL: proxyURL, apiKey: apiKey, session: session))
        let availableCopilotModelIds = await fetchCopilotModelIDs()
        let candidates = parsedModels.filter { model in
            if model.provider == "github-copilot", !availableCopilotModelIds.isEmpty {
                return availableCopilotModelIds.contains(model.id)
            }
            return true
        }
        return Selection(catalog: parsedModels, candidates: candidates)
    }

    /// 连接探测保留原宽松正文语义：HTTP 200 即可成功，目录不可解析时仅不填 modelResponded。
    /// 非 200 保留上游 message，传输失败保留本地化错误和 nil 延迟，不借严格目录解析改变用户反馈。
    @concurrent
    static func testConnection(proxyURL: String, apiKey: String, session: URLSession? = nil) async -> ConnectionTestResult {
        let startTime = Date()
        
        guard let url = ModelCatalogClient.modelsURL(baseURL: proxyURL) else {
            return ConnectionTestResult(
                success: false,
                message: "Invalid proxy URL",
                latencyMs: nil,
                modelResponded: nil
            )
        }
        
        do {
            let (data, response) = try await ModelCatalogClient.fetch(url: url, apiKey: apiKey, session: session)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                return ConnectionTestResult(
                    success: false,
                    message: "Invalid response",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]],
                   let firstModel = models.first?["id"] as? String {
                    return ConnectionTestResult(
                        success: true,
                        message: "Connected successfully",
                        latencyMs: latencyMs,
                        modelResponded: firstModel
                    )
                }
                return ConnectionTestResult(
                    success: true,
                    message: "Connected successfully",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            } else {
                var errorMessage = "HTTP \(httpResponse.statusCode)"
                
                // Try to parse detailed error message from proxy response (OpenAI format)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any],
                   let detailedMessage = errorObj["message"] as? String {
                    errorMessage = detailedMessage
                }
                
                return ConnectionTestResult(
                    success: false,
                    message: errorMessage,
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }
        } catch {
            return ConnectionTestResult(
                success: false,
                message: error.localizedDescription,
                latencyMs: nil,
                modelResponded: nil
            )
        }
    }
}
