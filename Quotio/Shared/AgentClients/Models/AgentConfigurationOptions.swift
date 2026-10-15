//
//  AgentConfigurationOptions.swift
//  Quotio
//

import Foundation

// 集中保存客户端配置的选择项与角色槽，供配置界面、草稿和文件生成器使用同一份值类型。
// 各枚举的字符串原始值属于既有 Codable 与配置协议，保持不变；ModelSlot.legacyCases 继续维持其他客户端的三槽兼容。
// 本次只移动完整声明，不调整 Fable、默认连接方式、自动或手动模式及存储位置的行为。

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
    case fable = "fable"
    case sonnet = "sonnet"
    case haiku = "haiku"

    var id: String { rawValue }

    /// 旧三槽协议继续用于其他代理与旧菜单草稿；Fable 只扩展 Claude 的原生角色。
    /// 避免新增角色后把额外默认模型写入 OpenCode、Droid 等已有三槽配置。
    static let legacyCases: [Self] = [.opus, .sonnet, .haiku]

    var displayName: String {
        switch self {
        case .opus: return "Opus (High Intelligence)"
        case .fable: return "Fable (Complex Tasks)"
        case .sonnet: return "Sonnet (Balanced)"
        case .haiku: return "Haiku (Fast)"
        }
    }

    var envSuffix: String {
        rawValue.uppercased()
    }
}

