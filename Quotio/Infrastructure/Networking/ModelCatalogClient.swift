import Foundation

/// 模型目录和连接探测实际共用的只读传输能力，输入为明确端点与客户端密钥。
/// 仅构造并发送原 /models 请求，保留 Bearer、十秒超时和现有代理配置；不读配置页、不写文件。
/// 返回原始响应，不在底层解析、筛选、缓存、补模型或按状态码重试，业务语义由调用方决定。
nonisolated enum ModelCatalogClient {
    static func modelsURL(baseURL: String) -> URL? {
        URL(string: "\(baseURL)/models")
    }

    /// 测试可传入离线 URLSession；正常调用仍使用原代理工厂逐次构造会话。
    /// 会话不保存为全局或服务状态，外部传入的会话也不会被此方法取消或关闭。
    @concurrent
    static func fetch(url: URL, apiKey: String, session: URLSession? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let activeSession = session ?? URLSession(configuration:
            ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10))
        return try await activeSession.data(for: request)
    }
}
