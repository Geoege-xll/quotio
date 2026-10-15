//
//  ShellType.swift
//  Quotio
//

import Foundation

// Shell 类型及配置文件定位直接访问进程环境和文件系统，与 ShellProfileManager 一起归入进程基础设施。
// 完整保留 ZDOTDIR、XDG 配置目录和默认路径的判断次序，以及 zsh、bash、fish 的原始值和 export 语法。
// 本次只移动完整声明，不迁移或改写用户磁盘上的 Shell 配置文件，也不改变运行时路径。

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
}

