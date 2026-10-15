//
//  CLIAgent.swift
//  Quotio
//

import Foundation
import SwiftUI

// CLI 身份、安装与配置能力、检测状态由客户端配置和工作区共同使用，因此在共享客户端模型目录维护。
// 本次仅把完整声明从 AgentModels.swift 移出；客户端原始值、安装命令、配置路径及状态展示规则原样保留。
// 这些类型仍处于原应用 Target，显式 nonisolated 和 Sendable 契约不因目录归类而改变。

// MARK: - CLI Agent Types

nonisolated enum CLIAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case pi = "pi"
    case claudeCode = "claude-code"
    case codexCLI = "codex"
    case ampCLI = "amp"
    case openCode = "opencode"
    case factoryDroid = "factory-droid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: return "Pi"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .ampCLI: return "Amp CLI"
        case .openCode: return "OpenCode"
        case .factoryDroid: return "Factory Droid"
        }
    }

    var description: String {
        switch self {
        case .pi: return "Pi coding agent with the official CLIProxyAPI provider"
        case .claudeCode: return "Anthropic's official CLI for Claude models"
        case .codexCLI: return "OpenAI's Codex CLI for GPT-5 models"
        case .ampCLI: return "Sourcegraph's Amp coding assistant"
        case .openCode: return "The open source AI coding agent"
        case .factoryDroid: return "Factory's AI coding agent"
        }
    }

    var configType: AgentConfigType {
        switch self {
        case .pi: return .file
        case .claudeCode: return .both
        case .codexCLI: return .file
        case .ampCLI: return .both
        case .openCode: return .file
        case .factoryDroid: return .file
        }
    }

    var binaryNames: [String] {
        switch self {
        case .pi: return ["pi"]
        case .claudeCode: return ["claude"]
        case .codexCLI: return ["codex"]
        case .ampCLI: return ["amp"]
        case .openCode: return ["opencode", "oc"]
        case .factoryDroid: return ["droid", "factory-droid"]
        }
    }

    var configPaths: [String] {
        switch self {
        case .pi: return PiAgentSupport.configURLs(homeDirectory: FileManager.default.homeDirectoryForCurrentUser).map(\.path)
        case .claudeCode: return ["~/.claude/settings.json"]
        case .codexCLI: return ["~/.codex/config.toml", "~/.codex/auth.json"]
        case .ampCLI: return ["~/.config/amp/settings.json", "~/.local/share/amp/secrets.json"]
        case .openCode: return ["~/.config/opencode/opencode.json"]
        case .factoryDroid: return ["~/.factory/config.json"]
        }
    }

    var docsURL: URL? {
        switch self {
        // 文档地址使用固定且有效的 URL，与其他智能体的属性类型保持一致。
        case .pi: return URL(string: "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent")!
        case .claudeCode: return URL(string: "https://docs.anthropic.com/en/docs/claude-code")
        case .codexCLI: return URL(string: "https://github.com/openai/codex")
        case .ampCLI: return URL(string: "https://ampcode.com/manual")
        case .openCode: return URL(string: "https://github.com/sst/opencode")
        case .factoryDroid: return URL(string: "https://docs.factory.ai/welcome")
        }
    }

    var npmPackageName: String? {
        switch self {
        case .pi: return "@earendil-works/pi-coding-agent"
        case .claudeCode: return "@anthropic-ai/claude-code"
        case .codexCLI: return "@openai/codex"
        case .ampCLI: return "@sourcegraph/amp"
        case .openCode: return "opencode-ai"
        case .factoryDroid: return "@factory-ai/droid"
        }
    }

    var defaultInstallCommand: String {
        guard let pkg = npmPackageName else { return "" }
        return "npm install -g \(pkg)"
    }

    /// 推荐安装命令：若本机存在 Homebrew，优先推荐官方 Homebrew 源（避免 npm global 权限与环境路径冲突）
    var recommendedInstallCommand: String {
        let hasBrew = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
                      FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
        if hasBrew {
            switch self {
            case .claudeCode: return "brew install --cask claude-code"
            case .codexCLI: return "brew install --cask codex"
            case .openCode: return "brew install opencode"
            default: break
            }
        }
        return defaultInstallCommand
    }

    var defaultUpgradeCommand: String {
        guard let pkg = npmPackageName else { return "" }
        return "npm install -g \(pkg)@latest"
    }

    var defaultUninstallCommand: String {
        guard let pkg = npmPackageName else { return "" }
        return "npm uninstall -g \(pkg)"
    }

    var systemIcon: String {
        switch self {
        case .pi: return "terminal.fill"
        case .claudeCode: return "brain.head.profile"
        case .codexCLI: return "chevron.left.forwardslash.chevron.right"
        case .ampCLI: return "bolt.fill"
        case .openCode: return "terminal"
        case .factoryDroid: return "cpu"
        }
    }

    var color: Color {
        switch self {
        // 十六进制颜色解析为可选值，提供系统橙色兜底以满足非可选返回类型。
        case .pi: return Color(hex: "F97316") ?? .orange
        case .claudeCode: return Color(hex: "D97706") ?? .orange
        case .codexCLI: return Color(hex: "10A37F") ?? .green
        case .ampCLI: return Color(hex: "FF5543") ?? .red
        case .openCode: return Color(hex: "8B5CF6") ?? .purple
        case .factoryDroid: return Color(hex: "238636") ?? .green
        }
    }
}

