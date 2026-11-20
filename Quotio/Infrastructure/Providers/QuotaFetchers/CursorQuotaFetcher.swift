//
//  CursorQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Cursor using stored auth tokens and cursor.com API
//  Reads auth from Cursor's state.vscdb SQLite database
//

import Foundation
import SQLite3

/// Quota data from Cursor
nonisolated struct CursorQuotaInfo: Sendable {
    let email: String?
    let membershipType: String? // pro, pro_student, free, etc.
    let subscriptionStatus: String?
    let billingCycleStart: Date?
    let billingCycleEnd: Date?
    let isUnlimited: Bool
    
    /// Plan usage (included in subscription)
    let planUsage: PlanUsage?
    /// On-demand usage (pay-as-you-go)
    let onDemandUsage: OnDemandUsage?
    
    struct PlanUsage: Sendable {
        let enabled: Bool
        let used: Int?
        let limit: Int?
        let remaining: Int?
        let totalPercentUsed: Double?
        let autoPercentUsed: Double
        let apiPercentUsed: Double
        
        var remainingPercentage: Double {
            // 字段缺失与真实零是不同状态。先采用完整剩余计数，再采用服务端百分比，最后计算差值。
            if let limit, limit > 0, let remaining {
                return min(100, max(0, Double(remaining) / Double(limit) * 100))
            }
            if let totalPercentUsed, totalPercentUsed.isFinite {
                return min(100, max(0, 100 - totalPercentUsed))
            }
            if let limit, limit > 0, let used {
                return min(100, max(0, (Double(limit) - Double(used)) / Double(limit) * 100))
            }
            return -1
        }
    }
    
    struct OnDemandUsage: Sendable {
        let enabled: Bool
        let used: Int?
        let limit: Int?
        let remaining: Int?

        /// 与套餐用量一致：缺失的已用值不能默认为零，也不能把没有上限解释为100%。
        var remainingPercentage: Double {
            guard let limit, limit > 0 else { return -1 }
            if let remaining { return min(100, max(0, Double(remaining) / Double(limit) * 100)) }
            if let used { return min(100, max(0, (Double(limit) - Double(used)) / Double(limit) * 100)) }
            return -1
        }
    }
}

/// Auth data from Cursor's state.vscdb
nonisolated struct CursorAuthData: Sendable {
    let accessToken: String?
    let refreshToken: String?
    let email: String?
    let membershipType: String?
    let subscriptionStatus: String?
    let signUpType: String?
}

