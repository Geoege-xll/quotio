import Foundation

/// Claude 的一次配置操作使用同一份有效输出规则，供页面校验、纯预览和配置服务共同消费。
/// 手动模式生成可复制的 JSON 方案，不沿用自动模式中已经隐藏的“仅 Shell”选择。
/// 本值没有状态、任务或磁盘副作用；原 ViewModel 与两个配置 actor 的所有权保持不变。
nonisolated struct ClaudeConfigurationOperation: Sendable {
    let mode: ConfigurationMode
    let storage: ConfigStorageOption

    init(mode: ConfigurationMode, storage: ConfigStorageOption) {
        self.mode = mode
        self.storage = mode == .manual ? .jsonOnly : storage
    }

    var writesJSON: Bool { mode == .automatic && storage != .shellOnly }
    var writesShell: Bool { mode == .automatic && storage != .jsonOnly }
}

/// 配置服务明确返回后续 Shell 动作，原 ViewModel 只执行，不再自行推断恢复／保存的清理条件。
/// JSON 写入回执仍交给原服务回滚；管理段外的用户命令仍由 ShellProfileManager 完整保留。
nonisolated enum ClaudeShellProfileAction: Sendable {
    case preserve
    case replace(String)
    case remove
}

/// 实际由本配置服务写入的环境键集中登记，保存、恢复及 Shell 撤销共用。
/// 不把未知 env、独立压缩窗口或用户的其他提供商凭据扩大为本应用管理范围。
nonisolated enum ClaudeManagedEnvironment {
    static let keys: [String] = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_MODEL",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "DISABLE_AUTO_COMPACT",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "CLAUDE_CODE_SUBAGENT_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL_FORCE", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_MODEL_CAPABILITIES"
    ] + ModelSlot.allCases.flatMap { role in
        let prefix = "ANTHROPIC_DEFAULT_" + role.envSuffix + "_MODEL"
        return [prefix, prefix + "_NAME", prefix + "_DESCRIPTION"]
    }
}