// MARK: - Configuration Types

nonisolated enum AgentConfigType: String, Codable, Sendable {
    case environment = "env"
    case file = "file"
    case both = "both"
}


// MARK: - Installation Method

/// 智能体 CLI 的实际安装方式（区分 Homebrew Cask / Formula、npm、pnpm、bun、独立二进制等）
nonisolated enum AgentInstallMethod: Equatable, Hashable, Sendable {
    case homebrewCask(name: String)
    case homebrewFormula(name: String)
    case npm(package: String)
    case pnpm(package: String)
    case bun(package: String)
    case standalone(binaryPath: String)
    case unknown

    var displayName: String {
        switch self {
        case .homebrewCask:
            return "Homebrew (Cask)"
        case .homebrewFormula:
            return "Homebrew"
        case .npm:
            return "npm"
        case .pnpm:
            return "pnpm"
        case .bun:
            return "bun"
        case .standalone:
            // 安装方式模型是 nonisolated；复用原同步本地化入口，避免后台检测跨越主执行器。
            return "agents.installMethod.standalone".localizedStatic()
        case .unknown:
            return "agents.installMethod.unknown".localizedStatic()
        }
    }

    var badgeColor: Color {
        switch self {
        case .homebrewCask, .homebrewFormula:
            return .blue
        case .npm:
            return .red
        case .pnpm:
            return .orange
        case .bun:
            return .yellow
        case .standalone:
            return .teal
        case .unknown:
            return .secondary
        }
    }

    /// 针对该安装方式定制的升级命令
    func upgradeCommand(for agent: CLIAgent) -> String {
        switch self {
        case .homebrewCask(let name):
            return "brew upgrade --cask \(ShellCommand.argument(name))"
        case .homebrewFormula(let name):
            return "brew upgrade \(ShellCommand.argument(name))"
        case .npm(let pkg):
            return "npm install -g \(ShellCommand.argument(pkg + "@latest"))"
        case .pnpm(let pkg):
            return "pnpm add -g \(ShellCommand.argument(pkg + "@latest"))"
        case .bun(let pkg):
            return "bun add -g \(ShellCommand.argument(pkg + "@latest"))"
        case .standalone(let path):
            // 对当前入口执行其原生升级，不安装第二份 npm CLI。旧版不支持子命令时
            // 保留终端的失败结果，不能自动换渠道；未知独立工具交由原安装方式维护。
            switch agent {
            case .claudeCode, .codexCLI: return "\(ShellCommand.argument(path)) update"
            case .openCode: return "\(ShellCommand.argument(path)) upgrade"
            default: return ""
            }
        case .unknown:
            return ""
        }
    }

    /// 针对该安装方式定制的卸载命令
    func uninstallCommand(for agent: CLIAgent, binaryPath: String? = nil) -> String {
        switch self {
        case .homebrewCask(let name):
            return "brew uninstall --cask \(ShellCommand.argument(name))"
        case .homebrewFormula(let name):
            return "brew uninstall \(ShellCommand.argument(name))"
        case .npm(let pkg):
            // 包管理器自行清理其入口。失败后不能继续删除普通文件或其他渠道的链接，
            // 也不能让后续 rm 的退出码掩盖真正的卸载失败。
            return "npm uninstall -g \(ShellCommand.argument(pkg))"
        case .pnpm(let pkg):
            return "pnpm remove -g \(ShellCommand.argument(pkg))"
        case .bun(let pkg):
            return "bun remove -g \(ShellCommand.argument(pkg))"
        case .standalone(let path):
            // 只移除已探测的可执行入口，保留同目录的配置和其他资源。
            return "rm -f -- \(ShellCommand.argument(path))"
        case .unknown:
            return ""
        }
    }

    /// 尝试从真实符号链接路径向上查找 package.json 并提取其实际包名
    static func detectPackageNameFromResolvedPath(_ resolvedPath: String) -> String? {
        var currentURL = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent()
        for _ in 0..<6 {
            let pkgURL = currentURL.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkgURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String, !name.isEmpty {
                return name
            }
            let parent = currentURL.deletingLastPathComponent()
            if parent.path == currentURL.path { break }
            currentURL = parent
        }
        return nil
    }

    /// 根据已探测到的可执行文件路径与符号链接目标深度解析安装方式
    static func detect(for agent: CLIAgent, binaryPath: String?) -> AgentInstallMethod {
        guard let binaryPath = binaryPath, !binaryPath.isEmpty else {
            return .unknown
        }
        let fileURL = URL(fileURLWithPath: (binaryPath as NSString).expandingTildeInPath)
        let resolvedPath = fileURL.resolvingSymlinksInPath().path
        let rawPath = fileURL.path

        // 1. Homebrew Cask 检测 (解析 Caskroom 目录，如 /opt/homebrew/Caskroom/claude-code/...)
        if let range = resolvedPath.range(of: "/Caskroom/") {
            let sub = resolvedPath[range.upperBound...]
            let caskName = String(sub.prefix(while: { $0 != "/" }))
            if !caskName.isEmpty {
                return .homebrewCask(name: caskName)
            }
        }

        // 2. Homebrew Formula 检测 (解析 Cellar 目录，如 /opt/homebrew/Cellar/opencode/...)
        if let range = resolvedPath.range(of: "/Cellar/") {
            let sub = resolvedPath[range.upperBound...]
            let formulaName = String(sub.prefix(while: { $0 != "/" }))
            if !formulaName.isEmpty {
                return .homebrewFormula(name: formulaName)
            }
        }

        // /opt/homebrew 也可能是 Node 的 npm 全局前缀，不能仅凭路径前缀推断 brew 归属。

        // 4. Bun 检测
        if resolvedPath.contains("/.bun/") || rawPath.contains("/.bun/") {
            let pkgName = detectPackageNameFromResolvedPath(resolvedPath) ?? agent.npmPackageName ?? agent.id
            return .bun(package: pkgName)
        }

        // 5. pnpm 检测
        if resolvedPath.contains("/pnpm/") || resolvedPath.contains("/Library/pnpm/") || rawPath.contains("pnpm") {
            let pkgName = detectPackageNameFromResolvedPath(resolvedPath) ?? agent.npmPackageName ?? agent.id
            return .pnpm(package: pkgName)
        }

        // 6. npm / nvm / npm-global / node_modules 检测
        if resolvedPath.contains("node_modules") ||
           resolvedPath.contains("/.nvm/") ||
           resolvedPath.contains("/.npm-global/") ||
           rawPath.contains("/.npm-global/") ||
           resolvedPath.contains("/lib/node_modules/") {
            let pkgName = detectPackageNameFromResolvedPath(resolvedPath) ?? agent.npmPackageName ?? agent.id
            return .npm(package: pkgName)
        }

        // 7. 独立安装脚本 (例如 opencode curl 安装在 ~/.opencode/bin)
        if rawPath.contains("/.opencode/") || resolvedPath.contains("/.opencode/") {
            return .standalone(binaryPath: rawPath)
        }

        // 8. 普通可执行文件兜底
        if FileManager.default.isExecutableFile(atPath: rawPath) {
            // 工具存在 npm 发行包不表示当前入口属于 npm；保留探测到的原生路径。
            return .standalone(binaryPath: rawPath)
        }

        return .unknown
    }
}

