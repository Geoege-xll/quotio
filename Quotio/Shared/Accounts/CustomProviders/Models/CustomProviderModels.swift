//
//  CustomProviderModels.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Models for custom AI providers (OpenAI-compatible, Claude, Gemini, Codex compatibility modes)
//

import Foundation
import SwiftUI

// MARK: - Custom Provider Type

/// Types of compatibility providers supported by CLIProxyAPI
enum CustomProviderType: String, CaseIterable, Codable, Identifiable, Sendable {
    case openaiCompatibility = "openai-compatibility"
    case claudeCompatibility = "claude-api-key"
    case geminiCompatibility = "gemini-api-key"
    case codexCompatibility = "codex-api-key"
    case glmCompatibility = "glm-api-key"
    case clinePass = "clinepass"
    case deepseekCompatibility = "deepseek-compatibility"
    case moonshotCompatibility = "moonshot-compatibility"
    case minimaxCompatibility = "minimax-compatibility"

    var id: String { rawValue }

    /// CLIProxyAPI section key. Kept separate from rawValue, which is persisted.
    var yamlSectionKey: String {
        switch self {
        case .clinePass, .deepseekCompatibility, .moonshotCompatibility, .minimaxCompatibility:
            return CustomProviderType.openaiCompatibility.rawValue
        default:
            return rawValue
        }
    }

    var displayName: String {
        switch self {
        case .openaiCompatibility: return "OpenAI Compatible"
        case .claudeCompatibility: return "Claude Compatible"
        case .geminiCompatibility: return "Gemini Compatible"
        case .codexCompatibility: return "Codex Compatible"
        case .glmCompatibility: return "GLM"
        case .clinePass: return "ClinePass"
        case .deepseekCompatibility: return "DeepSeek"
        case .moonshotCompatibility: return "Kimi"
        case .minimaxCompatibility: return "MiniMax"
        }
    }

    @MainActor
    var localizedDisplayName: String {
        switch self {
        case .openaiCompatibility: return "customProviders.type.openai".localized()
        case .claudeCompatibility: return "customProviders.type.claude".localized()
        case .geminiCompatibility: return "customProviders.type.gemini".localized()
        case .codexCompatibility: return "customProviders.type.codex".localized()
        case .glmCompatibility: return "customProviders.type.glm".localized()
        case .clinePass: return "customProviders.type.clinepass".localized()
        case .deepseekCompatibility: return "DeepSeek"
        case .moonshotCompatibility: return "Kimi"
        case .minimaxCompatibility: return "MiniMax"
        }
    }

    var description: String {
        switch self {
        case .openaiCompatibility:
            return "OpenRouter, Ollama, LM Studio, vLLM, or any OpenAI-compatible API"
        case .claudeCompatibility:
            return "Anthropic API or Claude-compatible providers"
        case .geminiCompatibility:
            return "Google Gemini API or Gemini-compatible providers"
        case .codexCompatibility:
            return "Custom Codex-compatible endpoints"
        case .glmCompatibility:
            return "Z.ai GLM Coding Plan API"
        case .clinePass:
            return "ClinePass subscription with OpenAI-compatible routing"
        case .deepseekCompatibility:
            return "DeepSeek API (deepseek-chat, deepseek-reasoner)"
        case .moonshotCompatibility:
            return "Kimi / Moonshot API (moonshot-v1, kimi-latest)"
        case .minimaxCompatibility:
            return "MiniMax API (MiniMax-Text-01, abab6.5s)"
        }
    }

    @MainActor
    var localizedDescription: String {
        switch self {
        case .openaiCompatibility: return "customProviders.type.openai.desc".localized()
        case .claudeCompatibility: return "customProviders.type.claude.desc".localized()
        case .geminiCompatibility: return "customProviders.type.gemini.desc".localized()
        case .codexCompatibility: return "customProviders.type.codex.desc".localized()
        case .glmCompatibility: return "customProviders.type.glm.desc".localized()
        case .clinePass: return "customProviders.type.clinepass.desc".localized()
        case .deepseekCompatibility: return "DeepSeek API (deepseek-chat, deepseek-reasoner)"
        case .moonshotCompatibility: return "Kimi / Moonshot API (moonshot-v1, kimi-latest)"
        case .minimaxCompatibility: return "MiniMax API (MiniMax-Text-01, abab6.5s)"
        }
    }

    var providerIconName: String {
        switch self {
        case .openaiCompatibility: return "openai"
        case .claudeCompatibility: return "claude"
        case .geminiCompatibility: return "gemini"
        case .codexCompatibility: return "openai"
        case .glmCompatibility: return "glm"
        case .clinePass: return "clinepass"
        case .deepseekCompatibility: return "deepseek"
        case .moonshotCompatibility: return "moonshot"
        case .minimaxCompatibility: return "minimax"
        }
    }

