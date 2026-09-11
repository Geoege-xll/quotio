//
//  Models.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import SwiftUI

// MARK: - Provider Types

nonisolated enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case qwen = "qwen"
    case iflow = "iflow"
    case antigravity = "antigravity"
    case vertex = "vertex"
    case kiro = "kiro"
    case copilot = "github-copilot"
    case cursor = "cursor"
    case factoryDroid = "factory-droid"
    case devin = "devin"
    case grok = "grok"
    case openRouter = "openrouter"
    case amp = "amp"
    case trae = "trae"
    case glm = "glm"
    case warp = "warp"
    case clinePass = "clinepass"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .qwen: return "Qwen Code"
        case .iflow: return "iFlow"
        case .antigravity: return "Antigravity"
        case .vertex: return "Vertex AI"
        case .kiro: return "Kiro"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        case .factoryDroid: return "Factory Droid"
        case .devin: return "Devin"
        case .grok: return "Grok"
        case .openRouter: return "OpenRouter"
        case .amp: return "Amp"
        case .trae: return "Trae"
        case .glm: return "Z.ai"
        case .warp: return "Warp"
        case .clinePass: return "ClinePass"
        }
    }
    
    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .qwen: return "cloud"
        case .iflow: return "arrow.triangle.branch"
        case .antigravity: return "wand.and.stars"
        case .vertex: return "cube"
        case .kiro: return "cloud.fill"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .factoryDroid: return "cpu"
        case .devin: return "bolt.horizontal.circle"
        case .grok: return "xmark.circle"
        case .openRouter: return "point.3.connected.trianglepath.dotted"
        case .amp: return "bolt.fill"
        case .trae: return "cursorarrow.rays"
        case .glm: return "brain"
        case .warp: return "terminal.fill"
        case .clinePass: return "cpu"
        }
    }
    
    /// Logo file name in ProviderIcons asset catalog
    var logoAssetName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "openai"
        case .qwen: return "qwen"
        case .iflow: return "iflow"
        case .antigravity: return "antigravity"
        case .vertex: return "vertex"
        case .kiro: return "kiro"
        case .copilot: return "copilot"
        case .cursor: return "cursor"
        case .factoryDroid: return "factory-droid"
        case .devin: return "devin"
        case .grok: return "grok"
        case .openRouter: return "openrouter"
        case .amp: return "amp"
        case .trae: return "trae"
        case .glm: return "glm"
        case .warp: return "warp"
        case .clinePass: return "clinepass"
        }
    }
    
    var color: Color {
        switch self {
        case .claude: return Color(hex: "D97706") ?? .orange
        case .codex: return Color(hex: "10A37F") ?? .green
        case .qwen: return Color(hex: "7C3AED") ?? .purple
        case .iflow: return Color(hex: "06B6D4") ?? .cyan
        case .antigravity: return Color(hex: "EC4899") ?? .pink
        case .vertex: return Color(hex: "EA4335") ?? .red
        case .kiro: return Color(hex: "9046FF") ?? .purple
        case .copilot: return Color(hex: "238636") ?? .green
        case .cursor: return Color(hex: "00D4AA") ?? .teal
        case .factoryDroid: return Color(hex: "238636") ?? .green
        case .devin: return Color(hex: "6C5CE7") ?? .purple
        case .grok: return .primary
        case .openRouter: return Color(hex: "6B5CFF") ?? .purple
        case .amp: return Color(hex: "FF5543") ?? .red
        case .trae: return Color(hex: "00B4D8") ?? .cyan
        case .glm: return Color(hex: "3B82F6") ?? .blue
        case .warp: return Color(hex: "01E5FF") ?? .cyan
        case .clinePass: return Color(hex: "61A3FA") ?? .blue
        }
    }
    
    var oauthEndpoint: String {
        switch self {
        case .claude: return "/anthropic-auth-url"
        case .codex: return "/codex-auth-url"
        case .qwen: return "/qwen-auth-url"
        case .iflow: return "/iflow-auth-url"
        case .antigravity: return "/antigravity-auth-url"
        case .vertex: return ""
        case .kiro: return ""  // Uses CLI-based auth like Copilot
        case .copilot: return ""
        case .cursor: return ""  // Uses browser session
        case .factoryDroid, .devin, .grok, .openRouter, .amp: return ""
        case .trae: return ""  // Uses browser session
        case .glm: return ""
        case .warp: return ""
        case .clinePass: return ""
        }
    }
    
    /// Short symbol for menu bar display
    var menuBarSymbol: String {
        switch self {
        case .claude: return "C"
        case .codex: return "O"
        case .qwen: return "Q"
        case .iflow: return "F"
        case .antigravity: return "A"
        case .vertex: return "V"
        case .kiro: return "K"
        case .copilot: return "CP"
        case .cursor: return "CR"
        case .factoryDroid: return "FD"
        case .devin: return "D"
        case .grok: return "X"
        case .openRouter: return "OR"
        case .amp: return "AM"
        case .trae: return "TR"
        case .glm: return "G"
        case .warp: return "W"
        case .clinePass: return "CL"
        }
    }
    
    /// Menu bar icon asset name (nil if should use SF Symbol fallback)
    var menuBarIconAsset: String? {
        switch self {
        case .claude: return "claude-menubar"
        case .codex: return "openai-menubar"
        case .qwen: return "qwen-menubar"
        case .copilot: return "copilot-menubar"
        // These don't have custom icons, use SF Symbols
        case .antigravity: return "antigravity-menubar"
        case .kiro: return "kiro-menubar"
        case .iflow: return "iflow-menubar"
        case .vertex: return "vertex-menubar"
        case .cursor: return "cursor-menubar"
        case .amp: return "amp-menubar"
        case .factoryDroid, .devin, .grok, .openRouter: return nil
        case .trae: return "trae-menubar"
        case .glm: return "glm-menubar"
        case .warp: return "warp-menubar"
        case .clinePass: return "clinepass-menubar"
        }
    }
    
    /// Whether this provider supports quota tracking in quota-only mode
    var supportsQuotaOnlyMode: Bool {
        switch self {
        case .claude, .codex, .cursor, .factoryDroid, .antigravity, .copilot, .devin, .grok, .openRouter, .amp, .trae, .glm, .warp, .kiro, .clinePass:
            return true
        case .qwen, .iflow, .vertex:
            return false
        }
    }
    
    /// Whether this provider uses browser cookies for auth
    var usesBrowserAuth: Bool {
        switch self {
        case .cursor, .trae:
            return true
        default:
            return false
        }
    }
    
    /// Whether this provider uses CLI commands for quota
    var usesCLIQuota: Bool {
        switch self {
        case .claude, .codex:
            return true
        default:
            return false
        }
    }

    /// Whether this provider's accounts are imported from a local IDE database by the
    /// explicit "Scan for IDEs" flow (issue #29) instead of being authenticated inside
    /// Quotio. Such an account owns no Quotio credential, so it exists only as imported
    /// quota data and deleting that data deletes the account (issue #213).
    ///
    /// Derived from the existing traits rather than listing cases again, so a new IDE
    /// edition only has to opt into `usesBrowserAuth` / `supportsManualAuth` to inherit
    /// the same import and delete behaviour.
    var isImportedFromLocalIDE: Bool {
        usesBrowserAuth && !supportsManualAuth
    }

    /// Map provider to CLI agent (if applicable)
    var cliAgent: CLIAgent? {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codexCLI
        default: return nil
        }
    }
    
    /// Whether this provider can be added manually (via OAuth, CLI login, or file import)
    /// Cursor, Trae, Windsurf are excluded because they only read from local app databases
    /// GLM and ClinePass are excluded because they should only be added via Custom Providers
    var supportsManualAuth: Bool {
        switch self {
        case .cursor, .trae, .devin, .grok, .glm, .clinePass:
            return false  // API-key providers: Custom Providers; Cursor/Trae: local app databases
        default:
            return true
        }
    }

    /// Whether this provider uses API key authentication
    var usesAPIKeyAuth: Bool {
        switch self {
        case .glm, .warp, .clinePass, .factoryDroid, .openRouter, .amp:
            return true
        default:
            return false
        }
    }
    
    /// Whether this provider is quota-tracking only (not a real provider that can route requests)
    var isQuotaTrackingOnly: Bool {
        switch self {
        case .cursor, .trae, .factoryDroid, .devin, .grok, .openRouter, .amp, .warp:
            return true  // Only for tracking usage, not a provider
        default:
            return false
        }
    }

    /// Whether the Local Proxy dashboard can route this provider through its setup flow.
    var supportsLocalProxySetup: Bool {
        supportsManualAuth && !isQuotaTrackingOnly
    }
}

