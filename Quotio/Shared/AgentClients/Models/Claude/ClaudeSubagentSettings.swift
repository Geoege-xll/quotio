import Foundation

/// 子代理默认值与强制覆盖属于同一个 CLI 契约：UI 回显、Shell 冲突校验和实际输出共用纯规则。
/// 不持有状态或 Task；原配置草稿、配置 actor 及 ViewModel 继续负责各自原有的生命周期。
nonisolated struct ClaudeSubagentSettings: Sendable {
    var model: String?
    var force: String?

    var environmentModel: String? {
        guard let value = model?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let parsed = AgentConfiguration.normalizedClaudeModelID(value)
        return parsed.base + (parsed.uses1M ? "[1m]" : "")
    }

    var selector: String? {
        guard let value = environmentModel, value != "inherit" else { return nil }
        return value
    }

    /// 与 CLI 的布尔环境变量解析保持一致：只接受 1／true／yes／on，忽略大小写和首尾空白。
    /// 不能按字符串非空判断，否则旧值 "0"／"false" 会被错误回显为开启；原始值仍无损保存。
    var isForced: Bool {
        ["1", "true", "yes", "on"].contains(force?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    /// settings.json 中已有的值优先于 Shell。只有 JSON 声明的行为与目标不同才要求修改 JSON；
    /// 同值、未声明，以及 inherit 与未设置的等价切换仍允许仅 Shell，避免不必要地拦截旧流程。
    func requiresJSONUpdate(comparedTo existing: Self) -> Bool {
        (existing.environmentModel != nil && existing.selector != selector)
            || (existing.force != nil && existing.isForced != isForced)
    }
}

// 子代理配置与菜单展示独立；选择器、回显和生成层仍使用原 AgentConfiguration 实例。
extension AgentConfiguration {
    /// 视图只消费语义选择器：原生 inherit 与未设置均表示使用默认规则。
    /// 输出仍读取 environmentModel，保留已有 inherit，而不是在打开／保存时擅自删除它。
    nonisolated var claudeSubagentSelector: String? {
        claudeSubagentSettings.selector
    }

    nonisolated var claudeSubagentSettings: ClaudeSubagentSettings {
        ClaudeSubagentSettings(model: claudeSubagentModel, force: claudeSubagentModelForce)
    }

}