    var menuBarIconName: String {
        switch self {
        case .openaiCompatibility: return "openai-menubar"
        case .claudeCompatibility: return "claude-menubar"
        case .geminiCompatibility: return "gemini-menubar"
        case .codexCompatibility: return "openai-menubar"
        case .glmCompatibility: return "glm-menubar"
        case .clinePass: return "clinepass-menubar"
        case .deepseekCompatibility: return "deepseek-menubar"
        case .moonshotCompatibility: return "moonshot-menubar"
        case .minimaxCompatibility: return "minimax-menubar"
        }
    }

    var color: Color {
        switch self {
        case .openaiCompatibility: return Color(hex: "10A37F") ?? .green
        case .claudeCompatibility: return Color(hex: "D97706") ?? .orange
        case .geminiCompatibility: return Color(hex: "4285F4") ?? .blue
        case .codexCompatibility: return Color(hex: "10A37F") ?? .green
        case .glmCompatibility: return Color(hex: "3B82F6") ?? .blue
        case .clinePass: return Color(hex: "61A3FA") ?? .blue
        case .deepseekCompatibility: return Color(hex: "1E88E5") ?? .blue
        case .moonshotCompatibility: return Color(hex: "6366F1") ?? .indigo
        case .minimaxCompatibility: return Color(hex: "FF4D4F") ?? .red
        }
    }

    /// Whether this provider type requires a base URL
    var requiresBaseURL: Bool {
        switch self {
        case .openaiCompatibility, .codexCompatibility:
            return true
        case .claudeCompatibility, .geminiCompatibility, .glmCompatibility, .clinePass,
             .deepseekCompatibility, .moonshotCompatibility, .minimaxCompatibility:
            return false // Has default base URL
        }
    }

    /// Default base URL for this provider type (if any)
    var defaultBaseURL: String? {
        switch self {
        case .claudeCompatibility:
            return "https://api.anthropic.com"
        case .geminiCompatibility:
            return "https://generativelanguage.googleapis.com"
        case .glmCompatibility:
            return "https://api.z.ai"
        case .clinePass:
            return "https://api.cline.bot/api/v1"
        case .deepseekCompatibility:
            return "https://api.deepseek.com"
        case .moonshotCompatibility:
            return "https://api.moonshot.cn/v1"
        case .minimaxCompatibility:
            return "https://api.minimaxi.com/v1"
        case .openaiCompatibility, .codexCompatibility:
            return nil
        }
    }

    /// Whether this provider type supports model alias mapping
    var supportsModelMapping: Bool {
        switch self {
        case .openaiCompatibility, .claudeCompatibility, .clinePass,
             .deepseekCompatibility, .moonshotCompatibility, .minimaxCompatibility:
            return true
        case .geminiCompatibility, .codexCompatibility, .glmCompatibility:
            return false
        }
    }

    /// Whether this provider type supports custom headers.
    /// CLIProxyAPI accepts a `headers` map for `openai-compatibility` providers (provider level)
    /// and for `claude-api-key`, `gemini-api-key`, and `codex-api-key` entries (per key).
    /// GLM, ClinePass, and dedicated mainstream providers are excluded:
    /// they are managed API-key services with fixed authentication.
    var supportsCustomHeaders: Bool {
        switch self {
        case .openaiCompatibility, .claudeCompatibility, .geminiCompatibility, .codexCompatibility:
            return true
        case .glmCompatibility, .clinePass,
             .deepseekCompatibility, .moonshotCompatibility, .minimaxCompatibility:
            return false
        }
    }
}

// MARK: - API Key Entry

/// A single API key with optional proxy configuration
struct CustomAPIKeyEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var apiKey: String
    var proxyURL: String?
    /// 可选字段兼容旧 JSON。未显式编辑时保持 nil，v8 合并保留磁盘中的既有 weight。
    var weight: Int?
    /// 仅属于本地编辑意图，不发送到 CPA。即使数值恢复到曾经保存过的值，也可识别为新修改。
    var weightRevision: UUID? = nil
    
    init(id: UUID = UUID(), apiKey: String, proxyURL: String? = nil, weight: Int? = nil) {
        self.id = id
        self.apiKey = apiKey
        self.proxyURL = proxyURL
        self.weight = weight
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case apiKey = "api-key"
        case proxyURL = "proxy-url"
        case weight
        case weightRevision = "weight-revision"
    }
    
    /// Masked API key for display (shows first 8 and last 4 characters)
    var maskedKey: String {
        guard apiKey.count > 12 else {
            return String(repeating: "•", count: apiKey.count)
        }
        let prefix = String(apiKey.prefix(8))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    /// 按不可变的密钥条目 UUID 应用草稿；删除／重排条目不会把某个账号的权重写到另一个账号。
    /// 未出现的草稿维持原值；留空保留 CPA 现值，显式输入 1 才表示恢复默认分配比例。
    static func applyingRoutingWeights(_ keys: [Self], drafts: [UUID: String], observed: [UUID: Int] = [:]) throws -> [Self] {
        try keys.map { key in
            guard let text = drafts[key.id] else { return key }
            // 打开编辑器观察到的值不等于写入意图，焦点回写同一文案也不能接管手工权重。
            if let baseline = observed[key.id] ?? key.weight,
               text.trimmingCharacters(in: .whitespacesAndNewlines) == String(baseline) {
                return key
            }
            var result = key
            result.weight = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : try CPAAccountWeight.parse(text)
            result.weightRevision = UUID()
            return result
        }
    }
}

