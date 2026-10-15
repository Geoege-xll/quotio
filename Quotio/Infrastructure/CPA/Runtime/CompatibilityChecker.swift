//
//  CompatibilityChecker.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Service for validating proxy is responding before activation.
//

import Foundation

/// Service for checking proxy compatibility with Quotio.
/// Simplified to just verify proxy responds to API requests.
actor CompatibilityChecker {
    
    private let session: URLSession
    
    /// 正常启动使用默认传输；测试可注入 URLProtocol，验证实际探测请求且不启动真实 CPA。
    init(configuration: URLSessionConfiguration = .default) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 健康检查也携带管理密钥。复用主客户端的同源约束，拒绝跨主机、换端口或降级跳转；
        // 即使跳转目标返回有效 v8 配置，也不能把目标服务当作当前端口上的 CPA。
        self.session = URLSession(configuration: config,
            delegate: ManagementSessionDelegate(clientId: "CPA-health"), delegateQueue: nil)
    }
    
    // MARK: - Compatibility Check
    
    /// Check if a running proxy is responding to API requests.
    /// - Parameters:
    ///   - port: The port the proxy is running on
    ///   - host: The host (defaults to 127.0.0.1)
    /// - Returns: Compatibility check result
    func checkCompatibility(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> CompatibilityCheckResult {
        let baseURL = "http://\(host):\(port)"
        
        // Try to call a simple management endpoint
        do {
            let isResponding = try await checkManagementEndpoint(baseURL: baseURL, managementKey: managementKey)
            return isResponding ? .compatible : .proxyNotResponding
        } catch {
            return .connectionError(error.localizedDescription)
        }
    }
    
    /// Check if a proxy is running and healthy.
    /// - Parameters:
    ///   - port: The port to check
    ///   - host: The host (defaults to 127.0.0.1)
    /// - Returns: true if the proxy responds
    func isHealthy(
        port: UInt16,
        host: String = "127.0.0.1",
        managementKey: String,
        requestTimeout: TimeInterval = 3
    ) async -> Bool {
        let baseURL = "http://\(host):\(port)"
        
        guard let request = makeManagementRequest(
            baseURL: baseURL,
            managementKey: managementKey,
            timeoutInterval: requestTimeout
        ) else {
            return false
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            
            // 状态码成功还需验证 v8 配置标记，避免错误服务或格式异常被当作已就绪的代理。
            return 200...299 ~= httpResponse.statusCode && ManagementAPIClient.isV8Configuration(data)
        } catch {
            return false
        }
    }
    
    /// Perform a full compatibility check including health.
    /// - Parameters:
    ///   - port: The port the proxy is running on
    ///   - host: The host (defaults to 127.0.0.1)
    /// - Returns: Compatibility check result (checks health first, then compatibility)
    func fullCheck(port: UInt16, host: String = "127.0.0.1", managementKey: String) async -> CompatibilityCheckResult {
        // First check if proxy is healthy
        guard await isHealthy(port: port, host: host, managementKey: managementKey) else {
            return .proxyNotRunning
        }
        
        // Then check compatibility (which is now just verifying it responds)
        return await checkCompatibility(port: port, host: host, managementKey: managementKey)
    }
    
    // MARK: - Private Helpers
    
    private func makeManagementRequest(
        baseURL: String,
        managementKey: String,
        timeoutInterval: TimeInterval = 3
    ) -> URLRequest? {
        // v8 配置接口只在 CPA 8 系列存在；以此探测能避免把仍支持旧接口的 v7 误判为兼容。
        guard let url = URL(string: ManagementAPIClient.managementURL(for: baseURL) + "/config") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.addValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func checkManagementEndpoint(baseURL: String, managementKey: String) async throws -> Bool {
        guard let request = makeManagementRequest(baseURL: baseURL, managementKey: managementKey) else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        return 200...299 ~= httpResponse.statusCode && ManagementAPIClient.isV8Configuration(data)
    }
}

// MARK: - Convenience Extensions

extension CompatibilityCheckResult {
    /// Check if the result indicates the proxy should be usable.
    var shouldProceed: Bool {
        switch self {
        case .compatible:
            return true
        case .proxyNotResponding, .proxyNotRunning, .connectionError:
            return false
        }
    }
}
