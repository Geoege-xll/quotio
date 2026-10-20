import Foundation

/// Claude 模型引用的唯一语义入口：选择器与 HTTP 请求模型身份并不是同一个概念。
/// 角色由 CLI／现有角色映射解析，特殊指令不能作为网关型号；只有字面 ID 才能进入请求正文。
/// `[1m]` 仅是选择器末尾的上下文声明，不能以目录中的 `x[1m]` 证明实际发送的 `x` 可用。
/// 本类型只转换纯值，不读取配置、网络或账号，也不持有状态及 Task。
nonisolated struct ClaudeModelReference: Equatable, Sendable {
    enum Special: String, CaseIterable, Sendable {
        case `default`, inherit, best, opusplan
    }

    enum Kind: Equatable, Sendable {
        case empty
        case role(ModelSlot)
        case special(Special)
        case literal
    }

    let base: String
    let uses1M: Bool
    let kind: Kind

    init(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        uses1M = trimmed.lowercased().hasSuffix("[1m]")
        base = uses1M ? String(trimmed.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        if base.isEmpty { kind = .empty }
        else if let role = ModelSlot(rawValue: base) { kind = .role(role) }
        else if let special = Special(rawValue: base) { kind = .special(special) }
        else { kind = .literal }
    }

    /// 仅规范化末尾的上下文声明；合法前缀、模型主体的大小写和内部符号全部保留。
    var selector: String { base + (uses1M ? "[1m]" : "") }
    var role: ModelSlot? { if case .role(let role) = kind { return role }; return nil }
    var isLiteral: Bool { kind == .literal }
    var wireModelID: String? { isLiteral ? base : nil }

    func withOneMillionContext(_ enabled: Bool) -> Self {
        Self(base + (enabled ? "[1m]" : ""))
    }

    /// 自动声明只采用同一精确 ID 的明确输入窗口；别名拼写、owned_by 和平台名都不证明容量。
    /// 已带后缀的历史选择保持原样；目录没有容量或存在相互矛盾的容量时交给 CLI 原生规则。
    func applyingCatalogContext(_ catalog: [AvailableModel]) -> Self {
        guard isLiteral, !uses1M else { return self }
        let windows = Set(catalog.filter { $0.id == base }.compactMap(\.contextWindow).filter { $0 > 0 })
        return windows.count == 1 && (windows.first ?? 0) >= 1_000_000 ? withOneMillionContext(true) : self
    }

    /// 目录证据必须覆盖真正进入 HTTP 正文的 ID，不能只匹配带有 CLI 声明的选择器。
    /// 例如目录只有 `model[1m]` 而没有 `model` 时，此处明确失败，不猜测后端是否也接受裸 ID。
    func isConfirmed(in catalogIDs: Set<String>) -> Bool {
        guard let wireModelID else { return false }
        return catalogIDs.contains(wireModelID)
    }

    /// 旧配置允许角色链，读取时保留；预览与生成统一展开到字面 ID，循环／缺失目标明确失败。
    /// 每个槽的显式开关优先于该槽旧 ID 中的后缀；外层 `role[1m]` 及下层已开启的声明向外传递。
    func resolvingRoles(in roles: [ModelSlot: String], oneMillion: [ModelSlot: Bool] = [:],
                        visited: Set<ModelSlot> = []) -> Self? {
        switch kind {
        case .empty, .special: return nil
        case .literal: return self
        case .role(let role):
            guard !visited.contains(role), let value = roles[role] else { return nil }
            let target = Self(value)
            let useLongContext = uses1M || (oneMillion[role] ?? target.uses1M)
            return target.withOneMillionContext(useLongContext)
                .resolvingRoles(in: roles, oneMillion: oneMillion, visited: visited.union([role]))
        }
    }
}