// MARK: - Model Mapping

/// Maps an upstream model name to a local alias with optional thinking budget
struct ModelMapping: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var alias: String
    var thinkingBudget: String?
    
    init(id: UUID = UUID(), name: String, alias: String, thinkingBudget: String? = nil) {
        self.id = id
        self.name = name
        self.alias = alias
        self.thinkingBudget = thinkingBudget
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, alias
        case thinkingBudget = "thinking-budget"
    }
    
    var effectiveAlias: String {
        guard let budget = thinkingBudget, !budget.isEmpty else { return alias }
        return "\(alias)(\(budget))"
    }
}

// MARK: - Custom Header

/// A custom HTTP header sent with requests to the upstream provider
struct CustomHeader: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case id, key, value
    }

    /// Non-alphanumeric characters allowed in an HTTP header field name (RFC 7230 token)
    private static let validNameSpecials = Set("!#$%&'*+-.^_`|~")

    /// RFC 7230 optional whitespace: the only characters stripped when normalizing.
    /// Deliberately narrower than `CharacterSet.whitespaces` (which also covers
    /// U+00A0 and friends) so normalization never silently rewrites a value that
    /// validation would otherwise reject.
    private static let optionalWhitespace = CharacterSet(charactersIn: " \t")

    /// Whether the given string is a valid HTTP header field name (RFC 7230 token: ASCII letters, digits, and select punctuation)
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || validNameSpecials.contains(character))
        }
    }

    /// Whether the given string is a valid HTTP header field value (RFC 7230 `field-value`:
    /// horizontal tab, space, and visible US-ASCII).
    ///
    /// CR/LF and other control characters must be rejected rather than escaped: CFNetwork
    /// either drops such a header or folds it into the previous one, Go's outbound HTTP
    /// stack refuses to send it, and a literal newline inside a YAML scalar is folded into
    /// a space when CLIProxyAPI parses the config back — silently changing the secret.
    /// Non-ASCII is rejected because its wire encoding is not interoperable (RFC 9110 §5.5).
    static func isValidValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value <= 0x7E)
        }
    }

    /// This header in canonical form: surrounding RFC 7230 optional whitespace removed
    /// from both the name and the value.
    var normalized: CustomHeader {
        CustomHeader(
            id: id,
            key: key.trimmingCharacters(in: Self.optionalWhitespace),
            value: value.trimmingCharacters(in: Self.optionalWhitespace)
        )
    }

    /// The canonical representation of an editor-entered header list: every entry
    /// normalized, entries without a name dropped.
    ///
    /// This is the single form that may be persisted, validated, emitted into the
    /// CLIProxyAPI config, or attached to a `URLRequest` — see `CustomProvider.effectiveHeaders`.
    static func canonicalized(_ headers: [CustomHeader]) -> [CustomHeader] {
        headers.map(\.normalized).filter { !$0.key.isEmpty }
    }

    /// Validation errors for a canonical header list (as produced by `canonicalized(_:)`).
    /// Each problem is reported at most once so the alert stays readable.
    static func validationErrors(in headers: [CustomHeader]) -> [String] {
        var errors: [String] = []
        var seenNames = Set<String>()
        var reportedInvalidName = false
        var reportedInvalidValue = false
        var reportedDuplicateName = false

        for header in headers {
            if !isValidName(header.key), !reportedInvalidName {
                errors.append("customProviders.error.headerNameInvalid".localizedStatic())
                reportedInvalidName = true
            }
            if !isValidValue(header.value), !reportedInvalidValue {
                errors.append("customProviders.error.headerValueInvalid".localizedStatic())
                reportedInvalidValue = true
            }
            if !seenNames.insert(header.key.lowercased()).inserted, !reportedDuplicateName {
                errors.append("customProviders.error.headerNameDuplicate".localizedStatic())
                reportedDuplicateName = true
            }
        }

        return errors
    }
}

