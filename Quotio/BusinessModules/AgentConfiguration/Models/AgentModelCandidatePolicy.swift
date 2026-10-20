import Foundation

/// 客户端配置页的候选投影，只接受当前服务实际返回的请求 ID。
/// 目录、别名元数据与当前已选值各有来源；旧值继续留在原草稿，不能混进实时目录冒充新候选。
/// 本类型不读取账号、不发请求、不持有状态或 Task，也不根据提供商名称猜测模型路由。
nonisolated struct AgentModelCandidatePolicy {
    let agent: CLIAgent
    let models: [AvailableModel]
    let aliases: [CPAModelAlias]
    let selectedModel: String
    var allowsRoleSelection = true
    var slotModels: [ModelSlot: String] = [:]

    private var catalogIDs: Set<String> { Set(models.map(\.id)) }

    var selectedRole: ModelSlot? {
        guard agent == .claudeCode, allowsRoleSelection else { return nil }
        return nativeRole
    }

    private var nativeRole: ModelSlot? {
        guard agent == .claudeCode else { return nil }
        return ClaudeModelReference(selectedModel).role
    }

    /// 别名必须以 alias 本身出现在当前目录中；只有目标型号出现不能证明别名已被该后端注册。
    /// 使用大小写敏感的完整 ID，保留合法前缀；不把本机配置中的映射当成远端可用性的证据。
    var confirmedAliases: [CPAModelAlias] {
        aliases.filter { entry in
            catalogIDs.contains(entry.alias) && (agent != .claudeCode
                || ClaudeModelReference(entry.alias).isConfirmed(in: catalogIDs))
        }
    }

    var modelIDs: [String] {
        let aliasIDs = Set(confirmedAliases.map(\.alias))
        return catalogIDs.filter { !$0.isEmpty && !aliasIDs.contains($0)
            && (agent != .claudeCode || ClaudeModelReference($0).isConfirmed(in: catalogIDs)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func isConfirmed(_ selector: String) -> Bool {
        // 其他客户端的完整 ID 仍按字面匹配；Claude 必须确认移除上下文声明后真正发送的 wire ID。
        guard agent == .claudeCode else { return catalogIDs.contains(selector) }
        return ClaudeModelReference(selector).isConfirmed(in: catalogIDs)
    }

    var hasUnconfirmedSelection: Bool {
        if let nativeRole {
            // 历史角色映射保留回显，但实际模型槽禁止再选择角色或 role[1m]，不能把循环输入伪装成有效模型。
            return !allowsRoleSelection || isUnconfirmedTarget(for: nativeRole)
        }
        return !selectedModel.isEmpty && !isConfirmed(selectedModel)
    }

    /// 手动输入与目录候选共用同一分类结果；禁止特殊指令，也禁止在实际模型槽中手填角色变体。
    /// 未确认的字面 ID 仍可保留为草稿，由严格保存计划明确拦截；此处不按相似名称猜替代型号。
    func canAddCustomModel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isConfirmed(trimmed),
              !confirmedAliases.contains(where: { $0.alias == trimmed }) else { return false }
        guard agent == .claudeCode else { return true }
        let reference = ClaudeModelReference(trimmed)
        switch reference.kind {
        case .empty, .special: return false
        case .role: return allowsRoleSelection && reference.uses1M
        case .literal: return true
        }
    }

    /// 角色目标说明与保存计划使用同一个链解析器；不能只检查第一层而漏掉循环及缺失的下层目标。
    func resolvedTarget(for role: ModelSlot) -> ClaudeModelReference? {
        ClaudeModelReference(role.rawValue).resolvingRoles(in: slotModels)
    }

    /// 原生角色始终保留；用户已经给它映射旧型号时，仅标记目标缺少目录证据，不删除角色引用。
    func isUnconfirmedTarget(for role: ModelSlot) -> Bool {
        guard agent == .claudeCode,
              let target = slotModels[role]?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return false }
        guard let resolved = resolvedTarget(for: role) else { return true }
        return !resolved.isConfirmed(in: catalogIDs)
    }
}
