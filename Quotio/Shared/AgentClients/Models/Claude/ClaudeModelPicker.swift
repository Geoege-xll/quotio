// Claude 菜单模型、未知 JSON 字段与配置输出由客户端配置和基础设施共同使用，归入共享客户端模型。
// 本次整文件迁移并保留所有原声明；旧菜单策略、整数精度、写入归属和子代理选择器的兼容行为均不改变。

import Foundation

/// 模型菜单的展示策略独立于角色映射。旧配置默认保留原生列表，
/// 新配置使用原生列表，旧菜单策略保留用于兼容；无法识别的外部菜单保持原样。
nonisolated enum ClaudeModelPickerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case native, curated, append, external
    var id: String { rawValue }
    var localizationKey: String { "agents.claudePicker.mode.\(rawValue)" }
}

/// 保存菜单中的未知 JSON 字段，避免编辑名称时丢失 behavesAs、能力配置或未来扩展。
/// 只用于配置数据，不执行字段中的字符串，也不把显示名称当作请求模型。
nonisolated indirect enum ClaudePickerJSONValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), unsignedInteger(UInt64), number(Double), bool(Bool), array([Self]), object([String: Self]), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        // 整数先于浮点数解码，防止未知扩展中的大整数超过 2^53 后丢失精度。
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(UInt64.self) { self = .unsignedInteger(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([Self].self) { self = .array(v) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .unsignedInteger(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}

/// UUID 仅用于表单和草稿的稳定身份；实际 settings.json 不写入 UUID。
/// 模型、名称和说明各自存储，修改标题不会改变请求路径或角色继承关系。
nonisolated struct ClaudeModelPickerOption: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var model: String
    var label = ""
    var description = ""
    var extraFields: [String: ClaudePickerJSONValue] = [:]

    var selector: String {
        let parsed = AgentConfiguration.normalizedClaudeModelID(model)
        return parsed.base + (parsed.uses1M ? "[1m]" : "")
    }
}

nonisolated struct ClaudeModelPickerConfiguration: Codable, Equatable, Sendable {
    var mode: ClaudeModelPickerMode = .native
    var options: [ClaudeModelPickerOption] = []
    var extraFields: [String: ClaudePickerJSONValue] = [:]
    /// 只给新建菜单标记归属；导入用户菜单时不取得归属，恢复官方配置时保留它。
    var isQuotioManaged = true
    /// 没有新字段的旧草稿不接管磁盘菜单；用户主动编辑后才开启写入。
    var shouldWrite = true
    var preservedExternalJSON: Data?

    static func roleDefaults(mode: ClaudeModelPickerMode = .curated) -> Self {
        // 兼容旧菜单的三个默认条目；新增 Fable 使用原生槽，不重建或扩充用户的存量菜单。
        Self(mode: mode, options: ModelSlot.legacyCases.map { ClaudeModelPickerOption(model: $0.rawValue) })
    }

    /// 从 CLI 文件导入菜单，同时保留所有未知字段。结构不兼容时保留整段 JSON，
    /// 不通过过滤“坏行”来静默删除用户或其他工具写入的条目。
    static func read(_ object: Any?) -> Self {
        guard let object else { return roleDefaults(mode: .native) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              let fields = try? JSONDecoder().decode([String: ClaudePickerJSONValue].self, from: data),
              case .array(let rows) = fields["options"],
              fields["replaceBuiltInOptions"] == nil || fields["replaceBuiltInOptions"] == .bool(true)
                || fields["replaceBuiltInOptions"] == .bool(false) else {
            return Self(mode: .external, isQuotioManaged: false,
                        preservedExternalJSON: try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
        }
        var result = Self(mode: fields["replaceBuiltInOptions"] == .bool(true) ? .curated : .append,
                          extraFields: fields, isQuotioManaged: fields["quotioManaged"] == .bool(true))
        for key in ["options", "replaceBuiltInOptions", "quotioManaged"] { result.extraFields.removeValue(forKey: key) }
        for row in rows {
            guard case .object(var values) = row, case .string(let model) = values["model"],
                  values["label"] == nil || { if case .string = values["label"] { return true }; return false }(),
                  values["description"] == nil || { if case .string = values["description"] { return true }; return false }() else {
                return Self(mode: .external, isQuotioManaged: false, preservedExternalJSON: data)
            }
            var option = ClaudeModelPickerOption(model: model)
            if case .string(let label) = values["label"] { option.label = label }
            if case .string(let description) = values["description"] { option.description = description }
            for key in ["model", "label", "description"] { values.removeValue(forKey: key) }
            option.extraFields = values
            result.options.append(option)
        }
        return result
    }
}

extension AgentConfiguration {
    /// 三个角色共用 _NAME 与 modelPicker 的自动标题；额外模型优先使用用户名称。
    /// 角色名始终按角色区分，因此两个角色指向同一模型时不会生成相同的自动标题。
    nonisolated func claudePickerLabel(for option: ClaudeModelPickerOption) -> String {
        if let formatted = ClaudeModelPresentation.magpieOption(option) { return formatted.label }
        let custom = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let parsed = Self.normalizedClaudeModelID(option.selector)
        let name = ModelSlot(rawValue: parsed.base).map { claudeDisplayName(for: $0) } ?? parsed.base
        return name + (parsed.uses1M ? " · 1M" : "")
    }

    nonisolated func claudePickerDescription(for option: ClaudeModelPickerOption) -> String {
        if let formatted = ClaudeModelPresentation.magpieOption(option) { return formatted.description }
        let custom = option.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? claudeResolvedSelector(option.selector) : custom
    }

    /// 只为说明和预览解析角色；输出到菜单的 model 仍保留角色引用。
    /// 显式角色[1m]覆盖该次选择的上下文，不改变角色本身的开关。
    nonisolated func claudeResolvedSelector(_ selector: String) -> String {
        resolvedClaudeReference(selector)?.selector ?? selector
    }

    /// 已有菜单只读预览完整保留顺序，同一个模型可能来自不同账号，不能按模型去掉账号行。
    /// 用户明确编辑并写入菜单时沿用既有选择器去重规则；普通模型、1M 变体和各角色仍独立。
    nonisolated var claudeEffectivePickerOptions: [ClaudeModelPickerOption] {
        if !claudeModelPicker.shouldWrite || claudeCatalogManaged {
            return claudeModelPicker.options.filter { !$0.selector.isEmpty }
        }
        var seen = Set<String>()
        return claudeModelPicker.options.filter { !$0.selector.isEmpty && seen.insert($0.selector).inserted }
    }

    /// 输出和面板预览使用同一份规则，未知扩展字段在重新生成时原样保留。
    nonisolated func claudePickerJSONObject() throws -> Any? {
        if claudeModelPicker.mode == .native { return nil }
        if claudeModelPicker.mode == .external {
            return try claudeModelPicker.preservedExternalJSON.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
        var fields = claudeModelPicker.extraFields
        fields["replaceBuiltInOptions"] = .bool(claudeModelPicker.mode == .curated)
        if claudeCatalogManaged {
            // 新托管凭证位于根命名空间，CLI 正常保存会剥离 modelPicker 的未知嵌套键。
            // 这里只迁出我们自己认识的历史键；用户及其他工具的扩展字段仍原样保留。
            for key in ClaudeCatalogOwnership.legacyKeys { fields.removeValue(forKey: key) }
        } else if claudeModelPicker.isQuotioManaged { fields["quotioManaged"] = .bool(true) }
        fields["options"] = .array(claudeEffectivePickerOptions.map { option in
            var row = option.extraFields
            row["model"] = .string(option.selector)
            row["label"] = .string(claudePickerLabel(for: option))
            row["description"] = .string(claudePickerDescription(for: option))
            return .object(row)
        })
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(fields))
    }
}
