//
//  ManagementAPIClient.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation

actor ManagementAPIClient {
    /// 全部管理请求统一使用 CPA 8 的根路径；模型业务请求的 /v1 与管理版本独立。
    /// 调用方只传服务地址来构造管理 URL，避免仪表盘、统计和账号页面各自留下旧前缀。
    nonisolated static let managementPath = "/v8/management"

    nonisolated static func managementURL(for serverURL: String) -> String {
        serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + managementPath
    }

    /// v8 配置读取必须声明 config-version=8；不能把端口上任意 200/HTML/旧 JSON 视为兼容服务。
    nonisolated static func isV8Configuration(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["config-version"] as? Int == 8
    }

    /// 管理密钥和模型客户端密钥都不能随 HTTP 重定向离开原服务。
    /// 按协议、主机及有效端口判断同源，HTTPS 降级或跳转到另一个本机端口也拒绝跟随。
    nonisolated static func allowsRedirect(from origin: URL?, to target: URL?) -> Bool {
        guard let origin, let target, let sourceHost = origin.host, let targetHost = target.host,
              let sourceScheme = origin.scheme?.lowercased(), let targetScheme = target.scheme?.lowercased(),
              ["http", "https"].contains(sourceScheme) else { return false }
        let sourcePort = origin.port ?? (sourceScheme == "https" ? 443 : 80)
        let targetPort = target.port ?? (targetScheme == "https" ? 443 : 80)
        return sourceScheme == targetScheme && sourceHost.lowercased() == targetHost.lowercased() && sourcePort == targetPort
    }
    private let baseURL: String
    private let authKey: String
    private let session: URLSession
    private let sessionDelegate: ManagementSessionDelegate
    private let clientId: String
    /// 停止代理后永久关闭当前客户端；新代理会创建新客户端，不能复用已失效的会话。
    private var isInvalidated = false
    /// 请求创建、登记和会话失效均由同一个 actor 串行管理，避免跨执行器创建任务时发生竞态。
    private var pendingTasks: [UUID: URLSessionDataTask] = [:]
    /// actor 在等待网络时可以重入；客户端密钥的读后替换必须拒绝同时编辑，避免互相覆盖。
    private var isEditingClientKeys = false
    
    /// Timeout configuration used for this client
    let timeoutConfig: TimeoutConfig
    
    // MARK: - Timeout Configuration
    
    /// Timeout settings for API requests
    struct TimeoutConfig: Sendable {
        let requestTimeout: TimeInterval
        let resourceTimeout: TimeInterval
        let maxRetries: Int

        /// Default timeouts for local connections (faster, more reliable)
        /// Increased maxRetries to handle proxy restart scenarios (graceful shutdown can take 1-2s)
        static let local = TimeoutConfig(
            requestTimeout: 15,
            resourceTimeout: 45,
            maxRetries: 4  // Was: 1. Now: 4 retries with exponential backoff = ~6.5s total wait
        )
    }
    
    // MARK: - Diagnostic Logging
    
    static let enableDiagnosticLogging = false
    nonisolated(unsafe) private static var activeRequests: Int = 0
    private static let requestLock = NSLock()
    
    private static func log(_ message: String) {
        guard enableDiagnosticLogging else { return }
        Log.api("\(message)")
    }
    
    private static func incrementActiveRequests() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        activeRequests += 1
        return activeRequests
    }
    
    private static func decrementActiveRequests() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        activeRequests -= 1
        return activeRequests
    }
    
    // MARK: - Initialization
    
    /// Initialize for local connection (localhost)
    init(baseURL: String, authKey: String, configuration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.authKey = authKey
        self.clientId = String(UUID().uuidString.prefix(6))
        self.timeoutConfig = .local
        
        // 复制配置以便隔离测试注入 URLProtocol，同时不修改调用方持有的配置对象。
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeoutConfig.requestTimeout
        config.timeoutIntervalForResource = timeoutConfig.resourceTimeout
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        self.sessionDelegate = ManagementSessionDelegate(clientId: clientId)
        self.session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        
        Self.log("[\(clientId)] Local client created, timeout=\(Int(timeoutConfig.requestTimeout))/\(Int(timeoutConfig.resourceTimeout))s")
    }
    
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        Self.log("[\(clientId)] Session invalidating...")
        session.invalidateAndCancel()
    }

    /// URLSession 在失效后创建任务会抛出 Objective-C 异常，Swift 的 do/catch 无法捕获。
    /// 因此在 actor 内同步检查状态并创建 dataTask；不能先检查、再跨执行器调用 data(for:)。
    /// 已创建的请求由 invalidateAndCancel 取消，调用方取消则只取消属于自己的请求。
    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let id = UUID()
        defer { pendingTasks[id] = nil }
        do {
            let result: (Data, URLResponse) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !isInvalidated, !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let task = session.dataTask(with: request) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, let response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: APIError.invalidResponse)
                        }
                    }
                    pendingTasks[id] = task
                    task.resume()
                }
            } onCancel: {
                Task { await self.cancelRequest(id) }
            }
            // 完成回调与停止操作可能同时到达；已停止会话的结果不能继续写回界面。
            try Task.checkCancellation()
            guard !isInvalidated else { throw CancellationError() }
            return result
        } catch {
            if isInvalidated || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func cancelRequest(_ id: UUID) {
        pendingTasks[id]?.cancel()
    }
    
    private func makeRequest(_ endpoint: String, method: String = "GET", body: Data? = nil, retryCount: Int = 0, contentType: String = "application/json") async throws -> Data {
        try Task.checkCancellation()
        guard !isInvalidated else { throw CancellationError() }
        let requestId = String(UUID().uuidString.prefix(6))
        let activeCount = Self.incrementActiveRequests()
        let startTime = Date()
        let logEndpoint = endpoint.split(separator: "?", maxSplits: 1).first.map(String.init) ?? endpoint

        Self.log("[\(clientId)][\(requestId)] START \(method) \(logEndpoint) (active=\(activeCount), retry=\(retryCount))")

        defer {
            let endCount = Self.decrementActiveRequests()
            let duration = Date().timeIntervalSince(startTime)
            Self.log("[\(clientId)][\(requestId)] END \(method) \(logEndpoint) duration=\(String(format: "%.3f", duration))s (active=\(endCount))")
        }

        guard baseURL.hasSuffix(Self.managementPath), let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")
        request.addValue(contentType, forHTTPHeaderField: "Content-Type")
        // Force new connection to avoid stale connection issues after idle periods
        request.addValue("close", forHTTPHeaderField: "Connection")
        
        if let body = body {
            request.httpBody = body
        }
        
        do {
            let (data, response) = try await data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard 200...299 ~= httpResponse.statusCode else {
                Self.log("[\(clientId)][\(requestId)] HTTP ERROR \(httpResponse.statusCode)")
                // 未注册的 OAuth 插件与整个管理 API 不可用都可能是 404，保留官方错误码进行区分。
                // 只取固定 provider_not_found 码，不展示包含账号或凭据的任意服务端正文。
                if endpoint.hasPrefix("/oauth/auth-url"), httpResponse.statusCode == 404,
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   payload["error"] as? String == "provider_not_found" {
                    throw APIError.oauthProviderNotFound
                }
                // 只有官方明确返回 not_found 的配置节点可使用默认值。
                // 无管理密钥、错误版本或整套接口缺失也会返回 404，不能把它们伪装成正常默认配置。
                if method == "GET", endpoint.hasPrefix("/config/"), httpResponse.statusCode == 404,
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   payload["error"] as? String == "not_found" {
                    throw ConfigNodeError.missing
                }
                // CPA 8 的配置接口会在错误正文中给出具体字段与校验原因。
                // 只解析配置写入响应，避免把其他接口的任意正文展示成诊断信息；
                // 不记录请求正文，其中可能含有上游服务商密钥。
                if (endpoint == "/config" || endpoint == "/config.yaml" || endpoint.hasPrefix("/config/")), method != "GET",
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let reason = (payload["message"] as? String) ?? (payload["error"] as? String) {
                    let singleLine = reason.components(separatedBy: .newlines).joined(separator: " ")
                    throw APIError.configRejected(httpResponse.statusCode, String(singleLine.prefix(300)))
                }
                throw APIError.httpError(httpResponse.statusCode)
            }
            
            return data
        } catch let error as URLError {
            Self.log("[\(clientId)][\(requestId)] URL ERROR: \(error.code.rawValue) - \(error.localizedDescription)")
            
            // 只重试没有副作用的读取。配置写入、凭据操作和 api-call 可能已在服务端完成，
            // OAuth 的 auth-url 虽然使用 GET 也会创建新会话，均不能因连接中断而自动执行第二次。
            // Exponential backoff: 0.5s, 1s, 2s, 3s (total ~6.5s wait for proxy restart)
            if method == "GET", !endpoint.hasPrefix("/oauth/auth-url"),
               retryCount < timeoutConfig.maxRetries && (error.code == .timedOut || error.code == .networkConnectionLost || error.code == .cannotConnectToHost) {
                let backoffSeconds = min(pow(2.0, Double(retryCount)) * 0.5, 3.0)  // Cap at 3 seconds
                let backoffStr = String(format: "%.1f", backoffSeconds)
                Self.log("[\(clientId)][\(requestId)] RETRYING after \(backoffStr)s (attempt \(retryCount + 1)/\(timeoutConfig.maxRetries))...")
                
                // Exponential backoff delay
                // 取消必须中断退避，不能吞掉 CancellationError 后重新创建网络请求。
                try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                return try await makeRequest(endpoint, method: method, body: body, retryCount: retryCount + 1, contentType: contentType)
            }
            throw APIError.connectionError(error.localizedDescription)
        } catch {
            Self.log("[\(clientId)][\(requestId)] UNEXPECTED ERROR: \(error.localizedDescription)")
            throw error
        }
    }

    private enum ConfigNodeError: Error { case missing }

    /// v8 返回配置节点本身，例如 true、3 或 "round-robin"，不再返回旧版字段包装对象。
    /// 缺省字段或显式 null 使用对应运行值；v8 的 null 会保存为节点，不能误当删除或类型损坏。
    /// 鉴权失败、端点不可用和非空类型错误必须交给调用方处理。
    private func configValue<Value: Decodable>(_ path: String, default fallback: Value) async throws -> Value {
        do { return try JSONDecoder().decode(Value?.self, from: await makeRequest("/config/" + path)) ?? fallback }
        catch ConfigNodeError.missing { return fallback }
    }

    /// v8 PUT 的正文必须是原始值，不能使用旧版 {value: ...} 包装。
    /// 保留斜杠原文以兼容 CPA 配置 YAML 解码器，尤其是代理 URL 和包含斜杠的密钥。
    private func setConfigValue<Value: Encodable>(_ path: String, value: Value) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try await mutateConfig("/config/" + path, method: "PUT", body: encoder.encode(value))
    }

    /// 官方配置写入必须返回 status=ok 与 config-version=8；仅收到 2xx 不足以宣称保存成功。
    /// 统一验证标量、配置树、迁移及 YAML 写入的确认，响应异常时不重复提交原修改。
    private func mutateConfig(_ endpoint: String, method: String, body: Data?, contentType: String = "application/json") async throws {
        struct Confirmation: Decodable { let status: String; let configVersion: Int
            enum CodingKeys: String, CodingKey { case status; case configVersion = "config-version" }
        }
        let data = try await makeRequest(endpoint, method: method, body: body, contentType: contentType)
        let confirmation = try JSONDecoder().decode(Confirmation.self, from: data)
        guard confirmation.status == "ok", confirmation.configVersion == 8 else { throw APIError.invalidResponse }
    }

    /// 凭据与导入运维接口以 status=ok 确认完成，不能仅凭 HTTP 200 就让界面移除或新增账号。
    private func mutateOperation(_ endpoint: String, method: String, body: Data? = nil, contentType: String = "application/json") async throws {
        struct Confirmation: Decodable { let status: String }
        let data = try await makeRequest(endpoint, method: method, body: body, contentType: contentType)
        guard try JSONDecoder().decode(Confirmation.self, from: data).status == "ok" else { throw APIError.invalidResponse }
    }

    /// URLQueryItem 不会转义加号，而管理查询可能按表单规则解释它，统一保护不透明参数值。
    private nonisolated static func queryEndpoint(_ components: URLComponents) throws -> String {
        guard let endpoint = components.string else { throw APIError.invalidURL }
        return endpoint.replacingOccurrences(of: "+", with: "%2B")
    }

    nonisolated static func authFileEndpoint(_ path: String, name: String) throws -> String {
        let queryValueCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: queryValueCharacters) else {
            throw APIError.invalidURL
        }
        return path + "?name=" + encodedName
    }

    func fetchAuthFiles() async throws -> [AuthFile] {
        let data = try await makeRequest("/credentials")
        let response = try JSONDecoder().decode(AuthFilesResponse.self, from: data)
        return response.files
    }

    func fetchAuthFileModels(name: String) async throws -> [AuthFileModelInfo] {
        let endpoint = try Self.authFileEndpoint("/credentials/models", name: name)
        let data = try await makeRequest(endpoint)
        let response = try JSONDecoder().decode(AuthFileModelsResponse.self, from: data)
        return response.models
    }
    
    func apiCall(_ request: APICallRequest) async throws -> APICallResponse {
        let body = try JSONEncoder().encode(request)
        let data = try await makeRequest("/requests/api-call", method: "POST", body: body)
        return try JSONDecoder().decode(APICallResponse.self, from: data)
    }
    
    func deleteAuthFile(name: String) async throws {
        let endpoint = try Self.authFileEndpoint("/credentials", name: name)
        try await mutateOperation(endpoint, method: "DELETE")
    }

    func uploadAuthFile(name: String, content: Data) async throws {
        let endpoint = try Self.authFileEndpoint("/credentials", name: name)
        try await mutateOperation(endpoint, method: "POST", body: content)
    }

    func downloadAuthFile(name: String) async throws -> Data {
        let endpoint = try Self.authFileEndpoint("/credentials/download", name: name)
        return try await makeRequest(endpoint)
    }
    
    func deleteAllAuthFiles() async throws {
        try await mutateOperation("/credentials?all=true", method: "DELETE")
    }

    func setAuthFileDisabled(name: String, disabled: Bool) async throws {
        struct Request: Encodable {
            let name: String
            let disabled: Bool
        }
        let body = try JSONEncoder().encode(Request(name: name, disabled: disabled))
        try await mutateOperation("/credentials/status", method: "PATCH", body: body)
    }
    
    /// 新版 CPA 用量队列是“读取即移除”。使用单次网络请求，不能沿用 makeRequest 的自动重试：
    /// 超时不代表后端没有弹出记录，盲目重试会消费下一批并掩盖前一批的传输缺口。
    func fetchUsageQueue(count: Int = 500) async throws -> UsageQueueBatch {
        guard baseURL.hasSuffix(Self.managementPath),
              let url = URL(string: baseURL + "/observability/usage/queue?count=" + String(max(1, min(count, 500)))) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + authKey, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw APIError.httpError(response.statusCode) }
        return try JSONDecoder().decode(UsageQueueBatch.self, from: data)
    }

    func getUsageStatisticsEnabled() async throws -> Bool {
        try await configValue("observability/usage/usage-statistics-enabled", default: false)
    }

    func setUsageStatisticsEnabled(_ enabled: Bool) async throws {
        try await setConfigValue("observability/usage/usage-statistics-enabled", value: enabled)
    }
    
    nonisolated static func cpaOAuthProviderKey(for provider: AIProvider) -> String {
        switch provider {
        case .grok:
            return "xai"
        default:
            return provider.rawValue
        }
    }

    func getOAuthURL(for provider: AIProvider) async throws -> OAuthURLResponse {
        // v8 将各服务商的旧专用授权路径统一为 provider 参数；URLQueryItem 负责参数值编码。
        var components = URLComponents()
        components.path = "/oauth/auth-url"
        let providerKey = Self.cpaOAuthProviderKey(for: provider)
        components.queryItems = [URLQueryItem(name: "provider", value: providerKey)]

        let webUIProviders: [AIProvider] = [.antigravity, .claude, .codex, .iflow, .kiro, .grok, .devin]
        if webUIProviders.contains(provider) {
            components.queryItems?.append(URLQueryItem(name: "is_webui", value: "true"))
        }

        do {
            let data = try await makeRequest(try Self.queryEndpoint(components))
            return try JSONDecoder().decode(OAuthURLResponse.self, from: data)
        } catch APIError.oauthProviderNotFound {
            // 不删除旧服务商功能；未启用插件时明确指出需要补齐能力，注册后仍走同一 v8 契约。
            throw APIError.oauthUnavailable(provider)
        }
    }
    
    func pollOAuthStatus(state: String) async throws -> OAuthStatusResponse {
        var components = URLComponents()
        components.path = "/oauth/status"
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        let data = try await makeRequest(try Self.queryEndpoint(components))
        return try JSONDecoder().decode(OAuthStatusResponse.self, from: data)
    }

    /// 解析完整回调 URL、参数串、code: 前缀或原始授权码，并始终绑定调用者的挂起 state。
    /// 所有形式最终重新编码查询参数，保护授权码里的 + / =，避免 Go 的表单解码把 + 变为空格。
    /// 本方法只构造交给 CPA 解析的字符串，不访问回调地址，也不记录授权码或 state。
    nonisolated static func resolveCallbackURL(provider: AIProvider, input: String, state: String?, defaultPort: Int = 8317) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let state, !state.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = defaultPort
        components.path = "/oauth/callback"
        var items: [URLQueryItem]
        if trimmed.range(of: #"(?i)^https?://"#, options: .regularExpression) != nil {
            guard let supplied = URLComponents(string: trimmed), let host = supplied.host, !host.isEmpty,
                  let query = supplied.queryItems else { return nil }
            components = supplied
            items = query
            // 完整回调必须自带唯一 state，不能给缺失 state 的另一个 URL 补上当前会话。
            guard items.filter({ $0.name == "state" }).count == 1 else { return nil }
        } else {
            let query = trimmed.hasPrefix("?") || trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
            // URLComponents(string:) 能安全拒绝非法查询输入，避免直接设置 percentEncodedQuery 的前置条件崩溃。
            let parsed = URLComponents(string: "http://localhost/?" + query)?.queryItems ?? []
            if query.contains("="), parsed.contains(where: { ["code", "state", "error"].contains($0.name) }) {
                items = parsed
                if !items.contains(where: { $0.name == "state" }) { items.append(URLQueryItem(name: "state", value: state)) }
            } else {
                // 使用前缀范围而不是按等号切分，code: xxx 和含 = 的不透明授权码都能完整保留。
                let prefix = trimmed.range(of: #"(?i)^code\s*[:=]\s*"#, options: .regularExpression)
                let code = prefix.map { String(trimmed[$0.upperBound...]) } ?? trimmed
                guard !code.isEmpty, !code.contains(where: { $0.isWhitespace }),
                      !code.contains("&"), !code.contains("?"), !code.contains("#"), !code.contains(":") else { return nil }
                items = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
            }
        }
        // 拒绝重复参数及跨会话回调，不让后端替客户端决定应完成哪个挂起登录。
        for name in ["code", "state", "error", "error_description"] {
            guard items.filter({ $0.name == name }).count <= 1 else { return nil }
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              items.contains(where: { ($0.name == "code" || $0.name == "error") && !($0.value ?? "").isEmpty }) else { return nil }
        components.queryItems = items
        return components.string?.replacingOccurrences(of: "+", with: "%2B")
    }

    /// 手动提交 OAuth 回调 URL（解决浏览器无法自动跳转到 localhost:8317 时的兜底完成）
    func submitOAuthCallback(provider: AIProvider, redirectURL: String) async throws {
        struct Request: Encodable {
            let provider: String
            let redirect_url: String
        }
        let providerKey = Self.cpaOAuthProviderKey(for: provider)
        let body = try JSONEncoder().encode(Request(provider: providerKey, redirect_url: redirectURL))
        try await mutateOperation("/oauth/callback", method: "POST", body: body)
    }

    /// 取消服务端挂起的登录会话；仅清空客户端弹窗不能阻止后端随后保存凭据。
    /// cancelled=false 表示该 state 已完成或不存在，不误报为网络失败，也不触碰已经保存的账号。
    func cancelOAuthSession(state: String) async throws -> Bool {
        var components = URLComponents()
        components.path = "/oauth/session"
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        struct Response: Decodable { let status: String; let cancelled: Bool }
        let data = try await makeRequest(try Self.queryEndpoint(components), method: "DELETE")
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == "ok" else { throw APIError.invalidResponse }
        return response.cancelled
    }
    
    func fetchLogs(after: Int? = nil, cursor: String? = nil, limit: Int = 2000) async throws -> LogsResponse {
        // CPA 新版本使用文件游标，避免秒级时间戳遗漏同一秒内后写入的日志。
        // URLQueryItem 负责编码不透明游标，避免不透明值包含查询分隔符时改变请求含义。
        var components = URLComponents()
        components.path = "/observability/logs"
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
        } else if let after {
            components.queryItems?.append(URLQueryItem(name: "after", value: String(after)))
        }
        let data = try await makeRequest(try Self.queryEndpoint(components))
        return try JSONDecoder().decode(LogsResponse.self, from: data)
    }
    
    func clearLogs() async throws {
        // 日志清理使用 success=true，属于独立运维响应，不能按配置或凭据的确认结构解码。
        struct Confirmation: Decodable { let success: Bool }
        let data = try await makeRequest("/observability/logs", method: "DELETE")
        guard try JSONDecoder().decode(Confirmation.self, from: data).success else { throw APIError.invalidResponse }
    }
    
    func setDebug(_ enabled: Bool) async throws {
        try await setConfigValue("observability/logs/debug", value: enabled)
    }

    /// v8 支持对象深度合并：同一表单开关控制的三个字段必须在一次 PATCH 中一起校验和保存。
    /// 避免第二／三次请求失败时仅更新 debug，令界面显示失败但磁盘已经留下部分修改。
    /// 只发送这三个布尔值，保留日志容量、错误文件数量和其他未编辑配置；不自动重试写入。
    func setDebugLogging(_ enabled: Bool) async throws {
        let patch = try JSONSerialization.data(withJSONObject: ["observability": ["logs": [
            "debug": enabled, "logging-to-file": enabled, "request-log": enabled
        ]]])
        try await patchV8Config(patch)
    }
    
    func setRoutingStrategy(_ strategy: String) async throws {
        try await setConfigValue("routing/strategy", value: strategy)
    }

    /// 只更新主开关；关闭会话绑定时保留 TTL 和子代理选项，重新开启可恢复用户设置。
    func setSessionAffinity(_ enabled: Bool) async throws {
        try await setConfigValue("routing/session-affinity", value: enabled)
    }

    /// 文件凭据使用字段 PATCH，不下载并重新上传整个认证文件，避免覆盖刷新中的令牌。
    /// 权重正文是整数，只修改 weight；不携带密钥、其他 metadata 或账号优先级。
    func setAuthFileWeight(name: String, weight: Int) async throws {
        _ = try CPAAccountWeight.parse(String(weight))
        struct Request: Encodable { let name: String; let weight: Int }
        try await mutateOperation("/credentials/fields", method: "PATCH",
            body: JSONEncoder().encode(Request(name: name, weight: weight)))
    }

    /// 列表中的 weight 是非秘密元数据；读取时不下载令牌文件，并核对目标名称避免编辑错账号。
    func fetchAuthFileWeight(name: String) async throws -> Int {
        struct Entry: Decodable { let id: String?; let name: String; let weight: Int? }
        struct Response: Decodable { let files: [Entry] }
        let data = try await makeRequest(Self.authFileEndpoint("/credentials", name: name))
        let entries = try JSONDecoder().decode(Response.self, from: data).files
        guard let entry = entries.first(where: { $0.name == name || $0.id == name }) else { throw APIError.invalidResponse }
        return entry.weight ?? 1
    }

    /// 凭据调度元数据（权重与优先级）。
    struct AuthFileRoutingMetadata: Sendable, Equatable {
        let weight: Int
        let priority: Int
    }

    /// 读取凭据调度元数据（权重与优先级）。
    func fetchAuthFileRouting(name: String) async throws -> AuthFileRoutingMetadata {
        struct Entry: Decodable { let id: String?; let name: String; let weight: Int?; let priority: Int? }
        struct Response: Decodable { let files: [Entry] }
        let data = try await makeRequest(Self.authFileEndpoint("/credentials", name: name))
        let entries = try JSONDecoder().decode(Response.self, from: data).files
        guard let entry = entries.first(where: { $0.name == name || $0.id == name }) else { throw APIError.invalidResponse }
        return AuthFileRoutingMetadata(weight: entry.weight ?? 1, priority: entry.priority ?? 0)
    }

    /// 写入凭据调度元数据（权重与优先级）。
    func setAuthFileRouting(name: String, weight: Int, priority: Int) async throws {
        _ = try CPAAccountWeight.parse(String(weight))
        _ = try CPAAccountPriority.parse(String(priority))
        struct Request: Encodable {
            let name: String
            let weight: Int
            let priority: Int
        }
        try await mutateOperation("/credentials/fields", method: "PATCH",
            body: JSONEncoder().encode(Request(name: name, weight: weight, priority: priority)))
    }

    /// 重置指定凭据在 CPA 内核中的冷却或配额耗尽状态。
    func resetCredentialCooldown(authIndex: String) async throws {
        let trimmed = authIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.invalidResponse }
        struct Request: Encodable {
            let auth_index: String
        }
        try await mutateOperation("/routing/cooldown/reset", method: "POST",
            body: JSONEncoder().encode(Request(auth_index: trimmed)))
    }
    
    /// Get routing strategy
    func getRoutingStrategy() async throws -> String {
        try await configValue("routing/strategy", default: "round-robin")
    }
    
    func setRequestRetry(_ count: Int) async throws {
        try await setConfigValue("routing/retry/request-retry", value: count)
    }
    
    // MARK: - Configuration Getters
    
    /// Fetch the full proxy configuration.
    func fetchConfig() async throws -> ProxyConfig {
        let data = try await makeRequest("/config")
        guard Self.isV8Configuration(data) else { throw APIError.invalidResponse }
        return try JSONDecoder().decode(ProxyConfig.self, from: data)
    }

    // MARK: - CPA 模型别名

    /// 必须读取完整 YAML，而非裁剪后的 ProxyConfig，防止保存时丢失凭据或未知配置。
    /// 内容只交给配置服务解析，不输出到日志或界面。
    func fetchModelAliasYAML() async throws -> String {
        let data = try await makeRequest("/config.yaml")
        guard let text = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse }
        return text
    }

    /// 官方 v8 的空 PATCH 会把仍可读取的旧版配置规范化并写回 v8 布局。
    /// 调用方负责先备份原文件，并在响应后核对文件和管理接口状态。
    func migrateLegacyConfigToV8() async throws {
        try await mutateConfig("/config", method: "PATCH", body: Data("{}".utf8))
    }

    /// 对 v8 配置做局部更新，由 CPA 校验并保留未触及区块的注释。
    func patchV8Config(_ patch: Data) async throws {
        try await mutateConfig("/config", method: "PATCH", body: patch)
    }

    /// v8 配置树的局部 PUT/DELETE 用于模型别名，避免整份 YAML 序列化清除手工注释。
    /// 列表需要整体替换；缺失的旧字段在回滚时使用 DELETE，而不是写入 null。
    func putV8Config(path: [String], body: Data?) async throws {
        guard !path.isEmpty,
              path.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else {
            throw APIError.invalidURL
        }
        let endpoint = "/config/" + path.joined(separator: "/")
        let method = body == nil ? "DELETE" : "PUT"
        // 客户端已经统一为 v8，不再临时创建另一个会话转换旧前缀，保持取消/停机语义一致。
        try await mutateConfig(endpoint, method: method, body: body)
    }

    func saveModelAliasYAML(_ text: String) async throws {
        try await mutateConfig("/config.yaml", method: "PUT", body: Data(text.utf8), contentType: "application/yaml")
    }

    /// v8 的 OAuth 别名属于配置树；局部 PUT 会持久化并热重载目录与请求路由。
    func replaceOAuthModelAliases(_ data: Data) async throws {
        try await putV8Config(path: ["oauth", "model-alias"], body: data)
    }

    func fetchModelAliasDefinitions(channel: String) async throws -> Data {
        guard ["vertex", "aistudio", "antigravity", "claude", "codex", "kimi", "xai"].contains(channel) else {
            throw APIError.invalidURL
        }
        return try await makeRequest("/routing/model-definitions/\(channel)")
    }

    /// /v1/models 使用代理客户端 API Key，不把管理密钥误当成业务凭据，也不从模型名猜测来源。
    func fetchModelAliasCatalog() async throws -> [String] {
        let keys = try await fetchAPIKeys()
        // access.api-keys 为空时，CPA 的配置认证提供方不会注册；模型接口允许无认证访问。
        // 此时仍读取目录且不发送 Authorization，绝不拿管理密钥填补业务认证值。
        let key = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard var components = URLComponents(string: baseURL) else { throw APIError.invalidURL }
        components.path = "/v1/models"
        components.query = nil
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        // 额外的访问插件可能仍要求认证；保留实际状态，不把 401/403 误报成目录解码失败。
        guard 200...299 ~= response.statusCode else { throw APIError.httpError(response.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else { throw APIError.invalidResponse }
        return models.compactMap { $0["id"] as? String }
    }
    
    /// Get debug mode status
    func getDebug() async throws -> Bool {
        try await configValue("observability/logs/debug", default: false)
    }
    
    /// Get proxy URL (upstream proxy)
    func getProxyURL() async throws -> String {
        try await configValue("requests/proxy-url", default: "")
    }
    
    /// Set proxy URL (upstream proxy)
    func setProxyURL(_ url: String) async throws {
        try await setConfigValue("requests/proxy-url", value: url)
    }
    
    /// Delete/clear proxy URL
    func deleteProxyURL() async throws {
        do { try await putV8Config(path: ["requests", "proxy-url"], body: nil) }
        catch APIError.configRejected(404, "not_found") {
            // v8 DELETE 缺失字段返回明确 not_found；“清空”是幂等操作，此时已经达到目标。
            // 其他 404（未启用管理接口、鉴权配置缺失等）仍须报告失败，不能一概吞掉。
        }
    }
    
    /// Get logging to file status
    func getLoggingToFile() async throws -> Bool {
        try await configValue("observability/logs/logging-to-file", default: false)
    }
    
    /// Set logging to file
    func setLoggingToFile(_ enabled: Bool) async throws {
        try await setConfigValue("observability/logs/logging-to-file", value: enabled)
    }
    
    /// Get request log status
    func getRequestLog() async throws -> Bool {
        try await configValue("observability/logs/request-log", default: false)
    }
    
    /// Set request log
    func setRequestLog(_ enabled: Bool) async throws {
        try await setConfigValue("observability/logs/request-log", value: enabled)
    }
    
    /// Get request retry count
    func getRequestRetry() async throws -> Int {
        // 官方模板显式写 3/30，但 CPA 8 加载未声明的整数时实际为 0/0。
        // 精确缺失节点按运行时取值，不将模板推荐值当成用户已经生效的配置。
        try await configValue("routing/retry/request-retry", default: 0)
    }
    
    /// Get max retry interval
    func getMaxRetryInterval() async throws -> Int {
        try await configValue("routing/retry/max-retry-interval", default: 0)
    }
    
    /// Set max retry interval
    func setMaxRetryInterval(_ seconds: Int) async throws {
        try await setConfigValue("routing/retry/max-retry-interval", value: seconds)
    }
    
    func uploadVertexServiceAccount(jsonPath: String) async throws {
        let url = URL(fileURLWithPath: jsonPath)
        let fileData = try Data(contentsOf: url)
        try await uploadVertexServiceAccount(data: fileData)
    }

    func uploadVertexServiceAccount(data: Data) async throws {
        // v8 的 Vertex 导入只接受 multipart 的 file 字段，不能继续发送旧版原始 JSON。
        // 固定文件名不含用户输入；随机边界与原始字节一起发送，保留服务账号 JSON 的完整内容。
        let boundary = "QuotioVertex-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"service-account.json\"\r\nContent-Type: application/json\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try await mutateOperation("/oauth/import?provider=vertex", method: "POST", body: body,
            contentType: "multipart/form-data; boundary=" + boundary)
    }
    
    func fetchAPIKeys() async throws -> [String] {
        try await configValue("access/api-keys", default: [])
    }
    
    func addAPIKey(_ key: String) async throws {
        try await editClientKeys { $0 + [key] }
    }
    
    func replaceAPIKeys(_ keys: [String]) async throws {
        try await editClientKeys(requiresRead: false) { _ in keys }
    }
    
    func updateAPIKey(old: String, new: String) async throws {
        // v8 的数组 PATCH 会替换整个数组，旧版 old/new 对象不再支持。
        // 读取当前客户端密钥列表后仅替换匹配项；不触碰顶层 api-keys 中的上游凭据。
        try await editClientKeys { keys in
            guard let index = keys.firstIndex(of: old) else { throw APIError.invalidResponse }
            var updated = keys; updated[index] = new; return updated
        }
    }
    
    func deleteAPIKey(value: String) async throws {
        try await editClientKeys { keys in
            guard let index = keys.firstIndex(of: value) else { throw APIError.invalidResponse }
            var updated = keys; updated.remove(at: index); return updated
        }
    }
    
    func deleteAPIKeyByIndex(_ index: Int) async throws {
        try await editClientKeys { keys in
            guard keys.indices.contains(index) else { throw APIError.invalidResponse }
            var updated = keys; updated.remove(at: index); return updated
        }
    }

    /// 仅串行保护当前客户端的密钥修改，不锁住日志/额度等只读请求。
    /// v8 没有列表元素级 CAS；其他外部客户端同时改同一列表仍应避免，这里不声称跨客户端事务。
    private func editClientKeys(requiresRead: Bool = true, _ edit: ([String]) throws -> [String]) async throws {
        guard !isEditingClientKeys else { throw APIError.operationInProgress }
        isEditingClientKeys = true
        defer { isEditingClientKeys = false }
        let current = requiresRead ? try await fetchAPIKeys() : []
        try Task.checkCancellation()
        try await setConfigValue("access/api-keys", value: edit(current))
    }
    
    // MARK: - Proxy Version & Health
    
    /// Fetch the latest proxy version available from the running proxy.
    /// The proxy fetches this from GitHub releases.
    func fetchLatestVersion() async throws -> LatestVersionResponse {
        let data = try await makeRequest("/server/latest-version")
        return try JSONDecoder().decode(LatestVersionResponse.self, from: data)
    }
    
    /// 用 v8 配置根检查代理；不能用旧兼容接口把运行中的 CPA 7 误判为受支持的服务。
    func checkProxyResponding() async -> Bool {
        do {
            _ = try await fetchConfig()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Latest Version Response

nonisolated struct LatestVersionResponse: Codable, Sendable {
    let latestVersion: String
    
    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest-version"
    }
}

// MARK: - URLSession Delegate

/// 管理 API 与启动健康探测共用同一重定向约束，不能让独立探测会话绕过认证边界。
final class ManagementSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    private let clientId: String
    
    init(clientId: String) {
        self.clientId = clientId
        super.init()
    }
    
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let errorMsg = error?.localizedDescription ?? "none"
        Log.api("[\(clientId)] Session invalidated, error=\(errorMsg)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // 不通过另一个会话追随外部地址，原请求得到 3xx 后由调用方报告失败，不泄露认证头。
        completionHandler(ManagementAPIClient.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard ManagementAPIClient.enableDiagnosticLogging else { return }
        
        for metric in metrics.transactionMetrics {
            let connectionType = metric.isReusedConnection ? "reused" : "new"
            let durationSec = metric.responseEndDate?.timeIntervalSince(metric.requestStartDate ?? Date()) ?? 0
            let durationStr = String(format: "%.3f", durationSec)
            Log.api("[\(clientId)] Connection: \(connectionType), duration=\(durationStr)s")
        }
    }
}

// MARK: - Response Types

nonisolated struct LogsResponse: Codable, Sendable {
    let lines: [String]?
    let lineCount: Int?
    let latestTimestamp: Int?
    var nextCursor: String? = nil
    var cursorReset: Bool? = nil
    
    enum CodingKeys: String, CodingKey {
        case lines
        case lineCount = "line-count"
        case latestTimestamp = "latest-timestamp"
        case nextCursor = "next-cursor"
        case cursorReset = "cursor-reset"
    }
}

nonisolated struct AuthFileModelsResponse: Codable, Sendable {
    let models: [AuthFileModelInfo]
}

nonisolated struct AuthFileModelInfo: Codable, Sendable {
    let id: String
    let ownedBy: String?
    let type: String?
    /// v8 凭据模型接口明确返回的显示名，缺省兼容既有响应及成员初始化调用。
    var displayName: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, type
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }
}

nonisolated struct APICallRequest: Codable, Sendable {
    let authIndex: String?
    let method: String
    let url: String
    let header: [String: String]?
    let data: String?
    
    enum CodingKeys: String, CodingKey {
        case method, url, header, data
        case authIndex = "auth_index"
    }
}

nonisolated struct APICallResponse: Codable, Sendable {
    let statusCode: Int
    let header: [String: [String]]?
    let body: String?
    
    enum CodingKeys: String, CodingKey {
        case header, body
        case statusCode = "status_code"
    }
}

nonisolated enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case configRejected(Int, String)
    case operationInProgress
    case oauthProviderNotFound
    case oauthUnavailable(AIProvider)
    case decodingError(String)
    case connectionError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .httpError(let code): return "HTTP error: \(code)"
        case .configRejected(let code, let reason): return "CPA 8 配置校验失败（HTTP \(code)）：\(reason)"
        case .operationInProgress: return "正在修改客户端密钥，请等待当前操作完成后重试"
        case .oauthProviderNotFound: return "CPA 8 当前未注册该 OAuth 提供商"
        case .oauthUnavailable(let provider):
            return String(format: (provider.requiresCPA8OAuthPlugin ? "oauth.cpa8PluginUnavailable" : "oauth.cpa8ProviderUnavailable").localizedStatic(), provider.displayName)
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .connectionError(let msg): return "Connection error: \(msg)"
        }
    }
}

