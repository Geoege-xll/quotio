//
//  AgentModels.swift
//  Quotio - CLI Agent Configuration Models
//

import Foundation
import SwiftUI

// MARK: - CLI Agent Types

nonisolated enum CLIAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case pi = "pi"
    case claudeCode = "claude-code"
    case codexCLI = "codex"
    case ampCLI = "amp"
    case openCode = "opencode"
    case factoryDroid = "factory-droid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: return "Pi"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .ampCLI: return "Amp CLI"
        case .openCode: return "OpenCode"
        case .factoryDroid: return "Factory Droid"
        }
    }

    var description: String {
        switch self {
        case .pi: return "Pi coding agent with the official CLIProxyAPI provider"
        case .claudeCode: return "Anthropic's official CLI for Claude models"
        case .codexCLI: return "OpenAI's Codex CLI for GPT-5 models"
        case .ampCLI: return "Sourcegraph's Amp coding assistant"
        case .openCode: return "The open source AI coding agent"
        case .factoryDroid: return "Factory's AI coding agent"
        }
    }

    var configType: AgentConfigType {
        switch self {
        case .pi: return .file
        case .claudeCode: return .both
        case .codexCLI: return .file
        case .ampCLI: return .both
        case .openCode: return .file
        case .factoryDroid: return .file
        }
    }

    var binaryNames: [String] {
        switch self {
        case .pi: return ["pi"]
        case .claudeCode: return ["claude"]
        case .codexCLI: return ["codex"]
        case .ampCLI: return ["amp"]
        case .openCode: return ["opencode", "oc"]
        case .factoryDroid: return ["droid", "factory-droid"]
        }
    }

    var configPaths: [String] {
        switch self {
        case .pi: return PiAgentSupport.configURLs(homeDirectory: FileManager.default.homeDirectoryForCurrentUser).map(\.path)
        case .claudeCode: return ["~/.claude/settings.json"]
        case .codexCLI: return ["~/.codex/config.toml", "~/.codex/auth.json"]
        case .ampCLI: return ["~/.config/amp/settings.json", "~/.local/share/amp/secrets.json"]
        case .openCode: return ["~/.config/opencode/opencode.json"]
        case .factoryDroid: return ["~/.factory/config.json"]
        }
    }

    var docsURL: URL? {
        switch self {
        // 文档地址使用固定且有效的 URL，与其他智能体的属性类型保持一致。
        case .pi: return URL(string: "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent")!
        case .claudeCode: return URL(string: "https://docs.anthropic.com/en/docs/claude-code")
        case .codexCLI: return URL(string: "https://github.com/openai/codex")
        case .ampCLI: return URL(string: "https://ampcode.com/manual")
        case .openCode: return URL(string: "https://github.com/sst/opencode")
        case .factoryDroid: return URL(string: "https://docs.factory.ai/welcome")
        }
    }

    var systemIcon: String {
        switch self {
        case .pi: return "terminal.fill"
        case .claudeCode: return "brain.head.profile"
        case .codexCLI: return "chevron.left.forwardslash.chevron.right"
        case .ampCLI: return "bolt.fill"
        case .openCode: return "terminal"
        case .factoryDroid: return "cpu"
        }
    }

    var color: Color {
        switch self {
        // 十六进制颜色解析为可选值，提供系统橙色兜底以满足非可选返回类型。
        case .pi: return Color(hex: "F97316") ?? .orange
        case .claudeCode: return Color(hex: "D97706") ?? .orange
        case .codexCLI: return Color(hex: "10A37F") ?? .green
        case .ampCLI: return Color(hex: "FF5543") ?? .red
        case .openCode: return Color(hex: "8B5CF6") ?? .purple
        case .factoryDroid: return Color(hex: "238636") ?? .green
        }
    }
}

// MARK: - Configuration Types

nonisolated enum AgentConfigType: String, Codable, Sendable {
    case environment = "env"
    case file = "file"
    case both = "both"
}

// MARK: - Configuration Setup Mode

