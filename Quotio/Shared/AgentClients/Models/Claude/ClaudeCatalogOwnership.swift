import Foundation

/// 托管归属是应用与用户文件之间的协议，不是 Claude modelPicker 的一部分。
/// Claude 会规范化已知嵌套对象，但保留顶层未知键；因此把小型归属凭证放在根命名空间，
/// 避免用户一次 /model 保存就失去账号变更同步。凭证只含连接指纹，不存原始密钥。
nonisolated enum ClaudeCatalogOwnership {
    static let rootKey = "quotioClaudeCatalog"
    static let legacyKeys = ["quotioManaged", "quotioCatalogVersion", "quotioCatalogSource"]

    static func source(in settings: [String: Any]) -> String? {
        if let root = settings[rootKey] {
            guard let fields = root as? [String: Any], isSupported(fields), boolean(fields["managed"]) == true else { return nil }
            return fields["source"] as? String
        }
        // 兼容已经生成的旧菜单：只认完整、有效的旧标记，不从模型名称或菜单相似度猜归属。
        guard let fields = settings["modelPicker"] as? [String: Any],
              fields["quotioManaged"] as? Bool == true,
              integerVersion(fields["quotioCatalogVersion"]) == 1,
              let source = fields["quotioCatalogSource"] as? String, !source.isEmpty else { return nil }
        return source
    }

    static func isSupported(_ fields: [String: Any]) -> Bool {
        integerVersion(fields["version"]) == 1 && boolean(fields["managed"]) != nil
            && (fields["source"] as? String).map { !$0.isEmpty } == true
    }

    static func canWrite(in settings: [String: Any]) -> Bool {
        guard let root = settings[rootKey] else { return true }
        guard let fields = root as? [String: Any] else { return false }
        // 官方恢复只撤下已知归属键，可能留下未知扩展；再次应用可安全合并这种无归属对象。
        // 若仍含任何保留键，则必须是当前完整协议，不能覆盖残缺或未来版本的归属。
        let reserved = ["managed", "version", "source"]
        return (isSupported(fields) || reserved.allSatisfy { fields[$0] == nil })
            && ClaudeCatalogProjection.canRead(fields[ClaudeCatalogProjection.key])
    }

    static func recording(in settings: [String: Any], source: String) -> [String: Any] {
        var result = settings
        // 同命名空间内的未知扩展也保留；调用前由 canWrite 拒绝无法理解的未来结构。
        var fields = settings[rootKey] as? [String: Any] ?? [:]
        fields["managed"] = true
        fields["version"] = 1
        fields["source"] = source
        result[rootKey] = fields
        return result
    }

    static func removingKnownFields(in settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var fields = settings[rootKey] as? [String: Any], isSupported(fields) else { return result }
        for key in ["managed", "version", "source"] { fields.removeValue(forKey: key) }
        // 自动值来源与托管归属一起退出，未知扩展继续保留，不能在再次应用时恢复已经撤下的旧策略。
        if ClaudeCatalogProjection.canRead(fields[ClaudeCatalogProjection.key]) {
            if let retained = ClaudeCatalogProjection.removingKnownFields(fields[ClaudeCatalogProjection.key]) {
                fields[ClaudeCatalogProjection.key] = retained
            } else { fields.removeValue(forKey: ClaudeCatalogProjection.key) }
        }
        if fields.isEmpty { result.removeValue(forKey: rootKey) }
        else { result[rootKey] = fields }
        return result
    }

    /// 已有 SavedAgentConfig 的投影字段保持兼容；磁盘新格式不再依赖这些嵌套扩展。
    static func picker(in settings: [String: Any]) -> ClaudeModelPickerConfiguration {
        var picker = ClaudeModelPickerConfiguration.read(settings["modelPicker"])
        if settings[rootKey] != nil {
            // 根协议一旦存在即具有优先权；不能让旧嵌套投影绕过未来／无效根协议的拒绝接管。
            picker.isQuotioManaged = false
            for key in legacyKeys { picker.extraFields.removeValue(forKey: key) }
        }
        if let source = source(in: settings) {
            picker.isQuotioManaged = true
            picker.extraFields["quotioCatalogVersion"] = .integer(1)
            picker.extraFields["quotioCatalogSource"] = .string(source)
        }
        return picker
    }

    /// Foundation 会把数字 1 桥接成 Bool；磁盘协议仍要求真正 JSON 布尔，避免残缺标记被误接管。
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integerVersion(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }
}