/// Fetches quota from Cursor using stored auth
actor CursorQuotaFetcher {
    private var session: URLSession
    private let readAuth: (@Sendable () -> CursorAuthData?)?
    private let cursorAPIBase = "https://api2.cursor.sh"
    private let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    
    /// 生产读取原本机数据库；测试可注入独立读取与会话，验证请求发出前的账号匹配。
    init(configuration: URLSessionConfiguration? = nil, readAuth: (@Sendable () -> CursorAuthData?)? = nil) {
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
    
    /// Check if Cursor is installed
    func isInstalled() async -> Bool {
        let appPaths = [
            "/Applications/Cursor.app",
            NSString(string: "~/Applications/Cursor.app").expandingTildeInPath
        ]
        
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if Cursor auth exists
    func hasAuth() -> Bool {
        let authData = readAuthFromStateDB()
        return authData?.accessToken != nil
    }
    
    /// Read auth data from Cursor's state.vscdb
    func readAuthFromStateDB() -> CursorAuthData? {
        if let readAuth { return readAuth() }
        let expandedPath = NSString(string: stateDBPath).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }
        
        // Use URI with immutable=1 to avoid WAL file requirement
        // This prevents errors when Cursor is not running and .vscdb-wal doesn't exist
        let uri = "file://\(expandedPath)?mode=ro&immutable=1"
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }
        
        var accessToken: String?
        var refreshToken: String?
        var email: String?
        var membershipType: String?
        var subscriptionStatus: String?
        var signUpType: String?
        
        let query = "SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth/%'"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let keyPtr = sqlite3_column_text(stmt, 0),
                      let valuePtr = sqlite3_column_text(stmt, 1) else {
                    continue
                }
                
                let key = String(cString: keyPtr)
                let value = String(cString: valuePtr)
                
                switch key {
                case "cursorAuth/accessToken":
                    accessToken = value
                case "cursorAuth/refreshToken":
                    refreshToken = value
                case "cursorAuth/cachedEmail":
                    email = value
                case "cursorAuth/stripeMembershipType":
                    membershipType = value
                case "cursorAuth/stripeSubscriptionStatus":
                    subscriptionStatus = value
                case "cursorAuth/cachedSignUpType":
                    signUpType = value
                default:
                    break
                }
            }
            sqlite3_finalize(stmt)
        }
        
        guard accessToken != nil || email != nil else {
            return nil
        }
        
        return CursorAuthData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            membershipType: membershipType,
            subscriptionStatus: subscriptionStatus,
            signUpType: signUpType
        )
    }
    
    /// 用户显式读取时仍可在服务不可达时查看本地套餐。
    func fetchQuota() async -> CursorQuotaInfo? {
        guard let authData = readAuthFromStateDB() else { return nil }
        return await fetchQuota(authData: authData, allowLocalInfo: true, isCurrent: { true })
    }

    /// 请求与身份匹配必须使用同一份本机凭据；禁止在校验后再次读取数据库。
    private func fetchQuota(authData: CursorAuthData, allowLocalInfo: Bool,
                            isCurrent: @Sendable () async -> Bool) async -> CursorQuotaInfo? {
        guard !Task.isCancelled, let accessToken = authData.accessToken,
              let usageURL = URL(string: "\(cursorAPIBase)/auth/usage-summary") else { return nil }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // 读取凭据与发请求之间可能切换 CPA 会话；凭据匹配本身不延续旧会话的出站许可。
        guard await isCurrent(), !Task.isCancelled else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else {
                return allowLocalInfo ? Self.localAccountInfo(authData) : nil
            }
            return Self.parseUsageSummaryResponse(data, authData: authData, allowLocalInfo: allowLocalInfo)
        } catch {
            return allowLocalInfo ? Self.localAccountInfo(authData) : nil
        }
    }

    private nonisolated static func localAccountInfo(_ authData: CursorAuthData) -> CursorQuotaInfo {
        CursorQuotaInfo(email: authData.email, membershipType: authData.membershipType,
                        subscriptionStatus: authData.subscriptionStatus, billingCycleStart: nil,
                        billingCycleEnd: nil, isUnlimited: false, planUsage: nil, onDemandUsage: nil)
    }

    /// 明示导入兼容本地套餐；已导入刷新遇到不可解析的响应时保留原成功额度。
    nonisolated static func parseUsageSummaryResponse(_ data: Data, authData: CursorAuthData,
                                                      allowLocalInfo: Bool = true) -> CursorQuotaInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return allowLocalInfo ? localAccountInfo(authData) : nil
        }

        // Parse membership type
        let membershipType = json["membershipType"] as? String ?? authData.membershipType
        let isUnlimited = json["isUnlimited"] as? Bool ?? false
        
        // Parse billing cycle dates
        var billingCycleStart: Date? = nil
        var billingCycleEnd: Date? = nil
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let startStr = json["billingCycleStart"] as? String {
            billingCycleStart = dateFormatter.date(from: startStr) ?? ISO8601DateFormatter().date(from: startStr)
        }
        if let endStr = json["billingCycleEnd"] as? String {
            billingCycleEnd = dateFormatter.date(from: endStr) ?? ISO8601DateFormatter().date(from: endStr)
        }
        
        // Parse individual usage
        var planUsage: CursorQuotaInfo.PlanUsage? = nil
        var onDemandUsage: CursorQuotaInfo.OnDemandUsage? = nil
        
        if let individualUsage = json["individualUsage"] as? [String: Any] {
            // Parse plan usage
            if let plan = individualUsage["plan"] as? [String: Any] {
                let enabled = plan["enabled"] as? Bool ?? false
                let used = plan["used"] as? Int
                let limit = plan["limit"] as? Int
                let remaining = plan["remaining"] as? Int
                let totalPercentUsed = plan["totalPercentUsed"] as? Double
                let autoPercentUsed = plan["autoPercentUsed"] as? Double ?? 0
                let apiPercentUsed = plan["apiPercentUsed"] as? Double ?? 0
                
                planUsage = CursorQuotaInfo.PlanUsage(
                    enabled: enabled,
                    used: used,
                    limit: limit,
                    remaining: remaining,
                    totalPercentUsed: totalPercentUsed,
                    autoPercentUsed: autoPercentUsed,
                    apiPercentUsed: apiPercentUsed
                )
            }
            
            // Parse on-demand usage
            if let onDemand = individualUsage["onDemand"] as? [String: Any] {
                let enabled = onDemand["enabled"] as? Bool ?? false
                let used = onDemand["used"] as? Int
                let limit = onDemand["limit"] as? Int
                let remaining = onDemand["remaining"] as? Int
                
                onDemandUsage = CursorQuotaInfo.OnDemandUsage(
                    enabled: enabled,
                    used: used,
                    limit: limit,
                    remaining: remaining
                )
            }
        }
        
        return CursorQuotaInfo(
            email: authData.email,
            membershipType: membershipType,
            subscriptionStatus: authData.subscriptionStatus,
            billingCycleStart: billingCycleStart,
            billingCycleEnd: billingCycleEnd,
            isUnlimited: isUnlimited,
            planUsage: planUsage,
            onDemandUsage: onDemandUsage
        )
    }
    
    /// 已导入刷新只能查询同一邮箱。没有邮箱时的旧展示占位符不能授权网络请求。
    func fetchAsProviderQuota(matchingAccountKeys: Set<String>? = nil,
                              isCurrent: @Sendable () async -> Bool = { true }) async -> [String: ProviderQuotaData] {
        guard await isCurrent(), !Task.isCancelled else { return [:] }
        if readAuth == nil, await !isInstalled() { return [:] }
        // 安装探测可挂起。读令牌前重新向当前 CPA 会话确认许可。
        guard await isCurrent(), !Task.isCancelled, let authData = readAuthFromStateDB() else { return [:] }
        let identity = authData.email.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let matchingAccountKeys {
            guard let identity, identity != "Cursor User", matchingAccountKeys.contains(identity) else { return [:] }
        }
        guard let info = await fetchQuota(authData: authData, allowLocalInfo: matchingAccountKeys == nil,
                                          isCurrent: isCurrent) else { return [:] }
        
        var models: [ModelQuota] = []
        
        // Add plan usage
        if let plan = info.planUsage, plan.enabled {
            let resetTimeStr: String
            if let resetTime = info.billingCycleEnd {
                resetTimeStr = ISO8601DateFormatter().string(from: resetTime)
            } else {
                resetTimeStr = ""
            }
            
            var planModel = ModelQuota(
                name: "plan-usage",
                percentage: plan.remainingPercentage,
                resetTime: resetTimeStr
            )
            planModel.used = plan.used
            planModel.limit = plan.limit
            planModel.remaining = plan.remaining
            models.append(planModel)
        }
        
        // Add on-demand usage if enabled
        if let onDemand = info.onDemandUsage, onDemand.enabled {
            // For on-demand, show used count (no limit typically)
            let percentage = onDemand.remainingPercentage
            
            var onDemandModel = ModelQuota(
                name: "on-demand",
                percentage: percentage,
                resetTime: ""
            )
            onDemandModel.used = onDemand.used
            onDemandModel.limit = onDemand.limit
            onDemandModel.remaining = onDemand.remaining
            models.append(onDemandModel)
        }
        
        // 成功响应也可能只有 "enabled" 标记。已导入刷新至少需要实际读数或明确的不限额状态，
        // 避免用未知占位替换上次成功额度、推进成功时间。
        if matchingAccountKeys != nil, !info.isUnlimited,
           !models.contains(where: { $0.percentage >= 0 || $0.used != nil || $0.limit != nil || $0.remaining != nil }) {
            return [:]
        }
        if models.isEmpty {
            models.append(ModelQuota(
                name: "cursor-usage",
                percentage: info.isUnlimited ? 100 : -1,
                resetTime: ""
            ))
        }
        
        let accountKey = identity ?? "Cursor User"
        
        // Format plan type for display (e.g., "pro_student" -> "Pro Student")
        var planDisplayName: String? = nil
        if let membership = info.membershipType {
            planDisplayName = membership
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: planDisplayName
        )
        
        return [accountKey: quotaData]
    }
}
