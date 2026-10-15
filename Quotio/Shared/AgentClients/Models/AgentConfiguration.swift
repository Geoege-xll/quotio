//
//  AgentConfiguration.swift
//  Quotio
//

import Foundation

// 客户端配置草稿在此保持单一完整声明，存储属性、自定义解码、默认值和派生规则暂不拆分。
// 扁平 CodingKeys、模型槽、Claude 菜单与名称、子代理及 1M 选择都属于历史兼容协议，不能因文件整理重排为嵌套配置。
// 新配置继续使用原生菜单；旧 curated、append、external 菜单和 Codex sonnet 字段存储规则完整保留。
// 显式 nonisolated 保证同步解码与后台配置操作不被应用 Target 的默认 MainActor 隔离改变。

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

    /// 直接指定的启动模型独立声明 1M；跟随角色时只读取角色的开关，不改写这份独立选择。
    /// 与模型 ID 相同的其他角色无关，避免同一模型在不同用途下意外共享上下文设置。
    var claudeDefaultModel1M: Bool

    /// 显示名称与请求 ID 分开存储；缺省或留空时保留角色名，避免同一模型用于多个角色时无法区分。
    var claudeModelDisplayNames: [ModelSlot: String]?
    /// 模型 ID 到展示平台的回填提示，仅供目录不可用时保留已保存的“平台/模型”说明。
    /// 以实际 ID 为键，切换角色目标后不会把旧模型的平台套用到另一个模型。
    var claudeModelPlatformHints: [String: String]

    /// Claude Code 的普通上下文窗口。1M 由各模型自己的后缀声明，不能提升这个全局值，
    /// 否则未开启 1M 的其他自定义模型也会被当成大上下文模型。
    var claudeMaxContextTokens: Int
    /// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` 的用户选择，必须为 1...100。
    var claudeAutoCompactPercentage: Int
    /// `DISABLE_AUTO_COMPACT=1` 只在启用时写入；关闭时移除 Quotio 管理的键。
    var claudeDisableAutoCompact: Bool
    /// 每个 Claude 角色独立决定是否在最终请求模型 ID 追加 `[1m]`。
    var claudeModel1M: [ModelSlot: Bool]

    /// 网关发现只决定是否把代理目录加入 /model，不改变三个角色槽的请求映射。
    /// 新配置默认只使用客户端模型项；回填时保留用户已有的网关发现设置。
    var claudeGatewayModelDiscovery: Bool

    /// 菜单结构和子代理目标分别保存，避免新增菜单项改变启动模型或后台任务。
    var claudeModelPicker: ClaudeModelPickerConfiguration
    var claudeSubagentModel: String?

    enum CodingKeys: String, CodingKey {
        case agent, modelSlots, proxyURL, apiKey, useOAuth, setupMode
        case codexReasoningEffort, claudeDefaultModel, claudeDefaultModel1M, claudeModelDisplayNames
        case claudeMaxContextTokens, claudeAutoCompactPercentage
        case claudeDisableAutoCompact, claudeModel1M, claudeGatewayModelDiscovery
        case claudeModelPicker, claudeSubagentModel
        case claudeModelPlatformHints
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
        let legacyDefault = Self.normalizedClaudeModelID(claudeDefaultModel ?? "")
        claudeDefaultModel1M = try container.decodeIfPresent(Bool.self, forKey: .claudeDefaultModel1M)
            ?? legacyDefault.uses1M
        // 旧数据可能把后缀直接存在模型字段里；完整角色选择器留给原生 CLI 解析。
        if legacyDefault.uses1M, ModelSlot(rawValue: legacyDefault.base) == nil {
            claudeDefaultModel = legacyDefault.base
        }
        claudeModelDisplayNames = try container.decodeIfPresent([ModelSlot: String].self, forKey: .claudeModelDisplayNames)
        claudeModelPlatformHints = try container.decodeIfPresent([String: String].self, forKey: .claudeModelPlatformHints) ?? [:]
        let decodedContextTokens = try container.decodeIfPresent(Int.self, forKey: .claudeMaxContextTokens)
        claudeMaxContextTokens = decodedContextTokens.map { $0 > 0 ? $0 : Self.defaultClaudeMaxContextTokens }
            ?? Self.defaultClaudeMaxContextTokens
        let decodedCompactPercentage = try container.decodeIfPresent(Int.self, forKey: .claudeAutoCompactPercentage)
        claudeAutoCompactPercentage = decodedCompactPercentage.map { (1...100).contains($0) ? $0 : Self.defaultClaudeAutoCompactPercentage }
            ?? Self.defaultClaudeAutoCompactPercentage
        claudeDisableAutoCompact = try container.decodeIfPresent(Bool.self, forKey: .claudeDisableAutoCompact) ?? false
        claudeModel1M = try container.decodeIfPresent([ModelSlot: Bool].self, forKey: .claudeModel1M) ?? [:]
        claudeGatewayModelDiscovery = try container.decodeIfPresent(Bool.self, forKey: .claudeGatewayModelDiscovery) ?? false
        // 旧草稿不主动接管菜单；旧生成器固定使用 Haiku 的实际 ID，迁移时维持该行为。
        claudeModelPicker = try container.decodeIfPresent(ClaudeModelPickerConfiguration.self, forKey: .claudeModelPicker)
            ?? .roleDefaults(mode: .native)
        if !container.contains(.claudeModelPicker) { claudeModelPicker.shouldWrite = false }
        claudeSubagentModel = nil
        if container.contains(.claudeSubagentModel) {
            claudeSubagentModel = try container.decodeIfPresent(String.self, forKey: .claudeSubagentModel)
        } else if !container.contains(.claudeModelPicker) {
            claudeSubagentModel = claudeRequestModel(for: .haiku)
        }
    }

    /// 旧版会把模型 ID 自动写入 _NAME；新旧配置共用归一规则，回填和直接生成时都能修复重复标题。
    /// 与请求 ID 相同的名称沿用既有“自动名称”判定；其它用户自定义名称原样保留（仅去除首尾空白）。
    static func normalizedClaudeDisplayName(_ value: String?, for slot: ModelSlot, modelID: String) -> String? {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name != slot.rawValue.capitalized,
              normalizedClaudeModelID(name).base != normalizedClaudeModelID(modelID).base else { return nil }
        return name
    }

    func claudeDisplayName(for slot: ModelSlot) -> String {
        Self.normalizedClaudeDisplayName(claudeModelDisplayNames?[slot], for: slot,
            modelID: claudeRequestModel(for: slot)) ?? slot.rawValue.capitalized
    }

    func usesClaude1MContext(for slot: ModelSlot) -> Bool {
        claudeModel1M[slot] ?? false
    }

    /// 兼容 cc-switch 等配置来源的大写后缀，输出统一使用 Claude 的小写 `[1m]`。
    /// 只剥离末尾的一份声明，不改写模型本身的大小写，也不猜测代理别名的真实指向。
    static func normalizedClaudeModelID(_ value: String) -> (base: String, uses1M: Bool) {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.lowercased().hasSuffix("[1m]") else { return (model, false) }
        return (String(model.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    /// 配置输出和显示预览共用最终请求 ID，避免开启 1M 后预览仍展示普通上下文模型。
    /// 仅规范化一个末尾后缀，保持与既有配置回读规则一致。
    func claudeRequestModel(for slot: ModelSlot) -> String {
        let selected = modelSlots[slot]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = selected.isEmpty ? (AvailableModel.defaultModels[slot]?.name ?? "") : selected
        let base = Self.normalizedClaudeModelID(model).base
        return usesClaude1MContext(for: slot) ? base + "[1m]" : base
    }

    /// Claude Code 的补全使用说明，选择面板使用显示名称；自定义名称不能代替请求 ID。
    /// 名称只放在标题中，说明只展示请求目标，避免会话面板重复显示自定义名称。
    func claudeModelDescription(for slot: ModelSlot, availableModels: [AvailableModel] = []) -> String {
        let request = claudeRequestModel(for: slot)
        return ClaudeModelPresentation.platformModel(request, availableModels: availableModels, hints: claudeModelPlatformHints)
    }

    /// Fable 未指定时沿用 CLI 自己的原生默认，不擅自钉住一个代理未提供的模型。
    /// 其余旧槽保持原来的兜底行为，旧配置重新保存后请求目标不变。
    var configuredClaudeSlots: [ModelSlot] {
        ModelSlot.allCases.filter { $0 != .fable || !(modelSlots[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    var effectiveClaudeMaxContextTokens: Int {
        claudeMaxContextTokens
    }

    /// 只有明确的角色标识才表示继承。直接指定的实际 ID 即使与某个槽相同，仍然独立。
    var claudeDefaultModelSlot: ModelSlot? {
        ModelSlot(rawValue: claudeModel)
    }

    var claudeDefaultUses1MContext: Bool {
        claudeDefaultModelSlot.map { usesClaude1MContext(for: $0) } ?? claudeDefaultModel1M
    }

    /// 保存角色本身而不是展开后的 ID，确保重新打开表单仍能识别「跟随角色」。
    var claudeDefaultModelSelector: String {
        if let slot = claudeDefaultModelSlot { return slot.rawValue }
        let base = Self.normalizedClaudeModelID(claudeModel).base
        return claudeDefaultModel1M ? base + "[1m]" : base
    }

    /// Claude Code 2.1.236 不接受 ANTHROPIC_DEFAULT_MODEL=haiku（含上下文后缀）。
    /// 顶层 model 仍保留角色以支持回填与继承，仅 Default 回退变量展开为最终请求目标。
    var claudeDefaultFallbackModel: String {
        Self.normalizedClaudeModelID(claudeDefaultModelSelector).base == ModelSlot.haiku.rawValue
            ? claudeDefaultRequestModel : claudeDefaultModelSelector
    }

    /// 默认行的只读名称和请求预览均从最终选择推导，不伪造原生 Default 的名称配置字段。
    var claudeDefaultRequestModel: String {
        let parsed = Self.normalizedClaudeModelID(claudeModel)
        if let slot = ModelSlot(rawValue: parsed.base) {
            let request = claudeRequestModel(for: slot)
            // 显式角色[1m]仍通过该角色解析目标，只单独增加上下文声明。
            return claudeDefaultModelSlot == nil && claudeDefaultModel1M
                ? Self.normalizedClaudeModelID(request).base + "[1m]" : request
        }
        return claudeDefaultModelSelector
    }

    var claudeDefaultDisplayName: String {
        ModelSlot(rawValue: Self.normalizedClaudeModelID(claudeModel).base).map { claudeDisplayName(for: $0) }
            ?? Self.normalizedClaudeModelID(claudeModel).base
    }

    var claudeModel: String {
        get {
            let model = claudeDefaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return model.isEmpty ? ModelSlot.opus.rawValue : model
        }
        set {
            let parsed = Self.normalizedClaudeModelID(newValue)
            // 原生 opus[1m] 等选择器具有显式覆盖语义，保留它与普通角色继承的区别。
            claudeDefaultModel = parsed.uses1M && ModelSlot(rawValue: parsed.base) != nil
                ? parsed.base + "[1m]" : parsed.base
            if parsed.uses1M { claudeDefaultModel1M = true }
        }
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
        self.claudeDefaultModel1M = false
        self.claudeGatewayModelDiscovery = false
        self.claudeModelPlatformHints = [:]
        // 新配置直接使用 CLI 原生 /model 菜单，不再额外生成“精选”菜单。
        // 禁止自动改写菜单还能保护回填完成前、或其他工具刚写入的已有自定义菜单。
        // 保留菜单数据结构与旧草稿解码逻辑，只改变新配置的默认行为。
        self.claudeModelPicker = .roleDefaults(mode: .native)
        self.claudeModelPicker.shouldWrite = false
        // 新配置尊重 Claude 的会话继承；已有文件中的显式变量会在回填时恢复。
        self.claudeSubagentModel = nil
        // Pi 必须使用 CPA 实际返回的模型，不继承 Claude 槽默认值。
        if agent == .pi {
            self.modelSlots = [:]
        } else if agent == .codexCLI {
            self.modelSlots = [.sonnet: Self.defaultCodexModel]
        } else {
            self.modelSlots = Dictionary(uniqueKeysWithValues: ModelSlot.legacyCases.compactMap { slot in
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