/// 记录应用生成的值而非另一份配置：跨 CLI /model 保存后仍可区别“自动投影”与用户显式选择。
/// 仅精确匹配同一来源、选择器和已生成文本才恢复自动输入；无记录的历史值一律保持显式兼容。
/// 放在根托管命名空间，避免 CLI 规范化 modelPicker 时丢失；不持有服务、状态或任务。
nonisolated struct ClaudeCatalogProjection {
    static let key = "projection"
    var contexts: [String: String] = [:]
    var menuLabels: [String: String] = [:]
    var menuContexts: [String: String] = [:]

    static func canRead(_ object: Any?) -> Bool {
        guard let object else { return true }
        guard let fields = object as? [String: Any] else { return false }
        if fields["version"] == nil {
            // 官方恢复可留下纯未知扩展壳；再次应用可合并，但不能把它读成有效的自动值凭证。
            let contexts = fields["contexts"] as? [String: String] ?? [:]
            return fields["menuLabels"] == nil && fields["menuContexts"] == nil
                && (fields["contexts"] == nil || fields["contexts"] is [String: String])
                && contexts.keys.allSatisfy { !knownContextNames.contains($0) }
        }
        guard let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1" else { return false }
        return ["contexts", "menuLabels", "menuContexts"].allSatisfy {
            fields[$0] == nil || fields[$0] is [String: String]
        }
    }

    static func read(in settings: [String: Any]) -> Self? {
        guard let env = settings["env"] as? [String: Any],
              let url = env["ANTHROPIC_BASE_URL"] as? String, let key = env["ANTHROPIC_AUTH_TOKEN"] as? String,
              ClaudeCatalogOwnership.source(in: settings) == ClaudeConfigurationPlan.sourceID(
                url: ClaudeConfigurationSource.modelAPIBaseURL(url), key: key),
              let root = settings[ClaudeCatalogOwnership.rootKey] as? [String: Any],
              let fields = root[Self.key] as? [String: Any], fields["version"] != nil, canRead(fields) else { return nil }
        return Self(contexts: fields["contexts"] as? [String: String] ?? [:],
                    menuLabels: fields["menuLabels"] as? [String: String] ?? [:],
                    menuContexts: fields["menuContexts"] as? [String: String] ?? [:])
    }

    func isAutomaticContext(_ name: String, selector: String) -> Bool {
        let reference = ClaudeModelReference(selector)
        guard reference.uses1M else { return false }
        // Default 原本就显式开启时，即使目录恰好也生成同名自动菜单项，仍不能吞掉历史独立声明。
        if name == "default", contexts["default-explicit"] == reference.selector { return false }
        // CLI 从自动菜单项选择并保存为新 Default 时同样继承自动规则；角色仍由自己的映射决定。
        return contexts[name] == reference.selector
            || (name == "default" && reference.isLiteral && menuContexts[reference.selector] == reference.base)
    }

    func isExplicitNormalContext(_ role: ModelSlot, selector: String) -> Bool {
        contexts["normal-" + role.rawValue] == ClaudeModelReference(selector).selector
    }

    func restoringMenu(_ picker: ClaudeModelPickerConfiguration) -> ClaudeModelPickerConfiguration {
        var result = picker
        for index in result.options.indices {
            let original = result.options[index]
            let selector = original.selector
            if menuLabels[selector] == original.label { result.options[index].label = "" }
            if menuContexts[selector] == ClaudeModelReference(selector).base {
                result.options[index].model = ClaudeModelReference(selector).base
            }
        }
        return result
    }

    /// 比较计划输入和最终输出，只登记本轮确实自动生成的部分；用户名称和旧显式 1M 不取得管理权。
    static func generated(input: AgentConfiguration, output: AgentConfiguration) -> Self {
        var result = Self()
        for role in output.configuredClaudeSlots {
            let before = input.resolvedClaudeReference(role.rawValue)
            let after = output.claudeRequestModel(for: role)
            if before?.uses1M == false, ClaudeModelReference(after).uses1M {
                result.contexts[role.rawValue] = after
            } else if input.claudeModel1M[role] == false, !ClaudeModelReference(after).uses1M {
                // JSON 只有裸 ID 无法区分“明确普通窗口”和“尚未推导”；保存这一最小绑定以兼容旧 false。
                result.contexts["normal-" + role.rawValue] = after
            }
        }
        if input.claudeDefaultModelSlot == nil, !input.claudeDefaultUses1MContext,
           output.claudeDefaultModelSlot == nil, output.claudeDefaultUses1MContext {
            result.contexts["default"] = output.claudeDefaultModelSelector
        } else if input.claudeDefaultModelSlot == nil, input.claudeDefaultUses1MContext {
            result.contexts["default-explicit"] = output.claudeDefaultModelSelector
        }
        if let before = input.claudeSubagentSelector, let after = output.claudeSubagentSelector,
           !ClaudeModelReference(before).uses1M, ClaudeModelReference(after).uses1M {
            result.contexts["subagent"] = after
        }
        for row in output.claudeEffectivePickerOptions where ClaudeModelReference(row.selector).isLiteral {
            let original = input.claudeModelPicker.options.first { $0.id == row.id }
            let name = original?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if original == nil || name.isEmpty || name == original?.selector
                || name == original.map({ ClaudeModelReference($0.selector).base }) {
                result.menuLabels[row.selector] = output.claudePickerLabel(for: row)
            }
            if ClaudeModelReference(row.selector).uses1M,
               original == nil || !ClaudeModelReference(original!.selector).uses1M {
                result.menuContexts[row.selector] = ClaudeModelReference(row.selector).base
            }
        }
        return result
    }

    func recording(in settings: [String: Any]) -> [String: Any] {
        var result = settings
        var root = settings[ClaudeCatalogOwnership.rootKey] as? [String: Any] ?? [:]
        var fields = root[Self.key] as? [String: Any] ?? [:]
        fields["version"] = 1
        // 上下文名是有限契约；未来客户端的其他上下文成员不在本轮已知集合内，继续原样保留。
        var allContexts = fields["contexts"] as? [String: String] ?? [:]
        for name in Self.knownContextNames { allContexts.removeValue(forKey: name) }
        allContexts.merge(contexts) { _, new in new }
        fields["contexts"] = allContexts
        fields["menuLabels"] = menuLabels
        fields["menuContexts"] = menuContexts
        root[Self.key] = fields
        result[ClaudeCatalogOwnership.rootKey] = root
        return result
    }

    private static var knownContextNames: [String] {
        ModelSlot.allCases.map(\.rawValue) + ModelSlot.allCases.map { "normal-" + $0.rawValue }
            + ["default", "default-explicit", "subagent"]
    }

    /// 恢复官方配置只撤下本协议成员，不能把同命名空间的未来扩展一起删除。
    static func removingKnownFields(_ object: Any?) -> [String: Any]? {
        guard var fields = object as? [String: Any] else { return nil }
        for key in ["version", "menuLabels", "menuContexts"] { fields.removeValue(forKey: key) }
        if var contexts = fields["contexts"] as? [String: String] {
            for name in knownContextNames { contexts.removeValue(forKey: name) }
            if contexts.isEmpty { fields.removeValue(forKey: "contexts") } else { fields["contexts"] = contexts }
        }
        return fields.isEmpty ? nil : fields
    }
}
