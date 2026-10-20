import Foundation
import SwiftUI

// 认证目录模型与其私有解码辅助作为一个完整单元迁移，防止为分文件扩大私有 API。
// 文件名身份、UTF-8 长度键、数字索引与旧字段兼容均保持原样；元数据不保存完整凭据。
// AuthFile 的自定义解码继续放在扩展中，保留已有成员初始化器和 nonisolated 约束。

// MARK: - Auth File Cooldown (from Management API)

/// CPA v8 凭据与模型的未过期冷却视图。
nonisolated struct AuthFileCooldown: Codable, Hashable, Sendable {
    let scope: String // "credential" or "model"
    let modelKey: String?
    let reason: String
    let retryAt: String?
    let remainingSeconds: Int64
    let backoffLevel: Int?
    let httpStatus: Int?
    /// 只保存该次响应的到期观测，不持有时钟或任务。优先使用服务端绝对时间；
    /// 旧服务缺少 retry_at 时按本次读取时间加剩余秒数计算，避免倒计时永久停在快照值。
    private let deadline: Date

    enum CodingKeys: String, CodingKey {
        case scope
        case modelKey = "model_key"
        case reason
        case retryAt = "retry_at"
        case remainingSeconds = "remaining_seconds"
        case backoffLevel = "backoff_level"
        case httpStatus = "http_status"
    }

    init(
        scope: String,
        modelKey: String? = nil,
        reason: String = "quota",
        retryAt: String? = nil,
        remainingSeconds: Int64 = 0,
        backoffLevel: Int? = nil,
        httpStatus: Int? = nil,
        observedAt: Date = Date()
    ) {
        self.scope = scope
        self.modelKey = modelKey
        self.reason = reason
        self.retryAt = retryAt
        self.remainingSeconds = remainingSeconds
        self.backoffLevel = backoffLevel
        self.httpStatus = httpStatus
        self.deadline = retryAt.flatMap { value in
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                ?? (try? Date.ISO8601FormatStyle().parse(value))
        } ?? observedAt.addingTimeInterval(TimeInterval(max(0, remainingSeconds)))
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scope: try values.decode(String.self, forKey: .scope),
                  modelKey: try values.decodeIfPresent(String.self, forKey: .modelKey),
                  reason: try values.decode(String.self, forKey: .reason),
                  retryAt: try values.decodeIfPresent(String.self, forKey: .retryAt),
                  remainingSeconds: try values.decode(Int64.self, forKey: .remainingSeconds),
                  backoffLevel: try values.decodeIfPresent(Int.self, forKey: .backoffLevel),
                  httpStatus: try values.decodeIfPresent(Int.self, forKey: .httpStatus))
    }

    func secondsRemaining(at date: Date) -> Int64 {
        guard remainingSeconds > 0 else { return 0 }
        let seconds = deadline.timeIntervalSince(date)
        guard seconds > 0 else { return 0 }
        return seconds >= Double(Int64.max) ? Int64.max : Int64(ceil(seconds))
    }

    /// 账号行、汇总横幅和批量重置共用同一份纯投影，调用方传入可见 UI 的时间。
    static func active(_ values: [Self]?, at date: Date) -> [Self] {
        (values ?? []).compactMap { value in
            let remaining = value.secondsRemaining(at: date)
            guard remaining > 0 else { return nil }
            return Self(scope: value.scope, modelKey: value.modelKey, reason: value.reason,
                        retryAt: value.retryAt, remainingSeconds: remaining,
                        backoffLevel: value.backoffLevel, httpStatus: value.httpStatus, observedAt: date)
        }
    }

    static func summary(_ active: [Self]) -> String? {
        guard let first = active.first else { return nil }
        let remaining = first.remainingSeconds
        let text: String
        if remaining >= 3600 { text = "\(remaining / 3600)h\((remaining % 3600) / 60)m" }
        else if remaining >= 60 {
            text = "\(remaining / 60)m" + (remaining % 60 > 0 ? "\(remaining % 60)s" : "")
        } else { text = "\(remaining)s" }
        return first.modelKey.flatMap { $0.isEmpty ? nil : "\($0) (\(text))" } ?? text
    }

    static func tooltip(_ active: [Self]) -> String? {
        guard !active.isEmpty else { return nil }
        let items = active.map { value in
            let scope = value.scope == "model" ? (value.modelKey ?? "model") : "credentials.cooldown.scopeAll".localizedStatic()
            return "\(scope): \(value.remainingSeconds)s (\(value.reason))"
        }
        return "credentials.cooldown.activeTooltip".localizedStatic() + "\n" + items.joined(separator: "\n")
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
    /// Copilot 专用路由主机；可选以兼容旧 CPA 列表和额度缓存。
    var githubHost: String? = nil

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
        let hostKeys = ["github_host", "githubHost", "host"]
        for name in hostKeys where values.contains(AuthFileMetadataKey(name)) {
            // 主机与通用 ID 的容错规则不同：显式 null、非字符串、空值或任何别名冲突
            // 都必须形成失败身份，不能被“缺字段兼容 github.com”悄悄吞掉。
            let host = (try? values.decode(String.self, forKey: AuthFileMetadataKey(name)))
                .flatMap { GitHubHost($0) }?.value ?? "invalid-host"
            if let previous = result.githubHost, previous != host { result.githubHost = "invalid-host" }
            else { result.githubHost = host }
        }

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
        // 嵌套元数据与顶层同样需要一致；不能用优先级掩盖显式错误或两个合法企业的冲突。
        if let otherHost = other.githubHost {
            if let host = githubHost, host != otherHost { githubHost = "invalid-host" }
            else { githubHost = otherHost }
        }
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
    let weight: Int?
    let priority: Int?
    let cooldowns: [AuthFileCooldown]?

    var quotaProjectID: String? { quotaMetadata.projectID }
    var quotaAccountID: String? { quotaMetadata.accountID }
    var quotaPlan: String? { quotaMetadata.plan }
    var quotaUserID: String? { quotaMetadata.userID }

    /// 供页面和状态栏显示，始终与机器查找键分离，不把 authIndex 暴露成账号名。
    var quotaDisplayName: String {
        [email, label, account, name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? name
    }

    /// 展示和批量重置均使用当前时刻投影，不能把上次读取的 remaining_seconds 当永久状态。
    var activeCooldowns: [AuthFileCooldown] { AuthFileCooldown.active(cooldowns, at: Date()) }
    var hasActiveCooldown: Bool { !activeCooldowns.isEmpty }
    var cooldownSummary: String? { AuthFileCooldown.summary(activeCooldowns) }
    var cooldownTooltip: String? { AuthFileCooldown.tooltip(activeCooldowns) }

    init(
        id: String,
        name: String,
        provider: String,
        label: String? = nil,
        status: String = "ready",
        statusMessage: String? = nil,
        disabled: Bool = false,
        unavailable: Bool = false,
        runtimeOnly: Bool? = nil,
        source: String? = nil,
        path: String? = nil,
        email: String? = nil,
        accountType: String? = nil,
        account: String? = nil,
        authIndex: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        lastRefresh: String? = nil,
        quotaMetadata: AuthFileQuotaMetadata = .init(),
        weight: Int? = nil,
        priority: Int? = nil,
        cooldowns: [AuthFileCooldown]? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.label = label
        self.status = status
        self.statusMessage = statusMessage
        self.disabled = disabled
        self.unavailable = unavailable
        self.runtimeOnly = runtimeOnly
        self.source = source
        self.path = path
        self.email = email
        self.accountType = accountType
        self.account = account
        self.authIndex = authIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRefresh = lastRefresh
        self.quotaMetadata = quotaMetadata
        self.weight = weight
        self.priority = priority
        self.cooldowns = cooldowns
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
        case weight, priority, cooldowns
    }
    
    var providerType: AIProvider? {
        AIProvider.fromAuthProvider(provider)
    }
    
    var quotaLookupKey: String {
        if providerType == .codex {
            // Codex proxy filenames encode the concrete subscription variant,
            // so filename-based keys keep same-email Plus/Team accounts distinct.
            return name.codexFilenameKey
        }
        if providerType == .copilot, let host = GitHubHost.saved(quotaMetadata.githubHost),
           let key = CopilotQuotaFetcher.canonicalAccountKey(filename: name, username: account, host: host) {
            // Same canonical rule as CopilotQuotaFetcher / DirectAuthFileService (#404):
            // identity field first, `github-copilot-*` filename suffix otherwise.
            return key
        }
        // 同邮箱可对应多个团队、项目或凭据。CPA 请求按 authIndex 路由，因此缓存必须
        // 同时区分文件名和 authIndex；长度前缀避免文件名中的分隔符造成键碰撞。
        return Self.cpaQuotaLookupKey(name: name, authIndex: authIndex)
    }

    /// 统一构造 CPA 路由槽位，供当前索引与旧无索引缓存的关联规则共同使用。
    /// 文件名允许包含中文或冒号，长度必须使用 UTF-8 字节数，不能用字符数猜测。
    static func cpaQuotaLookupKey(name: String, authIndex: String?) -> String {
        let index = authIndex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "cpa:\(name.utf8.count):\(name):\(index.utf8.count):\(index)"
    }

    /// 仅供调用方在确认一对一关联时迁移旧选择/原生缓存；不能逐项无条件回退，否则仍会串号。
    var legacyQuotaLookupKeys: [String] {
        if providerType == .copilot, quotaMetadata.githubHost != nil,
           GitHubHost.saved(quotaMetadata.githubHost)?.isGitHubCom != true {
            // 旧裸账号键无法证明所属企业；只迁移同一完整文件的来源别名。
            return [name, name.hasSuffix(".json") ? String(name.dropLast(5)) : name]
        }
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
    
    /// CPA v8 的可调度状态为 active；ready 保留给已有目录和旧本地快照。
    /// 两者都必须同时排除禁用／不可用记录，不能只看状态字符串或改变服务端原始值。
    var isReady: Bool {
        (status == "ready" || status == "active") && !disabled && !unavailable
    }
    
    var statusColor: Color {
        switch status {
        // 额度页沿用账号管理的语义，active 不能落入默认的灰色状态。
        case "ready", "active": return disabled ? .gray : .green
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

    /// CPA 会把单个模型的 429 冷却也汇总为认证文件的 error 状态。
    /// 只有同时确认 HTTP 429 与 QUOTA_EXHAUSTED，并取得上游明确给出的模型名时，
    /// 才把通用 Error 改写为“模型额度冷却”；其他认证错误仍保留原始状态，避免误报。
    var quotaCooldownModel: String? {
        guard status == "error", let statusMessage,
              let data = statusMessage.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              error["code"] as? Int == 429,
              let details = error["details"] as? [[String: Any]],
              let quotaDetail = details.first(where: { $0["reason"] as? String == "QUOTA_EXHAUSTED" }),
              let metadata = quotaDetail["metadata"] as? [String: Any],
              let model = metadata["model"] as? String,
              !model.isEmpty else { return nil }
        return model
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(quotaLookupKey)
        hasher.combine(quotaMetadata)
        hasher.combine(email)
        hasher.combine(account)
        hasher.combine(disabled)
        hasher.combine(status)
        // 错误状态不变但上游原因或重试时间变化时，SwiftUI 仍须重新绘制详情。
        hasher.combine(statusMessage)
        hasher.combine(weight)
        hasher.combine(priority)
        hasher.combine(cooldowns)
    }

    static func == (lhs: AuthFile, rhs: AuthFile) -> Bool {
        lhs.id == rhs.id &&
        lhs.quotaLookupKey == rhs.quotaLookupKey &&
        lhs.quotaMetadata == rhs.quotaMetadata &&
        lhs.email == rhs.email &&
        lhs.account == rhs.account &&
        lhs.disabled == rhs.disabled &&
        lhs.status == rhs.status &&
        lhs.statusMessage == rhs.statusMessage &&
        lhs.weight == rhs.weight &&
        lhs.priority == rhs.priority &&
        lhs.cooldowns == rhs.cooldowns
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
        weight = try values.decodeIfPresent(Int.self, forKey: .weight)
        priority = try values.decodeIfPresent(Int.self, forKey: .priority)
        cooldowns = try values.decodeIfPresent([AuthFileCooldown].self, forKey: .cooldowns)
    }
}

nonisolated struct AuthFilesResponse: Codable, Sendable {
    let files: [AuthFile]
}