// MARK: - Agent Status

nonisolated struct AgentStatus: Identifiable, Sendable {
    let agent: CLIAgent
    var installed: Bool
    var configured: Bool
    var binaryPath: String?
    var version: String?
    var lastConfigured: Date?
    var installMethod: AgentInstallMethod

    init(
        agent: CLIAgent,
        installed: Bool,
        configured: Bool,
        binaryPath: String? = nil,
        version: String? = nil,
        lastConfigured: Date? = nil,
        installMethod: AgentInstallMethod = .unknown
    ) {
        self.agent = agent
        self.installed = installed
        self.configured = configured
        self.binaryPath = binaryPath
        self.version = version
        self.lastConfigured = lastConfigured
        self.installMethod = installMethod
    }

    var id: String { agent.id }

    /// 基于实际安装方式（Homebrew/npm/bun等）动态生成的升级命令
    var upgradeCommand: String {
        installMethod.upgradeCommand(for: agent)
    }

    /// 基于实际安装方式（Homebrew/npm/bun等）动态生成的卸载命令
    var uninstallCommand: String {
        installMethod.uninstallCommand(for: agent, binaryPath: binaryPath)
    }

    /// 模型只提供本地化键；由视图按当前语言解析，切换语言时不会留下硬编码英文状态。
    var statusLocalizationKey: String {
        if !installed {
            return "agents.notInstalled"
        } else if configured {
            return "agents.configured"
        } else {
            return "agents.installed"
        }
    }

    var statusColor: Color {
        if !installed {
            return .secondary
        } else if configured {
            return .green
        } else {
            return .orange
        }
    }
}