/// Stable identity for one account in the provider quota dictionary.
nonisolated struct QuotaAccountID: Hashable, Sendable {
    let provider: AIProvider
    let accountKey: String
}

// MARK: - Quota Metric Presentation

/// Optional typed value for quota rows that are not plain percentages.
/// Existing snapshots omit this field and continue to render through ModelQuota.percentage.
nonisolated enum QuotaMetricUnit: String, Codable, Sendable, Equatable {
    case usd
    case credits
    case requests
    case searches

    func format(_ value: Double) -> String {
        let locale = LanguageManager.staticLocale
        switch self {
        case .usd:
            return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        case .credits:
            return String(format: "quota.metric.unit.credits".localizedStatic(), locale: locale, value)
        case .requests:
            return String(format: "quota.metric.unit.requests".localizedStatic(), locale: locale, value)
        case .searches:
            return String(format: "quota.metric.unit.searches".localizedStatic(), locale: locale, value)
        }
    }
}

nonisolated enum QuotaAmountSemantics: String, Codable, Sendable, Equatable {
    case balance
    case spent
}

nonisolated enum QuotaMetricPresentation: Codable, Sendable, Equatable {
    case progress(used: Double, limit: Double, unit: QuotaMetricUnit)
    case amount(value: Double, unit: QuotaMetricUnit, semantics: QuotaAmountSemantics)
    case status(text: String)
}

