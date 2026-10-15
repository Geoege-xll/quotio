import Foundation
import SwiftUI

/// 多个业务共同使用的提供商定义。此次按完整声明迁移，显示信息、能力判断和原始值保持原样。
/// 继续保留既有 Codable 与客户端映射，不引入第二套提供商注册或账号分类规则。

// MARK: - Provider Types

nonisolated enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case qwen = "qwen"
    case iflow = "iflow"
    case antigravity = "antigravity"
    case vertex = "vertex"
    case kiro = "kiro"
    case copilot = "github-copilot"
    case cursor = "cursor"
    case factoryDroid = "factory-droid"
    case devin = "devin"
    case grok = "grok"
    case openRouter = "openrouter"
    case amp = "amp"
    case trae = "trae"
    case glm = "glm"
    case warp = "warp"
    case clinePass = "clinepass"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .qwen: return "Qwen Code"
        case .iflow: return "iFlow"
        case .antigravity: return "Antigravity"
        case .vertex: return "Vertex AI"
        case .kiro: return "Kiro"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        case .factoryDroid: return "Factory Droid"
        case .devin: return "Devin"
        case .grok: return "Grok"
        case .openRouter: return "OpenRouter"
        case .amp: return "Amp"
        case .trae: return "Trae"
        case .glm: return "Z.ai"
        case .warp: return "Warp"
        case .clinePass: return "ClinePass"
        }
    }
    
    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .qwen: return "cloud"
        case .iflow: return "arrow.triangle.branch"
        case .antigravity: return "wand.and.stars"
        case .vertex: return "cube"
        case .kiro: return "cloud.fill"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .factoryDroid: return "cpu"
        case .devin: return "bolt.horizontal.circle"
        case .grok: return "xmark.circle"
        case .openRouter: return "point.3.connected.trianglepath.dotted"
        case .amp: return "bolt.fill"
        case .trae: return "cursorarrow.rays"
        case .glm: return "brain"
        case .warp: return "terminal.fill"
        case .clinePass: return "cpu"
        }
    }
    
    /// Logo file name in ProviderIcons asset catalog
    var logoAssetName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "openai"
        case .qwen: return "qwen"
        case .iflow: return "iflow"
        case .antigravity: return "antigravity"
        case .vertex: return "vertex"
        case .kiro: return "kiro"
        case .copilot: return "copilot"
        case .cursor: return "cursor"
        case .factoryDroid: return "factory-droid"
        case .devin: return "devin"
        case .grok: return "grok"
        case .openRouter: return "openrouter"
        case .amp: return "amp"
        case .trae: return "trae"
        case .glm: return "glm"
        case .warp: return "warp"
        case .clinePass: return "clinepass"
        }
    }
    
    var color: Color {
        switch self {
        case .claude: return Color(hex: "D97706") ?? .orange
        case .codex: return Color(hex: "10A37F") ?? .green
        case .qwen: return Color(hex: "7C3AED") ?? .purple
        case .iflow: return Color(hex: "06B6D4") ?? .cyan
        case .antigravity: return Color(hex: "EC4899") ?? .pink
        case .vertex: return Color(hex: "EA4335") ?? .red
        case .kiro: return Color(hex: "9046FF") ?? .purple
        case .copilot: return Color(hex: "238636") ?? .green
        case .cursor: return Color(hex: "00D4AA") ?? .teal
        case .factoryDroid: return Color(hex: "238636") ?? .green
        case .devin: return Color(hex: "6C5CE7") ?? .purple
        case .grok: return .primary
        case .openRouter: return Color(hex: "6B5CFF") ?? .purple
        case .amp: return Color(hex: "FF5543") ?? .red
        case .trae: return Color(hex: "00B4D8") ?? .cyan
        case .glm: return Color(hex: "3B82F6") ?? .blue
        case .warp: return Color(hex: "01E5FF") ?? .cyan
        case .clinePass: return Color(hex: "61A3FA") ?? .blue
        }
    }
    
    var oauthEndpoint: String {
        // v8 授权统一按 provider 查询；CLI 登录和浏览器会话类服务商继续使用各自现有流程。
        // 已有属性保留，以免其他调用方依赖它，但不再暴露旧专用管理路径。
        [.claude, .codex, .qwen, .iflow, .antigravity].contains(self)
            ? "/oauth/auth-url?provider=" + rawValue : ""
    }

    /// CPA 8 的内置 OAuth 列表不含 Qwen/iFlow；保留旧入口供已注册的 OAuth 插件使用。
    /// 这只是向用户说明必要条件，不猜测代理已安装插件，也不把现有账号从列表移除。
    var requiresCPA8OAuthPlugin: Bool { self == .qwen || self == .iflow }
    
    /// Short symbol for menu bar display
    var menuBarSymbol: String {
        switch self {
        case .claude: return "C"
        case .codex: return "O"
        case .qwen: return "Q"
        case .iflow: return "F"
        case .antigravity: return "A"
        case .vertex: return "V"
        case .kiro: return "K"
        case .copilot: return "CP"
        case .cursor: return "CR"
        case .factoryDroid: return "FD"
        case .devin: return "D"
        case .grok: return "X"
        case .openRouter: return "OR"
        case .amp: return "AM"
        case .trae: return "TR"
        case .glm: return "G"
        case .warp: return "W"
        case .clinePass: return "CL"
        }
    }
    
    /// Menu bar icon asset name (nil if should use SF Symbol fallback)
    var menuBarIconAsset: String? {
        switch self {
        case .claude: return "claude-menubar"
        case .codex: return "openai-menubar"
        case .qwen: return "qwen-menubar"
        case .copilot: return "copilot-menubar"
        // These don't have custom icons, use SF Symbols
        case .antigravity: return "antigravity-menubar"
        case .kiro: return "kiro-menubar"
        case .iflow: return "iflow-menubar"
        case .vertex: return "vertex-menubar"
        case .cursor: return "cursor-menubar"
        case .amp: return "amp-menubar"
        case .factoryDroid, .devin, .grok, .openRouter: return nil
        case .trae: return "trae-menubar"
        case .glm: return "glm-menubar"
        case .warp: return "warp-menubar"
        case .clinePass: return "clinepass-menubar"
        }
    }
    
    /// Whether this provider supports quota tracking in quota-only mode
    var supportsQuotaOnlyMode: Bool {
        switch self {
        case .claude, .codex, .cursor, .factoryDroid, .antigravity, .copilot, .devin, .grok, .openRouter, .amp, .trae, .glm, .warp, .kiro, .clinePass:
            return true
        case .qwen, .iflow, .vertex:
            return false
        }
    }
    
    /// Whether this provider uses browser cookies for auth
    var usesBrowserAuth: Bool {
        switch self {
        case .cursor, .trae:
            return true
        default:
            return false
        }
    }
    
    /// Whether this provider uses CLI commands for quota
    var usesCLIQuota: Bool {
        switch self {
        case .claude, .codex:
            return true
        default:
            return false
        }
    }

    /// Whether this provider's accounts are imported from a local IDE database by the
    /// explicit "Scan for IDEs" flow (issue #29) instead of being authenticated inside
    /// Quotio. Such an account owns no Quotio credential, so it exists only as imported
    /// quota data and deleting that data deletes the account (issue #213).
    ///
    /// Derived from the existing traits rather than listing cases again, so a new IDE
    /// edition only has to opt into `usesBrowserAuth` / `supportsManualAuth` to inherit
    /// the same import and delete behaviour.
    var isImportedFromLocalIDE: Bool {
        usesBrowserAuth && !supportsManualAuth
    }

    /// Map provider to CLI agent (if applicable)
    var cliAgent: CLIAgent? {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codexCLI
        default: return nil
        }
    }
    
    /// Whether this provider can be added manually (via OAuth, CLI login, or file import)
    /// Cursor and Trae are excluded because they only read from local app databases
    /// GLM and ClinePass are excluded because they should only be added via Custom Providers
    var supportsManualAuth: Bool {
        switch self {
        case .cursor, .trae, .glm, .clinePass:
            return false  // API-key providers: Custom Providers; Cursor/Trae: local app databases
        default:
            return true
        }
    }

    /// 手动添加能力必须按运行模式判断：CPA 已支持的插件不等于 Monitor 实现了同名登录。
    /// 此处只控制新增入口，不限制已有账号的展示、额度读取、导入或删除。
    func supportsManualAuth(in mode: OperatingMode) -> Bool {
        supportsManualAuth && !(mode == .monitor && (self == .grok || self == .devin))
    }

    /// API 目录和本地 JSON 使用同一份类型归一规则，避免停服后 xAI 账号从列表消失。
    static func fromAuthProvider(_ value: String) -> AIProvider? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "copilot": return .copilot
        case "xai", "x-ai", "grok": return .grok
        default: return AIProvider(rawValue: normalized)
        }
    }

    /// Whether this provider uses API key authentication
    var usesAPIKeyAuth: Bool {
        switch self {
        case .glm, .warp, .clinePass, .factoryDroid, .openRouter, .amp:
            return true
        default:
            return false
        }
    }
    
    /// Whether this provider is quota-tracking only (not a real provider that can route requests)
    var isQuotaTrackingOnly: Bool {
        switch self {
        case .cursor, .trae, .factoryDroid, .devin, .grok, .openRouter, .amp, .warp:
            return true  // Only for tracking usage, not a provider
        default:
            return false
        }
    }

    /// Whether the Local Proxy dashboard can route this provider through its setup flow.
    var supportsLocalProxySetup: Bool {
        supportsManualAuth && !isQuotaTrackingOnly
    }
}
