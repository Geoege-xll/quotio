//
//  ShellType.swift
//  Quotio
//

import Foundation

// Shell 类型及配置文件定位直接访问进程环境和文件系统，与 ShellProfileManager 一起归入进程基础设施。
// 保留 ZDOTDIR、XDG 配置目录和默认路径的判断次序，以及 zsh、bash、fish 的原始值。
// 环境声明由目标 Shell 原生生成；真正的用户 Profile 事务仍由 ShellProfileManager 执行。

// MARK: - Shell Profile

nonisolated enum ShellType: String, CaseIterable, Sendable {
    case zsh = "zsh"
    case bash = "bash"
    case fish = "fish"

    var profilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .zsh:
            if let zdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"], !zdotdir.isEmpty {
                return "\(zdotdir)/.zshrc"
            }
            let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
            let xdgZshDir = "\(xdgConfigHome)/zsh"
            if FileManager.default.fileExists(atPath: xdgZshDir) {
                return "\(xdgZshDir)/.zshrc"
            }
            return "\(home)/.zshrc"
        case .bash: return "\(home)/.bashrc"
        case .fish: return "\(home)/.config/fish/config.fish"
        }
    }

    var exportPrefix: String {
        switch self {
        case .zsh, .bash: return "export"
        case .fish: return "set -gx"
        }
    }

    /// Claude 的显式覆盖与撤销使用目标 Shell 的原生语法；nil 表示撤下旧 export。
    /// 值始终作为单引号字面量输出，内嵌引号拆分拼接，不能执行模型名或密钥中的命令替换。
    func environmentStatement(key: String, value: String?) -> String {
        guard let value else { return self == .fish ? "set -e \(key)" : "unset \(key)" }
        let quoted = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return self == .fish ? "set -gx \(key) '\(quoted)'" : "export \(key)='\(quoted)'"
    }
}