// MARK: - Proxy Status

nonisolated struct ProxyStatus: Codable {
    var running: Bool = false
    var port: UInt16 = 8317
    
    var endpoint: String {
        "http://localhost:\(port)/v1"
    }
}

// MARK: - Auth File (from Management API)

extension String {
    nonisolated var codexFilenameKey: String {
        var key = self
        if key.hasPrefix("codex-") {
            key = String(key.dropFirst("codex-".count))
        }
        if key.hasSuffix(".json") {
            key = String(key.dropLast(".json".count))
        }
        return key
    }

    nonisolated var copilotFilenameKey: String? {
        guard hasPrefix("github-copilot-") else { return nil }
        var key = String(dropFirst("github-copilot-".count))
        if key.hasSuffix(".json") {
            key = String(key.dropLast(".json".count))
        }
        return key.isEmpty ? nil : key
    }
}

/// 列表响应只保留配额路由所需的非秘密字段，不把 metadata 或令牌原文存入账号模型。
/// 这样即使 CPA 禁止下载凭据，配额请求仍可使用列表给出的项目、组织、套餐和用户身份。
nonisolated struct AuthFileQuotaMetadata: Codable, Hashable, Sendable {
    var projectID: String?
    var accountID: String?
    var plan: String?
    var userID: String?

    init(projectID: String? = nil, accountID: String? = nil, plan: String? = nil, userID: String? = nil) {
        self.projectID = projectID
        self.accountID = accountID
        self.plan = plan
        self.userID = userID
    }

    init(from decoder: Decoder) throws {
        self = try Self.read(from: decoder, depth: 0)
    }

    private static func read(from decoder: Decoder, depth: Int) throws -> Self {
        guard depth < 6 else { return Self() }
        let values = try decoder.container(keyedBy: AuthFileMetadataKey.self)
        var result = Self(
            projectID: values.quotaString(["project_id", "projectId", "projectID", "project", "cloudaicompanionProject"]),
            accountID: values.quotaString(["chatgpt_account_id", "chatgptAccountId", "account_id", "accountId", "accountID"]),
            plan: values.quotaString(["chatgpt_plan_type", "chatgptPlanType", "plan_type", "planType", "plan", "account_type", "accountType"]),
            userID: values.quotaString(["sub", "subject", "user_id", "userId", "userID"])
        )

        // Google 也可能把项目包装为对象；对象中的 id 是项目 ID，不能误作用户 ID。
        if result.projectID == nil {
            for key in ["project", "cloudaicompanionProject"] {
                if let nested = try? values.nestedContainer(keyedBy: AuthFileMetadataKey.self, forKey: AuthFileMetadataKey(key)) {
                    result.projectID = nested.quotaString(["id", "project_id", "projectId"])
                    if result.projectID != nil { break }
                }
            }
        }

        // 优先使用显式列表字段，再补嵌套元数据，最后补 JWT 声明；绝不保存完整凭据树。
        for key in ["quota_metadata", "metadata", "attributes", "oauth", "user", "https://api.openai.com/auth", "tokens"] {
            let codingKey = AuthFileMetadataKey(key)
            guard values.contains(codingKey),
                  let nestedDecoder = try? values.superDecoder(forKey: codingKey),
                  var nested = try? read(from: nestedDecoder, depth: depth + 1) else { continue }
            if key == "oauth" || key == "user" {
                // 只有明确的用户容器允许读取 id；顶层 id 是认证文件身份，不能混用。
                if nested.userID == nil,
                   let user = try? nestedDecoder.container(keyedBy: AuthFileMetadataKey.self) {
                    nested.userID = user.quotaString(["id"])
                }
            }
            result.fillMissing(from: nested)
        }

        for key in ["id_token", "idToken", "access_token", "accessToken"] {
            let codingKey = AuthFileMetadataKey(key)
            if let nestedDecoder = try? values.superDecoder(forKey: codingKey),
               let claims = try? read(from: nestedDecoder, depth: depth + 1) {
                result.fillMissing(from: claims)
            } else if let token = values.quotaString([key]), let claims = tokenClaims(token) {
                result.fillMissing(from: claims)
            }
        }
        return result
    }

    private mutating func fillMissing(from other: Self) {
        projectID = projectID ?? other.projectID
        accountID = accountID ?? other.accountID
        plan = plan ?? other.plan
        userID = userID ?? other.userID
    }

    private static func tokenClaims(_ token: String) -> Self? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        // 仅提取路由声明，不将未校验 JWT 当作认证依据；实际认证仍由 CPA 的 authIndex 完成。
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

private nonisolated struct AuthFileMetadataKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == AuthFileMetadataKey {
    /// CPA 部分版本将 auth_index 或声明 ID 编码成数字；布尔值不能被误当成账号标识。
    /// 此方法只读取当前解码容器，不访问界面或共享状态；显式解除扩展的默认主线程隔离，
    /// 让后台认证列表解析保持同步，并符合非隔离 Codable 数据模型的调用约束。
    nonisolated func quotaString(_ names: [String]) -> String? {
        for name in names {
            let key = AuthFileMetadataKey(name)
            if let value = try? decode(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let value = try? decode(Int64.self, forKey: key) {
                return String(value)
            } else if let value = try? decode(UInt64.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }
}

nonisolated struct AuthFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let label: String?
    let status: String
    let statusMessage: String?
    let disabled: Bool
    let unavailable: Bool
    let runtimeOnly: Bool?
    let source: String?
    let path: String?
    let email: String?
    let accountType: String?
    let account: String?
    let authIndex: String?
    let createdAt: String?
    let updatedAt: String?
    let lastRefresh: String?
    var quotaMetadata: AuthFileQuotaMetadata = .init()

    var quotaProjectID: String? { quotaMetadata.projectID }
    var quotaAccountID: String? { quotaMetadata.accountID }
    var quotaPlan: String? { quotaMetadata.plan }
    var quotaUserID: String? { quotaMetadata.userID }

    /// 供页面和状态栏显示，始终与机器查找键分离，不把 authIndex 暴露成账号名。
    var quotaDisplayName: String {
        [email, label, account, name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? name
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, provider, label, status, disabled, unavailable, source, path, email, account
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case accountType = "account_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRefresh = "last_refresh"
        case quotaMetadata = "quota_metadata"
    }
    
    var providerType: AIProvider? {
        // Handle "copilot" alias for "github-copilot"
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProvider == "copilot" {
            return .copilot
        }
        if ["xai", "x-ai", "grok"].contains(normalizedProvider) { return .grok }
        return AIProvider(rawValue: normalizedProvider)
    }
    
    var quotaLookupKey: String {
        if providerType == .codex {
            // Codex proxy filenames encode the concrete subscription variant,
            // so filename-based keys keep same-email Plus/Team accounts distinct.
            return name.codexFilenameKey
        }
        if providerType == .copilot,
           let key = CopilotQuotaFetcher.canonicalAccountKey(filename: name, username: account) {
            // Same canonical rule as CopilotQuotaFetcher / DirectAuthFileService (#404):
            // identity field first, `github-copilot-*` filename suffix otherwise.
            return key
        }
        // 同邮箱可对应多个团队、项目或凭据。CPA 请求按 authIndex 路由，因此缓存必须
        // 同时区分文件名和 authIndex；长度前缀避免文件名中的分隔符造成键碰撞。
        let index = authIndex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "cpa:\(name.utf8.count):\(name):\(index.utf8.count):\(index)"
    }

    /// 仅供调用方在确认一对一关联时迁移旧选择/原生缓存；不能逐项无条件回退，否则仍会串号。
    var legacyQuotaLookupKeys: [String] {
        var key = name
        if key.hasPrefix("github-copilot-") {
            key = String(key.dropFirst("github-copilot-".count))
        }
        if key.hasSuffix(".json") {
            key = String(key.dropLast(".json".count))
        }
        var seen = Set<String>()
        return [email, account, key, name].compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var menuBarAccountKey: String {
        let key = quotaLookupKey
        return key.isEmpty ? name : key
    }
    
    var isReady: Bool {
        status == "ready" && !disabled && !unavailable
    }
    
    var statusColor: Color {
        switch status {
        case "ready": return disabled ? .gray : .green
        case "cooling": return .orange
        case "error": return .red
        default: return .gray
        }
    }

    /// Extracts a human-readable message from the status_message field.
    /// The field may contain raw JSON error blobs from providers (e.g., Antigravity/Google).
    var humanReadableStatus: String? {
        guard let msg = statusMessage, !msg.isEmpty else { return nil }

        // If it looks like JSON, try to parse it
        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        // Already a plain string
        return msg
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(quotaLookupKey)
        hasher.combine(quotaMetadata)
        hasher.combine(email)
        hasher.combine(account)
        hasher.combine(disabled)
        hasher.combine(status)
    }

    static func == (lhs: AuthFile, rhs: AuthFile) -> Bool {
        lhs.id == rhs.id &&
        lhs.quotaLookupKey == rhs.quotaLookupKey &&
        lhs.quotaMetadata == rhs.quotaMetadata &&
        lhs.email == rhs.email &&
        lhs.account == rhs.account &&
        lhs.disabled == rhs.disabled &&
        lhs.status == rhs.status
    }
}

extension AuthFile {
    /// 自定义解码放在扩展中，保留既有成员初始化器，避免影响预览和旧调用方构造账号。
    /// 扩展不会自动继承类型的非隔离上下文，因此显式声明此纯值初始化器为 nonisolated，
    /// 满足 Decodable 的同步非隔离要求，避免把后台账号解码错误地绑定到主线程。
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let aliases = try decoder.container(keyedBy: AuthFileMetadataKey.self)
        name = try values.decode(String.self, forKey: .name)
        id = aliases.quotaString(["id"]) ?? name
        provider = aliases.quotaString(["provider", "type"]) ?? ""
        label = try values.decodeIfPresent(String.self, forKey: .label)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "ready"
        statusMessage = aliases.quotaString(["status_message", "statusMessage"])
        disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        unavailable = try values.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        runtimeOnly = try values.decodeIfPresent(Bool.self, forKey: .runtimeOnly)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        accountType = aliases.quotaString(["account_type", "accountType"])
        account = aliases.quotaString(["account"])
        authIndex = aliases.quotaString(["auth_index", "authIndex"])
        createdAt = aliases.quotaString(["created_at", "createdAt"])
        updatedAt = aliases.quotaString(["updated_at", "updatedAt"])
        lastRefresh = aliases.quotaString(["last_refresh", "lastRefresh"])
        quotaMetadata = (try? AuthFileQuotaMetadata(from: decoder)) ?? .init()
    }
}

nonisolated struct AuthFilesResponse: Codable, Sendable {
    let files: [AuthFile]
}

// MARK: - API Keys (Proxy Service Auth)

nonisolated struct APIKeysResponse: Codable, Sendable {
    let apiKeys: [String]
    
    enum CodingKeys: String, CodingKey {
        case apiKeys = "api-keys"
    }
}

// MARK: - Usage Statistics

nonisolated struct UsageStats: Codable, Sendable {
    let usage: UsageData?
    let failedRequests: Int?
    
    enum CodingKeys: String, CodingKey {
        case usage
        case failedRequests = "failed_requests"
    }
}

nonisolated struct UsageData: Codable, Sendable {
    let totalRequests: Int?
    let successCount: Int?
    let failureCount: Int?
    let totalTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
    
    var successRate: Double {
        guard let total = totalRequests, total > 0, let success = successCount else { return 0 }
        return Double(success) / Double(total) * 100
    }
}

// MARK: - OAuth Flow

nonisolated struct OAuthURLResponse: Codable, Sendable {
    let status: String
    let url: String?
    let state: String?
    let error: String?
}

nonisolated struct OAuthStatusResponse: Codable, Sendable {
    let status: String
    let error: String?
}

// MARK: - App Config

nonisolated struct AppConfig: Codable {
    var host: String = ""
    var port: UInt16 = 8317
    var authDir: String = "~/.cli-proxy-api"
    var proxyURL: String = ""
    var apiKeys: [String] = []
    var debug: Bool = false
    var loggingToFile: Bool = false
    var usageStatisticsEnabled: Bool = true
    var requestRetry: Int = 3
    var maxRetryInterval: Int = 30
    var wsAuth: Bool = false
    var routing: RoutingConfig = RoutingConfig()
    var quotaExceeded: QuotaExceededConfig = QuotaExceededConfig()
    var remoteManagement: RemoteManagementConfig = RemoteManagementConfig()
    
    enum CodingKeys: String, CodingKey {
        case host, port, debug, routing
        case authDir = "auth-dir"
        case proxyURL = "proxy-url"
        case apiKeys = "api-keys"
        case loggingToFile = "logging-to-file"
        case usageStatisticsEnabled = "usage-statistics-enabled"
        case requestRetry = "request-retry"
        case maxRetryInterval = "max-retry-interval"
        case wsAuth = "ws-auth"
        case quotaExceeded = "quota-exceeded"
        case remoteManagement = "remote-management"
    }
}

nonisolated struct RoutingConfig: Codable {
    var strategy: String = "round-robin"
}

nonisolated struct QuotaExceededConfig: Codable {
    var switchProject: Bool = true
    var switchPreviewModel: Bool = true
    
    enum CodingKeys: String, CodingKey {
        case switchProject = "switch-project"
        case switchPreviewModel = "switch-preview-model"
    }
}

nonisolated struct RemoteManagementConfig: Codable {
    var allowRemote: Bool = false
    var secretKey: String = ""
    var disableControlPanel: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case allowRemote = "allow-remote"
        case secretKey = "secret-key"
        case disableControlPanel = "disable-control-panel"
    }
}

// MARK: - Log Entry

nonisolated struct LogEntry: Identifiable {
    let id: UUID
    let timestamp: Date?
    let level: LogLevel
    let message: String

    /// 无法识别的时间保持为空，不使用客户端接收时间冒充服务端事件时间。
    /// 增量刷新时允许复用标识，避免选中项和阅读位置随每次轮询重置。
    init(id: UUID = UUID(), timestamp: Date?, level: LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
    
    enum LogLevel: String {
        case info, warn, error, debug, unknown
        
        var color: Color {
            switch self {
            case .info: return .primary
            case .warn: return .orange
            case .error: return .red
            case .debug: return .gray
            case .unknown: return .secondary
            }
        }
    }
}

// MARK: - Navigation

nonisolated enum NavigationPage: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case usageStatistics = "Usage Statistics"
    case callAnalytics = "Call Analytics"
    case quota = "Quota"
    case providers = "Providers"
    case agents = "Agents"
    case agentManagement = "Agent Management"
    case apiKeys = "API Keys"
    case logs = "Logs"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .usageStatistics: return "chart.xyaxis.line"
        case .callAnalytics: return "function"
        case .quota: return "chart.bar.fill"
        case .providers: return "person.2.badge.key"
        case .agents: return "terminal"
        case .agentManagement: return "slider.horizontal.2.square.on.square"
        case .apiKeys: return "key.horizontal"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }

    static let workspace = NavigationPage.agentManagement
}

// MARK: - Color Extension

nonisolated extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Formatting Helpers

extension Int {
    /// 纯数字格式化不依赖 UI 状态，允许统计展示值在非主 actor 上复用相同的紧凑口径。
    /// 自动在 K -> M -> G 之间进位换算，达到 1G (10^9) 时转换为 G 单位并精简冗余尾零。
    nonisolated var formattedCompact: String {
        let absValue = abs(self)
        let sign = self < 0 ? "-" : ""
        if absValue >= 1_000_000_000 {
            let value = Double(absValue) / 1_000_000_000
            return sign + String(format: "%.1fG", value).replacingOccurrences(of: ".0G", with: "G")
        } else if absValue >= 1_000_000 {
            let value = Double(absValue) / 1_000_000
            return sign + String(format: "%.1fM", value).replacingOccurrences(of: ".0M", with: "M")
        } else if absValue >= 1_000 {
            let value = Double(absValue) / 1_000
            return sign + String(format: "%.1fK", value).replacingOccurrences(of: ".0K", with: "K")
        }
        return "\(self)"
    }
}

// MARK: - Proxy URL Validation

nonisolated enum ProxyURLValidationResult: Equatable {
    case valid
    case empty
    case invalidScheme
    case invalidURL
    case missingHost
    case missingPort
    case invalidPort
    
    var isValid: Bool {
        self == .valid || self == .empty
    }
    
    var localizationKey: String? {
        switch self {
        case .valid, .empty:
            return nil
        case .invalidScheme:
            return "settings.proxy.error.invalidScheme"
        case .invalidURL:
            return "settings.proxy.error.invalidURL"
        case .missingHost:
            return "settings.proxy.error.missingHost"
        case .missingPort:
            return "settings.proxy.error.missingPort"
        case .invalidPort:
            return "settings.proxy.error.invalidPort"
        }
    }
}

nonisolated enum ProxyURLValidator {
    static let supportedSchemes = ["socks5", "http", "https"]
    
    static func validate(_ urlString: String) -> ProxyURLValidationResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            return .empty
        }
        
        let hasValidScheme = supportedSchemes.contains { scheme in
            trimmed.lowercased().hasPrefix("\(scheme)://")
        }
        
        guard hasValidScheme else {
            return .invalidScheme
        }
        
        guard let url = URL(string: trimmed) else {
            return .invalidURL
        }
        
        guard let host = url.host, !host.isEmpty else {
            return .missingHost
        }
        
        // socks5 requires explicit port
        if url.scheme?.lowercased() == "socks5" {
            guard let port = url.port else {
                return .missingPort
            }
            guard port >= 1 && port <= 65535 else {
                return .invalidPort
            }
        } else if let port = url.port {
            guard port >= 1 && port <= 65535 else {
                return .invalidPort
            }
        }
        
        return .valid
    }
    
    static func sanitize(_ urlString: String) -> String {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        
        return trimmed
    }
}
