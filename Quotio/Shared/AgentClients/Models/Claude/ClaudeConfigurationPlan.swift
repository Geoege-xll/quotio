import Foundation
import CryptoKit

/// Claude 配置中不属于表单编辑项、但仍引用模型身份的旧字段快照。
/// 仅保存模型相关数据，不复制 env 中的密钥；预览读已加载快照，保存读磁盘最新对象。
/// 不持有任务、服务或可变共享状态，未知 JSON 值继续使用原有无损表示。
nonisolated struct ClaudeLegacyModelReferences: Equatable, Sendable {
    var smallFastModel: String?
    var capabilities: String?
    var modelSettings: [String: ClaudePickerJSONValue]?
    var fallbackModel: ClaudePickerJSONValue?
    var advisorModel: String?
    /// 仅在“自定义名称恰好等于迁移后的 ID”时记录来源，防止下次回读误判成旧版自动名称。
    /// 以模型和名称成对绑定；未知扩展值原样保留，不改变原 _NAME 的 CLI 协议。
    var modelNameBindings: [String: ClaudePickerJSONValue]?
    /// 对照磁盘当前名称，外部工具删除／改写 _NAME 后旧绑定立即失效，不能恢复旧文案。
    var currentRoleNames: [String: String] = [:]

    static func read(_ settings: [String: Any]) -> Self {
        let env = settings["env"] as? [String: Any] ?? [:]
        let modelSettings = (settings["modelSettings"] as? [String: Any]).flatMap {
            try? JSONDecoder().decode([String: ClaudePickerJSONValue].self,
                                     from: JSONSerialization.data(withJSONObject: $0))
        }
        let nameBindings = (settings["quotioModelNameBindings"] as? [String: Any]).flatMap {
            try? JSONDecoder().decode([String: ClaudePickerJSONValue].self,
                                     from: JSONSerialization.data(withJSONObject: $0))
        }
        let fallback = settings["fallbackModel"].flatMap { value in
            (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).flatMap {
                try? JSONDecoder().decode(ClaudePickerJSONValue.self, from: $0)
            }
        }
        return Self(smallFastModel: env["ANTHROPIC_SMALL_FAST_MODEL"] as? String,
                    capabilities: env["CLAUDE_CODE_MODEL_CAPABILITIES"] as? String, modelSettings: modelSettings,
                    fallbackModel: fallback, advisorModel: settings["advisorModel"] as? String,
                    modelNameBindings: nameBindings,
                    currentRoleNames: Dictionary(uniqueKeysWithValues: ModelSlot.allCases.compactMap { slot in
                        (env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL_NAME"] as? String).map { (slot.rawValue, $0) }
                    }))
    }
}

/// 一次 Claude 配置事务的纯值计划：角色、菜单及关联模型键共用同一个目录解析规则。
/// ID 是后端公开的请求身份；平台说明、账号文案和 owned_by 不作为路由映射依据。
/// 原 ViewModel 负责目录来源与请求世代，原配置 actor 负责最新文件合并、备份和提交。
nonisolated struct ClaudeConfigurationPlan: Sendable {
    /// CLI 会解释这些特殊指令，不能把同名网关 ID 当作可直接传输的普通型号。
    /// Default 由 CLI 固定入口保留，其实际目标必须另行确认；继承语义仍由子代理规则维护。
    static let nonModelSelectors: Set<String> = Set(ClaudeModelReference.Special.allCases.map(\.rawValue))
    struct Migration: Equatable, Hashable, Sendable {
        let original: String
        let target: String
    }

    private(set) var configuration: AgentConfiguration
    private(set) var legacy: ClaudeLegacyModelReferences
    private(set) var migrations: [Migration] = []
    private(set) var unresolved: [String] = []
    private(set) var conflicts: [String] = []
    private(set) var requiresJSONUpdate = false
    /// 退出生效范围的模型与阻止提交的入口分开，避免将目录失效误当成官方退役。
    private(set) var removedModels: [String] = []
    private(set) var blockingReferences: [String] = []
    /// 菜单行清理与型号失效分开计数：同型号仍可由当前目录重新生成，不能误报为不可用。
    private(set) var removedLegacyMenuCount = 0
    var isCatalogManaged: Bool { configuration.claudeCatalogManaged }
    var catalogCount: Int { modelIDs.count }
    var sourceIdentifier: String {
        Self.sourceID(url: configuration.proxyURL, key: configuration.apiKey)
    }
    static func sourceID(url: String, key: String) -> String {
        digest((ModelCatalogClient.modelsURL(baseURL: url)?.absoluteString ?? url) + "\n" + key)
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var roleDisplayNames: [ModelSlot: String] = [:]
    private let modelIDs: Set<String>
    private let catalog: [AvailableModel]

    init(configuration requestedConfiguration: AgentConfiguration, availableModels: [AvailableModel],
         legacy: ClaudeLegacyModelReferences = .init()) {
        let configuration = requestedConfiguration.withClaudeCatalogContext(availableModels)
        self.configuration = configuration
        self.legacy = legacy
        // 只采用目录原始 id，不采用 name/展示归属，也不按相似型号、大小写或供应商名猜测。
        catalog = availableModels
        modelIDs = Set(availableModels.map(\.id))

        for slot in configuration.configuredClaudeSlots {
            guard let model = configuration.modelSlots[slot] else { continue }
            self.configuration.modelSlots[slot] = resolve(model)
            // 必须按迁移前的身份判定用户名称，不能用新 ID 把已确认的自定义名称重新降级为自动名称。
            let custom = AgentConfiguration.normalizedClaudeDisplayName(configuration.claudeModelDisplayNames?[slot],
                                                                         for: slot, modelID: configuration.claudeRequestModel(for: slot))
            let target = AgentConfiguration.normalizedClaudeModelID(self.configuration.claudeRequestModel(for: slot)).base
            var boundName: String?
            if case .object(let binding) = legacy.modelNameBindings?[slot.rawValue],
               case .string(let boundModel) = binding["model"], case .string(let name) = binding["name"],
               boundModel == target, legacy.currentRoleNames[slot.rawValue] == name, !name.isEmpty {
                boundName = name
            }
            let name = custom ?? boundName ?? slot.rawValue.capitalized
            roleDisplayNames[slot] = name
            if name != slot.rawValue.capitalized,
               AgentConfiguration.normalizedClaudeDisplayName(name, for: slot, modelID: target) == nil {
                var bindings = self.legacy.modelNameBindings ?? [:]
                // 只给歧义名称保留最小绑定；正常自定义名称不增加元数据，已有绑定扩展字段也保留。
                var binding: [String: ClaudePickerJSONValue] = [:]
                if case .object(let existing) = bindings[slot.rawValue] { binding = existing }
                binding["model"] = .string(target)
                binding["name"] = .string(name)
                bindings[slot.rawValue] = .object(binding)
                self.legacy.modelNameBindings = bindings
            }
        }
        if let model = configuration.claudeDefaultModel {
            self.configuration.claudeDefaultModel = resolve(model)
        }
        if let model = configuration.claudeSubagentModel {
            self.configuration.claudeSubagentModel = resolve(model)
        }
        // 用户授权移除明确带来源标记的旧 Magpie 行；原文仍在配置 actor 的原字节备份中。
        // 不识别的历史项和合法前缀不能仅因长得像 Magpie 就被删除。
        if configuration.claudeCatalogManaged {
            self.configuration.claudeModelPicker.options.removeAll { option in
                guard ClaudeModelPresentation.isLegacyMagpie(option) else { return false }
                removedLegacyMenuCount += 1
                return true
            }
        }
        // 仍保留原 shouldWrite、UUID 和外部字段；迁移不是取得整张菜单的管理权。
        for index in self.configuration.claudeModelPicker.options.indices {
            let option = self.configuration.claudeModelPicker.options[index]
            var formatted = ClaudeModelPresentation.magpieOption(option) ?? option
            formatted.model = resolve(option.model)
            if option.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let role = ModelSlot(rawValue: AgentConfiguration.normalizedClaudeModelID(option.model).base),
               displayName(for: role) != self.configuration.claudeDisplayName(for: role) {
                // 自动补入的标题仍继承原角色选择器的 1M 标识，不把长上下文行伪装成普通行。
                formatted.label = displayName(for: role) + (AgentConfiguration.normalizedClaudeModelID(option.model).uses1M ? " · 1M" : "")
            }
            self.configuration.claudeModelPicker.options[index] = formatted
        }
        if let model = legacy.smallFastModel { self.legacy.smallFastModel = resolve(model) }

        if let settings = legacy.modelSettings {
            var output = settings
            for key in settings.keys.sorted() {
                let target = resolve(key)
                guard target != key else { continue }
                // 已有当前 ID 的设置优先，冲突的旧值继续保留，不能因迁移静默覆盖用户选择。
                if output[target] != nil { Self.addUnique(key, to: &conflicts); continue }
                output[target] = settings[key]
                output.removeValue(forKey: key)
            }
            self.legacy.modelSettings = output
        }
        if let capabilities = legacy.capabilities {
            let segments = capabilities.components(separatedBy: ";")
            var existing = Set(segments.compactMap { segment -> String? in
                guard let separator = segment.firstIndex(of: "=") else { return nil }
                return String(segment[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            })
            self.legacy.capabilities = segments.map { segment in
                guard let separator = segment.firstIndex(of: "=") else { return segment }
                let key = String(segment[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let target = resolve(key)
                guard target != key else { return segment }
                if existing.contains(target) { Self.addUnique(key, to: &conflicts); return segment }
                existing.insert(target)
                // 能力正文只是透传的声明；这里仅迁移关联键，不发明或合并后端能力。
                return target + String(segment[separator...])
            }.joined(separator: ";")
        }
        // 旧前缀先按当前目录迁移，再匹配精确 ID 的容量；否则槽位漏识别而追加项识别为 1M。
        self.configuration = self.configuration.withClaudeCatalogContext(availableModels)
        if configuration.claudeCatalogManaged { applyCatalogPolicy() }
        requiresJSONUpdate = configuration.claudeCatalogManaged || self.legacy != legacy
            || self.configuration.claudeModelPicker.options.map(\.model) != configuration.claudeModelPicker.options.map(\.model)
    }

    func displayName(for slot: ModelSlot) -> String {
        roleDisplayNames[slot] ?? configuration.claudeDisplayName(for: slot)
    }

    /// 已存在的完整 ID（包括合法 prefix/model）始终优先；只迁移已知旧网关命名且后半段精确存在的 ID。
    /// 三种命名来自现有 Magpie 导入契约，不是静态型号清单。未知前缀、缺失型号、空／失败目录都不猜测。
    /// [1m] 是 Claude 的上下文声明，匹配时分离，输出时保留；原生角色继续交给 CLI 解析。
    private mutating func resolve(_ selector: String) -> String {
        let parsed = ClaudeModelReference(selector)
        // 角色／特殊指令不参与网关旧前缀迁移；完整目录身份优先，合法 prefix/model 不做截断。
        // 保留原始选择与确认 wire ID 是两件事：目录只有 prefix/model[1m] 时先保留它，
        // 随后的严格校验仍会拒绝缺失的 prefix/model，不能改猜为另一条无前缀型号。
        guard parsed.isLiteral, !modelIDs.contains(selector), !modelIDs.contains(parsed.base) else { return selector }
        let parts = parsed.base.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, ["codex", "antigravity", "zhipu"].contains(String(parts[0])) else { return selector }
        let target = String(parts[1])
        guard !target.isEmpty, !modelIDs.isEmpty else { return selector }
        guard ClaudeModelReference(target).isConfirmed(in: modelIDs) else {
            Self.addUnique(selector, to: &unresolved)
            return selector
        }
        let resolved = target + (parsed.uses1M ? "[1m]" : "")
        let migration = Migration(original: selector, target: resolved)
        if !migrations.contains(migration) { migrations.append(migration) }
        return resolved
    }

    /// 同一个解析器处理角色与具体 ID；原生角色只有最终落到已确认 ID 才能进入受管菜单。
    /// 循环角色和未映射角色明确失败，不回退到 CLI 内置型号，也不擅自选择目录第一项。
    func confirmedRequest(_ selector: String, visited: Set<ModelSlot> = []) -> String? {
        guard let request = ClaudeModelReference(selector).resolvingRoles(in: configuration.modelSlots,
                oneMillion: configuration.claudeModel1M, visited: visited), request.isConfirmed(in: modelIDs) else { return nil }
        return request.selector
    }

    /// 已确认的角色引用保持继承关系；具体 ID 使用规范化后的请求身份。
    /// 关联字段不能因为本次校验而把长期跟随角色的选择永久展开成一个固定型号。
    private func confirmedSelector(_ selector: String) -> String? {
        guard let request = confirmedRequest(selector) else { return nil }
        return ClaudeModelReference(selector).role == nil ? request : selector
    }

    private mutating func applyCatalogPolicy() {
        guard !modelIDs.isEmpty else { blockingReferences = ["modelCatalog"]; return }
        if configuration.claudeModelPicker.mode == .external {
            blockingReferences.append("modelPicker")
            return
        }
        // 先在同一份原角色图上解析全部目标，再统一写入纯值计划，避免逐槽修改影响后续解析。
        // Claude CLI 的角色环境映射只展开一层；因此旧的 Opus→Sonnet→实际 ID 必须在输出前展开，
        // Default／子代理仍可保留角色选择器，实际请求、预览和说明都使用这份已确认的最终映射。
        var resolvedRoles: [ModelSlot: String] = [:]
        for role in configuration.configuredClaudeSlots {
            if let request = confirmedRequest(role.rawValue) { resolvedRoles[role] = request }
            else { blockingReferences.append(role.rawValue.capitalized) }
        }
        for (role, request) in resolvedRoles {
            let parsed = AgentConfiguration.normalizedClaudeModelID(request)
            configuration.modelSlots[role] = parsed.base
            configuration.claudeModel1M[role] = parsed.uses1M
            let name = displayName(for: role)
            if name != role.rawValue.capitalized,
               AgentConfiguration.normalizedClaudeDisplayName(name, for: role, modelID: parsed.base) == nil {
                // 角色链展开后，原自定义名称可能恰好等于最终 ID；绑定最终身份，
                // 下次回读才不会把该名称误认成旧版本自动生成的标题。
                var bindings = legacy.modelNameBindings ?? [:]
                var binding: [String: ClaudePickerJSONValue] = [:]
                if case .object(let existing) = bindings[role.rawValue] { binding = existing }
                binding["model"] = .string(parsed.base)
                binding["name"] = .string(name)
                bindings[role.rawValue] = .object(binding)
                legacy.modelNameBindings = bindings
            }
        }
        if confirmedRequest(configuration.claudeDefaultModelSelector) == nil { blockingReferences.append("Default") }
        if let child = configuration.claudeSubagentSelector, confirmedRequest(child) == nil {
            blockingReferences.append("CLAUDE_CODE_SUBAGENT_MODEL")
        }

        // 当前 ID 的关联设置优先。旧冲突键退出生效配置，整份原始文件始终保存在事务备份里。
        if let settings = legacy.modelSettings {
            var cleaned = settings
            for key in settings.keys.sorted() {
                let target = resolve(key)
                guard let request = confirmedSelector(target) else {
                    cleaned.removeValue(forKey: key); Self.addUnique(key, to: &removedModels); continue
                }
                if key != request {
                    if cleaned[request] == nil { cleaned[request] = settings[key] }
                    cleaned.removeValue(forKey: key)
                }
            }
            legacy.modelSettings = cleaned
        }
        if let value = legacy.capabilities {
            let parts = value.components(separatedBy: ";")
            let keys = Set(parts.compactMap { part -> String? in
                guard let index = part.firstIndex(of: "=") else { return nil }
                return String(part[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            })
            var emitted = Set<String>()
            legacy.capabilities = parts.compactMap { part -> String? in
                guard let index = part.firstIndex(of: "=") else { return part }
                let key = String(part[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                let target = resolve(key)
                guard let request = confirmedSelector(target) else {
                    Self.addUnique(key, to: &removedModels); return nil
                }
                if key != request, keys.contains(request) { return nil }
                guard emitted.insert(request).inserted else { return nil }
                return request + String(part[index...])
            }.joined(separator: ";")
            if legacy.capabilities?.isEmpty == true { legacy.capabilities = nil }
        }
        if let small = legacy.smallFastModel, confirmedRequest(small) == nil {
            Self.addUnique(small, to: &removedModels); legacy.smallFastModel = nil
        }
        if let advisor = legacy.advisorModel {
            let target = resolve(advisor)
            legacy.advisorModel = confirmedSelector(target)
            if legacy.advisorModel == nil { Self.addUnique(advisor, to: &removedModels) }
        }
        if let fallback = legacy.fallbackModel {
            switch fallback {
            case .string(let value):
                if value == "default" { break }
                let target = resolve(value)
                legacy.fallbackModel = confirmedSelector(target).map { .string($0) }
                if legacy.fallbackModel == nil { Self.addUnique(value, to: &removedModels) }
            case .array(let values):
                var retained: [ClaudePickerJSONValue] = []
                for value in values {
                    guard case .string(let model) = value else { blockingReferences.append("fallbackModel"); continue }
                    if model == "default" { retained.append(value); continue }
                    let target = resolve(model)
                    if let request = confirmedSelector(target) { retained.append(.string(request)) }
                    else { Self.addUnique(model, to: &removedModels) }
                }
                legacy.fallbackModel = retained.isEmpty ? nil : .array(retained)
            default: blockingReferences.append("fallbackModel")
            }
        }

        var retained: [ClaudeModelPickerOption] = []
        for var option in configuration.claudeModelPicker.options {
            // 追加模型的自动上下文声明采用同一精确目录证据；角色继续继承各槽的存量设置。
            if ClaudeModelReference(option.selector).isLiteral {
                option.model = ClaudeModelReference(option.selector).applyingCatalogContext(catalog).selector
            }
            guard let request = confirmedRequest(option.selector) else {
                Self.addUnique(option.model, to: &removedModels); continue
            }
            if ModelSlot(rawValue: AgentConfiguration.normalizedClaudeModelID(option.selector).base) != nil {
                // 固定角色的右侧必须取当前已确认映射，不能沿用旧菜单说明。
                // 否则换了 Opus／Sonnet 目标后，会出现“菜单写 Gemini、CLI 实际选 GPT”的错配。
                // 角色保留标题、选择器和未知字段；追加模型随后使用当前已确认的来源元数据。
                option.description = ClaudeModelPresentation.platformModel(request, availableModels: catalog,
                    hints: configuration.claudeModelPlatformHints)
            } else {
                // 新行与历史普通行都经过同一展示规则，防止下一次同步退回左右重复的 ID。
                option = ClaudeModelPresentation.catalogOption(option, models: catalog)
            }
            // 同 ID 的不同账号描述继续保留，仅合并内容完全相同的重复行；UUID 不参与输出身份。
            if !retained.contains(where: { $0.model == option.model && $0.label == option.label
                && $0.description == option.description && $0.extraFields == option.extraFields }) { retained.append(option) }
        }
        var rows: [ClaudeModelPickerOption] = []
        for role in configuration.configuredClaudeSlots where confirmedRequest(role.rawValue) != nil {
            if !retained.contains(where: { $0.selector == role.rawValue }) {
                rows.append(.init(model: role.rawValue, label: displayName(for: role),
                    description: configuration.claudeModelDescription(for: role, availableModels: catalog)))
            }
        }
        rows += retained
        let covered = Set(rows.compactMap { confirmedRequest($0.selector).map { AgentConfiguration.normalizedClaudeModelID($0).base } })
        for id in modelIDs.sorted() where !covered.contains(ClaudeModelReference(id).base)
            && ClaudeModelReference(id).isConfirmed(in: modelIDs) {
            let selector = ClaudeModelReference(id).applyingCatalogContext(catalog).selector
            rows.append(ClaudeModelPresentation.catalogOption(.init(model: selector), models: catalog))
        }
        configuration.claudeModelPicker.options = rows
        configuration.claudeModelPicker.mode = .curated
        configuration.claudeModelPicker.isQuotioManaged = true
        configuration.claudeModelPicker.shouldWrite = true
        configuration.claudeModelPicker.extraFields["quotioCatalogVersion"] = .integer(1)
        configuration.claudeModelPicker.extraFields["quotioCatalogSource"] = .string(sourceIdentifier)
        configuration.claudeGatewayModelDiscovery = false
    }

    /// 报告只记录模型引用与结果，不记录密钥、完整 env、hooks 或原始配置正文。
    func migrationReport(backupPath: String?) -> [String: Any] {
        ["version": 1, "status": "prepared", "source": sourceIdentifier, "backup": backupPath ?? "",
         "catalogCount": modelIDs.count, "catalogFingerprint": Self.digest(modelIDs.sorted().joined(separator: "\n")),
         "migrations": migrations.map { ["from": $0.original, "to": $0.target] },
         "removedModels": removedModels, "removedLegacyMenuItems": removedLegacyMenuCount, "conflicts": conflicts]
    }

    private static func addUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) { values.append(value) }
    }

    /// 保存处理磁盘最新对象，预览处理同一组纯规则。未接管的菜单只改实际发生迁移的引用，
    /// 不序列化整张类型化菜单，避免补 flag、去重、丢失未知字段或改变大整数。
    func mergingLegacyReferences(into settings: [String: Any]) throws -> [String: Any] {
        var result = settings
        if !configuration.claudeCatalogManaged, !configuration.claudeModelPicker.shouldWrite,
           configuration.claudeModelPicker.mode != .external,
           var menu = settings["modelPicker"] as? [String: Any],
           var rows = menu["options"] as? [[String: Any]],
           rows.count == configuration.claudeModelPicker.options.count {
            for index in rows.indices {
                let option = configuration.claudeModelPicker.options[index]
                rows[index]["model"] = option.model
                // 与原展示格式化保持一致，账号文字仍只是说明，不产生账号固定路由。
                if rows[index]["label"] != nil || !option.label.isEmpty { rows[index]["label"] = option.label }
                if rows[index]["description"] != nil || !option.description.isEmpty { rows[index]["description"] = option.description }
            }
            menu["options"] = rows
            result["modelPicker"] = menu
        }
        // env 的已知条目读取字符串，合并时仍保留任意未知 JSON 值；单个扩展字段不能清空整个对象。
        var env = result["env"] as? [String: Any] ?? [:]
        if let model = legacy.smallFastModel { env["ANTHROPIC_SMALL_FAST_MODEL"] = model }
        if let capabilities = legacy.capabilities { env["CLAUDE_CODE_MODEL_CAPABILITIES"] = capabilities }
        if configuration.claudeCatalogManaged {
            if legacy.smallFastModel == nil { env.removeValue(forKey: "ANTHROPIC_SMALL_FAST_MODEL") }
            if legacy.capabilities == nil { env.removeValue(forKey: "CLAUDE_CODE_MODEL_CAPABILITIES") }
            if let fallback = legacy.fallbackModel {
                result["fallbackModel"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback), options: [.fragmentsAllowed])
            } else { result.removeValue(forKey: "fallbackModel") }
            if let advisor = legacy.advisorModel { result["advisorModel"] = advisor }
            else { result.removeValue(forKey: "advisorModel") }
        }
        if !env.isEmpty || configuration.claudeCatalogManaged { result["env"] = env }
        if let modelSettings = legacy.modelSettings {
            result["modelSettings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modelSettings))
        }
        if let bindings = legacy.modelNameBindings {
            result["quotioModelNameBindings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bindings))
        }
        return result
    }
}
