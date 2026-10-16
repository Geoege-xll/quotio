import Foundation

/// 模型目录和连接探测实际共用的只读传输能力，输入为明确端点与客户端密钥。
/// 仅构造并发送原 /models 请求，保留 Bearer、十秒超时和现有代理配置；不读配置页、不写文件。
/// CPA 的 v8 是 /v8/management 管理协议版本；这里的 /v1/models 属于客户端兼容协议，
/// 与 Codex／OpenCode 的 /v1 基址一致，不能机械改成 /v8/models，也不能发送管理密钥。
/// 返回原始响应，不在底层解析、筛选、缓存、补模型或按状态码重试，业务语义由调用方决定。
nonisolated enum ModelCatalogClient {
    static func modelsURL(baseURL: String) -> URL? {
        // 路径级拼接兼容末尾斜杠，避免 /v1//models 导致首次读取与每次重试都失败；
        // 只修改 path，保留服务主机、部署前缀和查询参数，不把 /models 拼到 query／fragment 内。
        guard var endpoint = URLComponents(string: baseURL) else { return nil }
        var path = endpoint.path
        while path.hasSuffix("/") { path.removeLast() }
        endpoint.path = path + "/models"
        endpoint.fragment = nil
        return endpoint.url
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