/// Determines whether to use proxy or default provider endpoints
nonisolated enum ConfigurationSetup: String, CaseIterable, Identifiable, Codable, Sendable {
    case proxy = "proxy"
    case defaultSetup = "default"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proxy: return "agents.setup.proxy".localizedStatic()
        case .defaultSetup: return "agents.setup.default".localizedStatic()
        }
    }

    var description: String {
        switch self {
        case .proxy: return "agents.setup.proxy.desc".localizedStatic()
        case .defaultSetup: return "agents.setup.default.desc".localizedStatic()
        }
    }

    var icon: String {
        switch self {
        case .proxy: return "arrow.triangle.branch"
        case .defaultSetup: return "arrow.right"
        }
    }
}

// MARK: - Configuration Mode

nonisolated enum ConfigurationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = "automatic"
    case manual = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual: return "Manual"
        }
    }

    var icon: String {
        switch self {
        case .automatic: return "gearshape.2"
        case .manual: return "doc.text"
        }
    }

    var description: String {
        switch self {
        case .automatic: return "Directly update config files and shell profile"
        case .manual: return "View and copy configuration manually"
        }
    }
}

nonisolated enum ConfigStorageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case jsonOnly = "json"
    case shellOnly = "shell"
    case both = "both"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .jsonOnly: return "doc.text"
        case .shellOnly: return "terminal"
        case .both: return "square.stack"
        }
    }
}

// MARK: - Model Slots

nonisolated enum ModelSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Opus (High Intelligence)"
        case .sonnet: return "Sonnet (Balanced)"
        case .haiku: return "Haiku (Fast)"
        }
    }

    var envSuffix: String {
        rawValue.uppercased()
    }
}

// MARK: - Codex Reasoning Effort

