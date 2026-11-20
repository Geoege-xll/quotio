//
//  TraeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Trae (ByteDance) using stored auth tokens
//  Reads auth from Trae's storage.json file
//

import Foundation

/// Auth data from Trae's storage.json
struct TraeAuthData: Sendable {
    let accessToken: String?
    let refreshToken: String?
    let email: String?
    let userId: String?
    let apiHost: String?
    let username: String?
}

/// Quota info from Trae API
struct TraeQuotaInfo: Sendable {
    let email: String?
    let userId: String?
    let username: String?
    let planType: String?
    
    // Usage limits
    let advancedModelLimit: Int
    let advancedModelUsed: Int?
    let autoCompletionLimit: Int
    let autoCompletionUsed: Int?
    let premiumFastLimit: Int
    let premiumFastUsed: Int?
    let premiumSlowLimit: Int
    let premiumSlowUsed: Int?
    
    let resetTime: Date?
}

/// Fetches quota from Trae using stored auth
actor TraeQuotaFetcher {
    private var session: URLSession
    private let readAuth: (@Sendable () -> TraeAuthData?)?
    private let storageJsonPath = "~/Library/Application Support/Trae/User/globalStorage/storage.json"
    private let authKey = "iCubeAuthInfo://icube.cloudide"
    
    /// 生产读取原存储文件；测试注入临时认证数据与 URLSession 验证出站前的账号筛选。
    init(configuration: URLSessionConfiguration? = nil, readAuth: (@Sendable () -> TraeAuthData?)? = nil) {
        self.readAuth = readAuth
        let config = configuration ?? ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }
    
    /// Check if Trae is installed
    func isInstalled() async -> Bool {
        let appPaths = [
            "/Applications/Trae.app",
            NSString(string: "~/Applications/Trae.app").expandingTildeInPath
        ]
        
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if Trae auth exists
    func hasAuth() -> Bool {
        let authData = readAuthFromStorageJson()
        return authData?.accessToken != nil
    }
    
    /// Read auth data from Trae's storage.json
    func readAuthFromStorageJson() -> TraeAuthData? {
        if let readAuth { return readAuth() }
        let expandedPath = NSString(string: storageJsonPath).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }
        
        guard let data = FileManager.default.contents(atPath: expandedPath),
              let storageJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Get the auth info string from storage.json
        guard let authInfoString = storageJson[authKey] as? String,
              let authInfoData = authInfoString.data(using: .utf8),
              let authInfo = try? JSONSerialization.jsonObject(with: authInfoData) as? [String: Any] else {
            return nil
        }
        
        // Extract auth info
        let accessToken = authInfo["token"] as? String
        let refreshToken = authInfo["refreshToken"] as? String
        let userId = authInfo["userId"] as? String
        let apiHost = authInfo["host"] as? String
        
        // Email and username are in the nested "account" object
        var email: String? = nil
        var username: String? = nil
        
        if let account = authInfo["account"] as? [String: Any] {
            email = account["email"] as? String
            username = account["username"] as? String
        }
        
        guard accessToken != nil || email != nil else {
            return nil
        }
        
        return TraeAuthData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            userId: userId,
            apiHost: apiHost,
            username: username
        )
    }
    
    /// Fetch quota from Trae API
    func fetchQuota() async -> TraeQuotaInfo? {
        guard let authData = readAuthFromStorageJson() else { return nil }
        return await fetchQuota(authData: authData, isCurrent: { true })
    }

    /// 账号匹配完成后只使用已确认的这份凭据，不重新读取 IDE 文件。
    private func fetchQuota(authData: TraeAuthData, isCurrent: @Sendable () async -> Bool) async -> TraeQuotaInfo? {
        guard !Task.isCancelled, let accessToken = authData.accessToken else { return nil }
        
        // Use the API host from auth data or default
        let apiHost = authData.apiHost ?? "https://api-sg-central.trae.ai"
        let quotaEndpoint = "\(apiHost)/trae/api/v1/pay/user_current_entitlement_list"
        
        guard let quotaURL = URL(string: quotaEndpoint) else {
            return nil
        }
        
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.setValue("Cloud-IDE-JWT \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.trae.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://www.trae.ai/", forHTTPHeaderField: "Referer")
        
        // Request body
        let body = ["require_usage": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        // 即使凭据已匹配，先复核 CPA 会话再让携带令牌的 HTTP 请求离开本机。
        guard await isCurrent(), !Task.isCancelled else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            return parseQuotaResponse(data, authData: authData)
        } catch {
            return nil
        }
    }
    
    /// Parse quota API response
    func parseQuotaResponse(_ data: Data, authData: TraeAuthData) -> TraeQuotaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entitlementList = json["user_entitlement_pack_list"] as? [[String: Any]] else {
            return nil
        }
        
        // Find the active entitlement (status = 1, typically the free tier)
        var activeEntitlement: [String: Any]? = nil
        var resetTime: Date? = nil
        
        for entitlement in entitlementList {
            let status = entitlement["status"] as? Int ?? 0
            if status == 1 {
                activeEntitlement = entitlement
                
                // Get end time for reset
                if let baseInfo = entitlement["entitlement_base_info"] as? [String: Any],
                   let endTimestamp = baseInfo["end_time"] as? Int {
                    resetTime = Date(timeIntervalSince1970: TimeInterval(endTimestamp))
                }
                break
            }
        }
        
        guard let entitlement = activeEntitlement else {
            // 没有有效权益时不能回退到列表首项；首项可能是已到期套餐，其剩余额度不可再用。
            return nil
        }
        
        return parseEntitlement(entitlement, authData: authData, resetTime: resetTime)
    }
    
    /// Parse a single entitlement object
    private func parseEntitlement(_ entitlement: [String: Any], authData: TraeAuthData, resetTime: Date?) -> TraeQuotaInfo {
        // Get limits from entitlement_base_info.quota
        var advancedModelLimit = 0
        var autoCompletionLimit = 0
        var premiumFastLimit = 0
        var premiumSlowLimit = 0
        var planType: String? = nil
        
        if let baseInfo = entitlement["entitlement_base_info"] as? [String: Any] {
            if let quota = baseInfo["quota"] as? [String: Any] {
                advancedModelLimit = quota["advanced_model_request_limit"] as? Int ?? 0
                autoCompletionLimit = quota["auto_completion_limit"] as? Int ?? 0
                premiumFastLimit = quota["premium_model_fast_request_limit"] as? Int ?? 0
                premiumSlowLimit = quota["premium_model_slow_request_limit"] as? Int ?? 0
            }
            
            // Determine plan type from product_type
            let productType = baseInfo["product_type"] as? Int ?? 0
            switch productType {
            case 0: planType = "Free"
            case 1: planType = "Pro"
            case 2: planType = "Team"
            case 3: planType = "Builder"
            default: planType = nil
            }
        }
        
        // Get usage - use *_amount fields (not *_request_usage)
        // 权益额度和已用次数可能分开返回；缺少 usage 不能宣称该账号尚未使用任何额度。
        var advancedModelUsed: Int?
        var autoCompletionUsed: Int?
        var premiumFastUsed: Int?
        var premiumSlowUsed: Int?
        
        if let usage = entitlement["usage"] as? [String: Any] {
            advancedModelUsed = usage["advanced_model_amount"] as? Int
            autoCompletionUsed = usage["auto_completion_amount"] as? Int
            premiumFastUsed = usage["premium_model_fast_amount"] as? Int
            premiumSlowUsed = usage["premium_model_slow_amount"] as? Int
        }
        
        return TraeQuotaInfo(
            email: authData.email,
            userId: authData.userId,
            username: authData.username,
            planType: planType,
            advancedModelLimit: advancedModelLimit,
            advancedModelUsed: advancedModelUsed,
            autoCompletionLimit: autoCompletionLimit,
            autoCompletionUsed: autoCompletionUsed,
            premiumFastLimit: premiumFastLimit,
            premiumFastUsed: premiumFastUsed,
            premiumSlowLimit: premiumSlowLimit,
            premiumSlowUsed: premiumSlowUsed,
            resetTime: resetTime
        )
    }
    
    /// 保留原有邮箱、用户名、用户 ID 的优先级。只有显式导入可显示缺失身份的占位符。
    func fetchAsProviderQuota(matchingAccountKeys: Set<String>? = nil,
                              isCurrent: @Sendable () async -> Bool = { true }) async -> [String: ProviderQuotaData] {
        guard await isCurrent(), !Task.isCancelled else { return [:] }
        if readAuth == nil, await !isInstalled() { return [:] }
        // 安装探测完成后再确认许可，避免停机后读取 IDE 存储里的认证文件。
        guard await isCurrent(), !Task.isCancelled, let authData = readAuthFromStorageJson() else { return [:] }
        let identity = [authData.email, authData.username, authData.userId].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let matchingAccountKeys {
            guard let identity, identity != "Trae User", matchingAccountKeys.contains(identity) else { return [:] }
        }
        guard let info = await fetchQuota(authData: authData, isCurrent: isCurrent) else { return [:] }
        
        var models: [ModelQuota] = []
        
        let resetTimeStr: String
        if let resetTime = info.resetTime {
            resetTimeStr = ISO8601DateFormatter().string(from: resetTime)
        } else {
            resetTimeStr = ""
        }
        
        // Add Premium Fast quota (most important for users)
        if info.premiumFastLimit > 0 {
            let remaining = info.premiumFastUsed.map { max(0, info.premiumFastLimit - $0) }
            let percentage = remaining.map { min(100, max(0, Double($0) / Double(info.premiumFastLimit) * 100)) } ?? -1
            
            var quotaModel = ModelQuota(
                name: "premium-fast",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.premiumFastUsed
            quotaModel.limit = info.premiumFastLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // Add Premium Slow quota
        if info.premiumSlowLimit > 0 {
            let remaining = info.premiumSlowUsed.map { max(0, info.premiumSlowLimit - $0) }
            let percentage = remaining.map { min(100, max(0, Double($0) / Double(info.premiumSlowLimit) * 100)) } ?? -1
            
            var quotaModel = ModelQuota(
                name: "premium-slow",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.premiumSlowUsed
            quotaModel.limit = info.premiumSlowLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // Add Advanced Model quota
        if info.advancedModelLimit > 0 {
            let remaining = info.advancedModelUsed.map { max(0, info.advancedModelLimit - $0) }
            let percentage = remaining.map { min(100, max(0, Double($0) / Double(info.advancedModelLimit) * 100)) } ?? -1
            
            var quotaModel = ModelQuota(
                name: "advanced-model",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.advancedModelUsed
            quotaModel.limit = info.advancedModelLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // Add Auto Completion quota
        if info.autoCompletionLimit > 0 {
            let remaining = info.autoCompletionUsed.map { max(0, info.autoCompletionLimit - $0) }
            let percentage = remaining.map { min(100, max(0, Double($0) / Double(info.autoCompletionLimit) * 100)) } ?? -1
            
            var quotaModel = ModelQuota(
                name: "auto-completion",
                percentage: percentage,
                resetTime: resetTimeStr
            )
            quotaModel.used = info.autoCompletionUsed
            quotaModel.limit = info.autoCompletionLimit
            quotaModel.remaining = remaining
            models.append(quotaModel)
        }
        
        // 有效权益也可能缺额度数据。明确导入仍可显示该账号，已导入刷新只保留上一份有效额度。
        if models.isEmpty {
            guard matchingAccountKeys == nil else { return [:] }
            models.append(ModelQuota(
                name: "trae-usage",
                percentage: -1,
                resetTime: ""
            ))
        }
        
        let accountKey = identity ?? "Trae User"
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: info.planType
        )
        
        return [accountKey: quotaData]
    }
}