// MARK: - Configuration Response Types

nonisolated struct ProxyConfig: Codable, Sendable {
    let debug: Bool?
    let proxyURL: String?
    let routingStrategy: String?
    let requestRetry: Int?
    let maxRetryInterval: Int?
    let loggingToFile: Bool?
    let requestLog: Bool?
    let sessionAffinity: Bool?
    let sessionAffinityTTL: String?
    let sessionAffinitySubagents: Bool?
    let maxRetryCredentials: Int?
    let streamingKeepaliveSeconds: Int?
    let streamingBootstrapRetries: Int?
    let logsMaxTotalSizeMB: Int?
    let errorLogsMaxFiles: Int?
    
    enum CodingKeys: String, CodingKey {
        case debug
        case proxyURL = "proxy-url"
        case routingStrategy = "routing-strategy"
        case requestRetry = "request-retry"
        case maxRetryInterval = "max-retry-interval"
        case loggingToFile = "logging-to-file"
        case requestLog = "request-log"
    }

    /// 界面仍使用原有简洁属性，网络解码则按 v8 的嵌套配置树取值。
    /// 旧字段仅用于本地历史数据解码；网络请求不会因此退回旧管理 API。
    /// v8 无对应字段的旧额度切换开关由解码器忽略；不再创建展示或写入这些开关的数据模型。
    init(from decoder: any Decoder) throws {
        let legacy = try decoder.container(keyedBy: CodingKeys.self)
        let root = try decoder.container(keyedBy: V8Keys.self)
        let logs = try root.decodeIfPresent(Observability.self, forKey: .observability)?.logs
        let requests = try root.decodeIfPresent(Requests.self, forKey: .requests)
        let routing = try root.decodeIfPresent(Routing.self, forKey: .routing)
        debug = try logs?.debug ?? legacy.decodeIfPresent(Bool.self, forKey: .debug)
        proxyURL = try requests?.proxyURL ?? legacy.decodeIfPresent(String.self, forKey: .proxyURL)
        routingStrategy = try routing?.strategy ?? legacy.decodeIfPresent(String.self, forKey: .routingStrategy)
        requestRetry = try routing?.retry?.requestRetry ?? legacy.decodeIfPresent(Int.self, forKey: .requestRetry)
        maxRetryInterval = try routing?.retry?.maxRetryInterval ?? legacy.decodeIfPresent(Int.self, forKey: .maxRetryInterval)
        loggingToFile = try logs?.loggingToFile ?? legacy.decodeIfPresent(Bool.self, forKey: .loggingToFile)
        requestLog = try logs?.requestLog ?? legacy.decodeIfPresent(Bool.self, forKey: .requestLog)
        // 新增字段只读取 v8 节点，显式 false 和 0 不得被模板建议值覆盖。
        sessionAffinity = routing?.sessionAffinity
        sessionAffinityTTL = routing?.sessionAffinityTTL
        sessionAffinitySubagents = routing?.sessionAffinitySubagents
        maxRetryCredentials = routing?.retry?.maxRetryCredentials
        streamingKeepaliveSeconds = requests?.streaming?.keepaliveSeconds
        streamingBootstrapRetries = requests?.streaming?.bootstrapRetries
        logsMaxTotalSizeMB = logs?.logsMaxTotalSizeMB
        errorLogsMaxFiles = logs?.errorLogsMaxFiles
    }

    private enum V8Keys: String, CodingKey { case observability, requests, routing }
    private struct Observability: Decodable { let logs: Logs? }
    private struct Logs: Decodable {
        let debug: Bool?
        let loggingToFile: Bool?
        let requestLog: Bool?
        let logsMaxTotalSizeMB: Int?
        let errorLogsMaxFiles: Int?
        enum CodingKeys: String, CodingKey {
            case debug
            case loggingToFile = "logging-to-file"
            case requestLog = "request-log"
            case logsMaxTotalSizeMB = "logs-max-total-size-mb"
            case errorLogsMaxFiles = "error-logs-max-files"
        }
    }
    private struct Requests: Decodable {
        let proxyURL: String?
        let streaming: Streaming?
        enum CodingKeys: String, CodingKey { case proxyURL = "proxy-url"; case streaming }
    }
    private struct Streaming: Decodable {
        let keepaliveSeconds: Int?
        let bootstrapRetries: Int?
        enum CodingKeys: String, CodingKey {
            case keepaliveSeconds = "keepalive-seconds"
            case bootstrapRetries = "bootstrap-retries"
        }
    }
    private struct Routing: Decodable {
        let strategy: String?
        let retry: Retry?
        let sessionAffinity: Bool?
        let sessionAffinityTTL: String?
        let sessionAffinitySubagents: Bool?
        enum CodingKeys: String, CodingKey {
            case strategy, retry
            case sessionAffinity = "session-affinity"
            case sessionAffinityTTL = "session-affinity-ttl"
            case sessionAffinitySubagents = "session-affinity-subagents"
        }
    }
    private struct Retry: Decodable {
        let requestRetry: Int?
        let maxRetryInterval: Int?
        let maxRetryCredentials: Int?
        enum CodingKeys: String, CodingKey {
            case requestRetry = "request-retry"
            case maxRetryInterval = "max-retry-interval"
            case maxRetryCredentials = "max-retry-credentials"
        }
    }
}