extension URLRequest {
    /// Attach a canonical custom header list to this request.
    ///
    /// Both outgoing request paths in the provider editor (Fetch Models and the mandatory
    /// pre-save connection test) go through here, so neither can drift from the header set
    /// that is validated, persisted, and written to the CLIProxyAPI config.
    /// - Parameter headers: headers already normalized via `CustomHeader.canonicalized(_:)`
    ///   or read from `CustomProvider.effectiveHeaders`.
    mutating func applyCustomHeaders(_ headers: [CustomHeader]) {
        for header in headers {
            setValue(header.value, forHTTPHeaderField: header.key)
        }
    }
}

// MARK: - Custom Provider

/// A user-defined custom provider configuration
struct CustomProvider: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var type: CustomProviderType
    var baseURL: String
    var prefix: String?
    var apiKeys: [CustomAPIKeyEntry]
    var models: [ModelMapping]
    var headers: [CustomHeader]  // Custom HTTP headers (types where supportsCustomHeaders is true)
    var limitToSelectedModels: Bool
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        type: CustomProviderType,
        baseURL: String = "",
        prefix: String? = nil,
        apiKeys: [CustomAPIKeyEntry] = [],
        models: [ModelMapping] = [],
        headers: [CustomHeader] = [],
        limitToSelectedModels: Bool = true,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL.isEmpty ? (type.defaultBaseURL ?? "") : baseURL
        self.prefix = prefix
        self.apiKeys = apiKeys
        self.models = models
        self.headers = headers
        self.limitToSelectedModels = limitToSelectedModels
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, prefix
        case baseURL = "base-url"
        case apiKeys = "api-keys"
        case models, headers
        case limitToSelectedModels = "limit-to-selected-models"
        case isEnabled = "is-enabled"
        case createdAt = "created-at"
        case updatedAt = "updated-at"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(CustomProviderType.self, forKey: .type)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
        apiKeys = try container.decodeIfPresent([CustomAPIKeyEntry].self, forKey: .apiKeys) ?? []
        models = try container.decodeIfPresent([ModelMapping].self, forKey: .models) ?? []
        headers = try container.decodeIfPresent([CustomHeader].self, forKey: .headers) ?? []
        limitToSelectedModels = try container.decodeIfPresent(Bool.self, forKey: .limitToSelectedModels) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(prefix, forKey: .prefix)
        try container.encode(apiKeys, forKey: .apiKeys)
        try container.encode(models, forKey: .models)
        try container.encode(headers, forKey: .headers)
        try container.encode(limitToSelectedModels, forKey: .limitToSelectedModels)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
    
    /// Validate the provider configuration
    func validate() -> [String] {
        var errors: [String] = []
        
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Provider name is required")
        }
        
        if type.requiresBaseURL && baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Base URL is required for \(type.displayName)")
        }
        
        if !baseURL.isEmpty {
            if let url = URL(string: baseURL), url.scheme == nil || url.host == nil {
                errors.append("Invalid base URL format")
            }
        }
        
        if apiKeys.isEmpty {
            errors.append("At least one API key is required")
        }
        
        for (index, key) in apiKeys.enumerated() {
            if key.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("API key #\(index + 1) is empty")
            }
        }

        if type == .clinePass, apiKeys.count != 1 {
            errors.append("clinepass.error.singleKey".localizedStatic())
        }

        if type == .clinePass, models.isEmpty {
            errors.append("clinepass.error.modelsRequired".localizedStatic())
        }

        if type.supportsCustomHeaders {
            // 校验规范化后的请求头；CPA 8 局部配置同步、模型读取与连接测试共用这组值，
            // 避免保存前校验与最终发送的请求头不一致。
            errors.append(contentsOf: CustomHeader.validationErrors(in: CustomHeader.canonicalized(headers)))
        }

        return errors
    }
    
    /// Check if provider is valid
    var isValid: Bool {
        validate().isEmpty
    }

    /// 提供商请求头的统一出口：CPA 8 局部配置同步、保存前连接测试和模型目录请求均读取此值，
    /// 确保界面校验、持久化数据和实际请求使用相同的有效请求头。
    ///
    /// 先去除首尾可选空白和无名称条目，再过滤不符合 HTTP 规则的名称与值。
    /// `validate()` 会拒绝保存这些无效值；这里仍保留防御过滤，避免历史存储中尚未经新校验的
    /// 提供商生成非法请求或无效配置，不为兼容旧数据而放宽线上请求的边界。
    var effectiveHeaders: [CustomHeader] {
        guard type.supportsCustomHeaders else { return [] }
        return CustomHeader.canonicalized(headers).filter {
            CustomHeader.isValidName($0.key) && CustomHeader.isValidValue($0.value)
        }
    }
}

// MARK: - Custom Provider Test Error

enum CustomProviderTestError: LocalizedError {
    case noAPIKey
    case invalidURL
    case invalidResponse
    case unauthorized
    case endpointNotFound
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key provided"
        case .invalidURL:
            return "Invalid base URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "API key is invalid or unauthorized"
        case .endpointNotFound:
            return "Models endpoint not found at this URL"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

