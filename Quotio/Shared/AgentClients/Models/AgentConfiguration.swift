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

nonisolated struct AgentConfiguration: Codable, Equatable, Sendable {
    let agent: CLIAgent
    var modelSlots: [ModelSlot: String]
    var proxyURL: String
    var apiKey: String
    var useOAuth: Bool
    var setupMode: ConfigurationSetup
    /// Reasoning effort written to Codex CLI's `model_reasoning_effort`.
    /// Only used when `agent == .codexCLI`.
    var codexReasoningEffort: CodexReasoningEffort

    /// nil 表示交由 Claude Code 解析模型窗口，不把未知容量猜成 200K 或 1M。
    /// 保留原字段与 CodingKey；旧草稿中明确保存的正整数（包括 200000）继续作为自定义值回填。
    static let defaultClaudeMaxContextTokens: Int? = nil
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

    /// 可选的全局上下文声明：nil 跟随 CLI，正整数才写覆盖变量；0 仅表示表单已选择自定义但尚未填写。
    /// 不从型号或目录 ID 推断容量。逐模型 [1m] 仍独立处理，不提升这个全局值。
    var claudeMaxContextTokens: Int?
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
    /// 新配置页明确接管目录菜单；旧 Codable／服务调用缺省为 false，保留原兼容路径。
    /// 该选项只存在原草稿中，磁盘归属由菜单版本标记识别，不增加状态宿主。
    var claudeCatalogManaged = false
    var claudeSubagentModel: String?
    /// 保留 CLI 环境变量的原始字符串，避免普通保存把外部配置的值统一改成 "1"。
    /// nil 表示未声明；空字符串明确关闭强制覆盖，可覆盖旧 Shell 中遗留的开启值。
    var claudeSubagentModelForce: String? = nil

    enum CodingKeys: String, CodingKey {
        case agent, modelSlots, proxyURL, apiKey, useOAuth, setupMode
        case codexReasoningEffort, claudeDefaultModel, claudeDefaultModel1M, claudeModelDisplayNames
        case claudeMaxContextTokens, claudeAutoCompactPercentage
        case claudeDisableAutoCompact, claudeModel1M, claudeGatewayModelDiscovery
        case claudeModelPicker, claudeSubagentModel, claudeSubagentModelForce, claudeCatalogManaged
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
        claudeMaxContextTokens = decodedContextTokens.flatMap { $0 > 0 ? $0 : nil }
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
        // 新字段缺失时保持旧草稿原有行为，不因升级自动开启强制覆盖。
        claudeSubagentModelForce = try container.decodeIfPresent(String.self, forKey: .claudeSubagentModelForce)
        claudeCatalogManaged = try container.decodeIfPresent(Bool.self, forKey: .claudeCatalogManaged) ?? false
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
        // 已保存的显式选择优先，不能因型号名称像长上下文模型就把 false 改成 true。
        // 原始 ID 末尾的 [1m] 只在旧数据缺少独立开关时作为声明回退，不推断后端能力。
        if let explicit = claudeModel1M[slot] { return explicit }
        return Self.is1MSupported(by: modelSlots[slot] ?? "")
    }

    /// 保留原调用签名；此处只识别 CLI 明确的末尾 [1m] 声明，不声称检测模型能力。
    /// 128k、-1m、:1m、1000k 等都是后端 ID 的一部分，必须按原 ID 路由，不能自动追加后缀。
    static func is1MSupported(by modelName: String) -> Bool {
        normalizedClaudeModelID(modelName).uses1M
    }

    /// 兼容 cc-switch 等配置来源的大写后缀，输出统一使用 Claude 的小写 `[1m]`。
    /// 只剥离末尾的一份声明，不改写模型本身的大小写，也不猜测代理别名的真实指向。
    static func normalizedClaudeModelID(_ value: String) -> (base: String, uses1M: Bool) {
        let reference = ClaudeModelReference(value)
        return (reference.base, reference.uses1M)
    }

    /// 配置输出和显示预览共用最终请求 ID，避免开启 1M 后预览仍展示普通上下文模型。
    /// 仅规范化一个末尾后缀，保持与既有配置回读规则一致。
    func claudeRequestModel(for slot: ModelSlot) -> String {
        let selected = modelSlots[slot]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = selected.isEmpty ? (AvailableModel.defaultModels[slot]?.name ?? "") : selected
        return ClaudeModelReference(model).withOneMillionContext(usesClaude1MContext(for: slot)).selector
    }

    /// Default、菜单说明和保存计划共享角色链解析，不再分别实现一层／多层展开规则。
    /// 本方法不接管目录校验；读取旧配置时仍保留原字面值，严格保存计划再确认最终 wire ID。
    func resolvedClaudeReference(_ selector: String) -> ClaudeModelReference? {
        ClaudeModelReference(selector).resolvingRoles(in: modelSlots, oneMillion: claudeModel1M)
    }

    /// 槽位、菜单预览与配置输出共用的自动上下文投影，不改写原草稿或另建状态宿主。
    /// 历史每槽显式 true/false 保留；缺少独立声明时只采用目录明确容量，不从名称推断。
    func withClaudeCatalogContext(_ models: [AvailableModel]) -> Self {
        guard agent == .claudeCode else { return self }
        var result = self
        for slot in configuredClaudeSlots where claudeModel1M[slot] == nil {
            let reference = ClaudeModelReference(modelSlots[slot] ?? "")
            if reference.applyingCatalogContext(models).uses1M { result.claudeModel1M[slot] = true }
        }
        // 直接默认与子代理没有每槽开关；明确的长窗口按同一目录规则生成后缀，角色仍继承其槽。
        if let model = claudeDefaultModel, ClaudeModelReference(model).isLiteral,
           ClaudeModelReference(model).applyingCatalogContext(models).uses1M { result.claudeDefaultModel1M = true }
        if let model = claudeSubagentModel, ClaudeModelReference(model).isLiteral {
            result.claudeSubagentModel = ClaudeModelReference(model).applyingCatalogContext(models).selector
        }
        return result
    }

    /// Claude Code 的补全使用说明，选择面板使用显示名称；自定义名称不能代替请求 ID。
    /// 名称只放在标题中，说明只展示请求目标，避免会话面板重复显示自定义名称。
    func claudeModelDescription(for slot: ModelSlot, availableModels: [AvailableModel] = []) -> String {
        let request = resolvedClaudeReference(slot.rawValue)?.selector ?? claudeRequestModel(for: slot)
        return ClaudeModelPresentation.platformModel(request, availableModels: availableModels, hints: claudeModelPlatformHints)
    }

    /// Fable 未指定时沿用 CLI 自己的原生默认，不擅自钉住一个代理未提供的模型。
    /// 其余旧槽保持原来的兜底行为，旧配置重新保存后请求目标不变。
    var configuredClaudeSlots: [ModelSlot] {
        ModelSlot.allCases.filter { $0 != .fable || !(modelSlots[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    var effectiveClaudeMaxContextTokens: Int? {
        claudeMaxContextTokens
    }

    /// 只有明确的角色标识才表示继承。直接指定的实际 ID 即使与某个槽相同，仍然独立。
    var claudeDefaultModelSlot: ModelSlot? {
        let reference = ClaudeModelReference(claudeModel)
        return reference.uses1M ? nil : reference.role
    }

    var claudeDefaultUses1MContext: Bool {
        if let slot = claudeDefaultModelSlot {
            // 旧角色链的内层声明同样影响最终请求；不能让只读开关仍按第一层显示成普通上下文。
            return resolvedClaudeReference(slot.rawValue)?.uses1M ?? usesClaude1MContext(for: slot)
        }
        return ClaudeModelReference(claudeModel).uses1M || claudeDefaultModel1M
    }

    /// 保存角色本身而不是展开后的 ID，确保重新打开表单仍能识别「跟随角色」。
    var claudeDefaultModelSelector: String {
        if let slot = claudeDefaultModelSlot { return slot.rawValue }
        let reference = ClaudeModelReference(claudeModel)
        return reference.withOneMillionContext(reference.uses1M || claudeDefaultModel1M).selector
    }

    /// Claude Code 2.1.236 不接受 ANTHROPIC_DEFAULT_MODEL=haiku（含上下文后缀）。
    /// 顶层 model 仍保留角色以支持回填与继承，仅 Default 回退变量展开为最终请求目标。
    var claudeDefaultFallbackModel: String {
        Self.normalizedClaudeModelID(claudeDefaultModelSelector).base == ModelSlot.haiku.rawValue
            ? claudeDefaultRequestModel : claudeDefaultModelSelector
    }

    /// 默认行的只读名称和请求预览均从最终选择推导，不伪造原生 Default 的名称配置字段。
    var claudeDefaultRequestModel: String {
        resolvedClaudeReference(claudeDefaultModelSelector)?.selector ?? claudeDefaultModelSelector
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
    /// 空值表示尚未选择，不能补入固定版本；由页面提示从实时目录选择或手动输入。
    /// 已保存的旧 ID、自定义别名仍原样读取，既不按目录迁移也不按新白名单清理。
    var codexModel: String {
        get {
            let model = modelSlots[.sonnet]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return model
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
        // 只有 Claude 的角色引用由 CLI 原生解释；其他客户端的新配置不继承 Claude 槽，
        // 也不预填任何具体型号。目录型客户端使用实际返回的目录，Codex 由用户明确选择。
        if agent == .claudeCode {
            self.modelSlots = Dictionary(uniqueKeysWithValues: ModelSlot.legacyCases.compactMap { slot in
                AvailableModel.defaultModels[slot].map { (slot, $0.name) }
            })
        } else {
            self.modelSlots = [:]
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