/// Reasoning effort accepted by Codex CLI's `model_reasoning_effort` key in
/// `~/.codex/config.toml`.
///
/// Codex treats this key as an **open** set. `ReasoningEffort` in
/// `codex-rs/protocol/src/openai_models.rs` names `none`, `minimal`, `low`,
/// `medium`, `high`, `xhigh`, `max` and `ultra`, and its hand-written
/// `FromStr` maps every other non-empty string to `ReasoningEffort::Custom`;
/// only the empty string is rejected. `custom` mirrors that escape hatch so a
/// value Quotio does not know is round-tripped verbatim instead of being
/// silently replaced.
nonisolated enum CodexReasoningEffort: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
    /// A valid Codex value Quotio does not have a named case for.
    /// Never produced for a value that maps to a named case — see `init(rawValue:)`.
    case custom(String)

    /// Fails only for the empty string, which Codex itself rejects with
    /// "reasoning_effort must not be empty".
    init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "minimal": self = .minimal
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh": self = .xhigh
        case "max": self = .max
        case "ultra": self = .ultra
        case "": return nil
        default: self = .custom(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .none: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        case .ultra: return "ultra"
        case .custom(let value): return value
        }
    }

    /// The named values Quotio offers in the picker, ordered by effort.
    /// A `custom` value read from the user's config is offered alongside these.
    static let allCases: [CodexReasoningEffort] = [
        .none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra
    ]

    var id: String { rawValue }

    /// Default effort, matching the value Quotio has historically written.
    static let defaultEffort: CodexReasoningEffort = .high

    var displayName: String {
        if case .custom(let value) = self {
            return String.localizedStringWithFormat(
                "agents.reasoningEffort.custom".localizedStatic(),
                value
            )
        }
        return "agents.reasoningEffort.\(rawValue)".localizedStatic()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CodexReasoningEffort(rawValue: rawValue) ?? .defaultEffort
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Available Models for Routing

nonisolated struct AvailableModel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let isDefault: Bool

    var displayName: String {
        name.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static let defaultModels: [ModelSlot: AvailableModel] = [
        .opus: AvailableModel(id: "opus", name: "gemini-claude-opus-4-6-thinking", provider: "openai", isDefault: true),
        .sonnet: AvailableModel(id: "sonnet", name: "gemini-claude-sonnet-4-5", provider: "openai", isDefault: true),
        .haiku: AvailableModel(id: "haiku", name: "gemini-3-flash-preview", provider: "openai", isDefault: true)
    ]

    static let allModels: [AvailableModel] = [
        // Claude models
        AvailableModel(id: "gemini-claude-opus-4-6-thinking", name: "gemini-claude-opus-4-6-thinking", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-opus-4-5-thinking", name: "gemini-claude-opus-4-5-thinking", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-sonnet-4-5", name: "gemini-claude-sonnet-4-5", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-sonnet-4-5-thinking", name: "gemini-claude-sonnet-4-5-thinking", provider: "anthropic", isDefault: false),
        // Gemini models
        AvailableModel(id: "gemini-3-pro-preview", name: "gemini-3-pro-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-3-pro-image-preview", name: "gemini-3-pro-image-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-3-flash-preview", name: "gemini-3-flash-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-flash-lite", name: "gemini-2.5-flash-lite", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-computer-use-preview-10-2025", name: "gemini-2.5-computer-use-preview-10-2025", provider: "google", isDefault: false),
        // GPT models
        AvailableModel(id: "gpt-5.3-codex", name: "gpt-5.3-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.2", name: "gpt-5.2", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.2-codex", name: "gpt-5.2-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1", name: "gpt-5.1", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex", name: "gpt-5.1-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex-max", name: "gpt-5.1-codex-max", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex-mini", name: "gpt-5.1-codex-mini", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5", name: "gpt-5", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5-codex-mini", name: "gpt-5-codex-mini", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-oss-120b-medium", name: "gpt-oss-120b-medium", provider: "openai", isDefault: false),
    ]
}

// MARK: - Agent Status

nonisolated struct AgentStatus: Identifiable, Sendable {
    let agent: CLIAgent
    var installed: Bool
    var configured: Bool
    var binaryPath: String?
    var version: String?
    var lastConfigured: Date?

    var id: String { agent.id }

    /// 模型只提供本地化键；由视图按当前语言解析，切换语言时不会留下硬编码英文状态。
    var statusLocalizationKey: String {
        if !installed {
            return "agents.notInstalled"
        } else if configured {
            return "agents.configured"
        } else {
            return "agents.installed"
        }
    }

    var statusColor: Color {
        if !installed {
            return .secondary
        } else if configured {
            return .green
        } else {
            return .orange
        }
    }
}

// MARK: - Agent Configuration

nonisolated struct AgentConfiguration: Codable, Sendable {
    let agent: CLIAgent
    var modelSlots: [ModelSlot: String]
    var proxyURL: String
    var apiKey: String
    var useOAuth: Bool
    var setupMode: ConfigurationSetup
    /// Reasoning effort written to Codex CLI's `model_reasoning_effort`.
    /// Only used when `agent == .codexCLI`.
    var codexReasoningEffort: CodexReasoningEffort

    /// Codex 的独立备用模型沿用原生成器的取值，不再借用 Claude 的 Sonnet 默认槽。
    /// 已保存的模型和用户在界面中的选择始终优先，不因刷新模型列表而被替换。
    static let defaultCodexModel = "gpt-5-codex"
    static let defaultClaudeMaxContextTokens = 200_000
    static let defaultClaudeAutoCompactPercentage = 90

    /// 独立保存 Claude 的启动模型；可选字段兼容没有该键的旧 Codable 数据。
    /// nil 时跟随 Opus 槽，保持旧版首次配置的实际行为，而不是复制槽中的模型 ID。
    var claudeDefaultModel: String?

    /// 显示名称与请求 ID 分开存储；可选字典兼容旧配置，缺省或留空时展示实际模型 ID。
    var claudeModelDisplayNames: [ModelSlot: String]?

    /// Claude Code 的普通上下文窗口。任一模型槽位启用 1M 时，生成器临时写入 1,000,000，
    /// 但不改写这里的用户选择，以便关闭 1M 后恢复该值。
    var claudeMaxContextTokens: Int
    /// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` 的用户选择，必须为 1...100。
    var claudeAutoCompactPercentage: Int
    /// `DISABLE_AUTO_COMPACT=1` 只在启用时写入；关闭时移除 Quotio 管理的键。
    var claudeDisableAutoCompact: Bool
    /// 每个 Claude 角色独立决定是否在最终请求模型 ID 追加 `[1m]`。
    var claudeModel1M: [ModelSlot: Bool]

    enum CodingKeys: String, CodingKey {
        case agent, modelSlots, proxyURL, apiKey, useOAuth, setupMode
        case codexReasoningEffort, claudeDefaultModel, claudeModelDisplayNames
        case claudeMaxContextTokens, claudeAutoCompactPercentage
        case claudeDisableAutoCompact, claudeModel1M
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(CLIAgent.self, forKey: .agent)
        modelSlots = try container.decode([ModelSlot: String].self, forKey: .modelSlots)
        proxyURL = try container.decode(String.self, forKey: .proxyURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        useOAuth = try container.decode(Bool.self, forKey: .useOAuth)
        setupMode = try container.decode(ConfigurationSetup.self, forKey: .setupMode)
        codexReasoningEffort = try container.decodeIfPresent(CodexReasoningEffort.self, forKey: .codexReasoningEffort) ?? .defaultEffort
        claudeDefaultModel = try container.decodeIfPresent(String.self, forKey: .claudeDefaultModel)
        claudeModelDisplayNames = try container.decodeIfPresent([ModelSlot: String].self, forKey: .claudeModelDisplayNames)
        let decodedContextTokens = try container.decodeIfPresent(Int.self, forKey: .claudeMaxContextTokens)
        claudeMaxContextTokens = decodedContextTokens.map { $0 > 0 ? $0 : Self.defaultClaudeMaxContextTokens }
            ?? Self.defaultClaudeMaxContextTokens
        let decodedCompactPercentage = try container.decodeIfPresent(Int.self, forKey: .claudeAutoCompactPercentage)
        claudeAutoCompactPercentage = decodedCompactPercentage.map { (1...100).contains($0) ? $0 : Self.defaultClaudeAutoCompactPercentage }
            ?? Self.defaultClaudeAutoCompactPercentage
        claudeDisableAutoCompact = try container.decodeIfPresent(Bool.self, forKey: .claudeDisableAutoCompact) ?? false
        claudeModel1M = try container.decodeIfPresent([ModelSlot: Bool].self, forKey: .claudeModel1M) ?? [:]
    }

    func claudeDisplayName(for slot: ModelSlot) -> String {
        let name = claudeModelDisplayNames?[slot]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let model = modelSlots[slot]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? (AvailableModel.defaultModels[slot]?.name ?? "") : model
    }

    func usesClaude1MContext(for slot: ModelSlot) -> Bool {
        claudeModel1M[slot] ?? false
    }

    var effectiveClaudeMaxContextTokens: Int {
        ModelSlot.allCases.contains { usesClaude1MContext(for: $0) }
            ? 1_000_000
            : claudeMaxContextTokens
    }

    var claudeModel: String {
        get {
            let model = claudeDefaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return model.isEmpty ? ModelSlot.opus.rawValue : model
        }
        set { claudeDefaultModel = newValue }
    }

    /// 为兼容已保存的 AgentConfiguration，单模型仍存放在原来的 sonnet 字段中。
    /// 通过专用属性统一处理空值，避免界面显示的模型与生成器的备用值不一致。
    var codexModel: String {
        get {
            let model = modelSlots[.sonnet]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return model.isEmpty ? Self.defaultCodexModel : model
        }
        set { modelSlots[.sonnet] = newValue }
    }

    init(agent: CLIAgent, proxyURL: String, apiKey: String, setupMode: ConfigurationSetup = .proxy) {
        self.agent = agent
        self.proxyURL = proxyURL
        self.apiKey = apiKey
        self.useOAuth = false
        self.setupMode = setupMode
        self.codexReasoningEffort = .defaultEffort
        self.claudeMaxContextTokens = Self.defaultClaudeMaxContextTokens
        self.claudeAutoCompactPercentage = Self.defaultClaudeAutoCompactPercentage
        self.claudeDisableAutoCompact = false
        self.claudeModel1M = [:]
        // Pi 必须使用 CPA 实际返回的模型，不继承 Claude 槽默认值。
        if agent == .pi {
            self.modelSlots = [:]
        } else if agent == .codexCLI {
            self.modelSlots = [.sonnet: Self.defaultCodexModel]
        } else {
            self.modelSlots = Dictionary(uniqueKeysWithValues: ModelSlot.allCases.compactMap { slot in
                AvailableModel.defaultModels[slot].map { (slot, $0.name) }
            })
        }
    }

    /// 先应用该代理自己的默认值，再覆盖已保存的选择，两个初始化入口使用同一规则。
    init(agent: CLIAgent, proxyURL: String, apiKey: String, setupMode: ConfigurationSetup = .proxy, savedModelSlots: [ModelSlot: String]) {
        self.init(agent: agent, proxyURL: proxyURL, apiKey: apiKey, setupMode: setupMode)
        for (slot, model) in savedModelSlots {
            self.modelSlots[slot] = model
        }
    }

}

// MARK: - Raw Configuration Output (for Manual Mode)

nonisolated struct RawConfigOutput: Sendable {
    let format: ConfigFormat
    let content: String
    let filename: String?
    let targetPath: String?
    let instructions: String

    enum ConfigFormat: String, Sendable {
        case shellExport = "shell"
        case toml = "toml"
        case json = "json"
        case yaml = "yaml"
    }
}

// MARK: - Configuration Result

nonisolated struct AgentConfigResult: Sendable {
    let success: Bool
    let configType: AgentConfigType
    let mode: ConfigurationMode
    var configPath: String?
    var authPath: String?
    var shellConfig: String?
    var rawConfigs: [RawConfigOutput]
    var instructions: String
    var modelsConfigured: Int
    var error: String?
    var backupPath: String?

    static func success(
        type: AgentConfigType,
        mode: ConfigurationMode,
        configPath: String? = nil,
        authPath: String? = nil,
        shellConfig: String? = nil,
        rawConfigs: [RawConfigOutput] = [],
        instructions: String,
        modelsConfigured: Int = 3,
        backupPath: String? = nil
    ) -> AgentConfigResult {
        AgentConfigResult(
            success: true,
            configType: type,
            mode: mode,
            configPath: configPath,
            authPath: authPath,
            shellConfig: shellConfig,
            rawConfigs: rawConfigs,
            instructions: instructions,
            modelsConfigured: modelsConfigured,
            error: nil,
            backupPath: backupPath
        )
    }

    static func failure(error: String) -> AgentConfigResult {
        AgentConfigResult(
            success: false,
            configType: .environment,
            mode: .automatic,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "",
            modelsConfigured: 0,
            error: error,
            backupPath: nil
        )
    }
}

// MARK: - Shell Profile

nonisolated enum ShellType: String, CaseIterable, Sendable {
    case zsh = "zsh"
    case bash = "bash"
    case fish = "fish"

    var profilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .zsh:
            if let zdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"], !zdotdir.isEmpty {
                return "\(zdotdir)/.zshrc"
            }
            let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
            let xdgZshDir = "\(xdgConfigHome)/zsh"
            if FileManager.default.fileExists(atPath: xdgZshDir) {
                return "\(xdgZshDir)/.zshrc"
            }
            return "\(home)/.zshrc"
        case .bash: return "\(home)/.bashrc"
        case .fish: return "\(home)/.config/fish/config.fish"
        }
    }

    var exportPrefix: String {
        switch self {
        case .zsh, .bash: return "export"
        case .fish: return "set -gx"
        }
    }
}

// MARK: - Connection Test Result

nonisolated struct ConnectionTestResult: Sendable {
    let success: Bool
    let message: String
    let latencyMs: Int?
    let modelResponded: String?
}
