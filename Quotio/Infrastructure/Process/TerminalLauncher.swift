//
//  TerminalLauncher.swift
//  Quotio
//
//  Cross-terminal emulator detection and native launcher.
//  Executes CLI commands via executable .command runners to bypass
//  macOS AppleScript automation restrictions (-1743 errAEEventNotPermitted).
//

import AppKit
import Foundation

struct TerminalAppInfo: Identifiable, Hashable, Sendable {
    let id: String // bundle ID, or "auto"
    let displayName: String
    let iconName: String
    let isInstalled: Bool
    let appURL: URL?

    init(id: String, displayName: String, iconName: String, isInstalled: Bool, appURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.isInstalled = isInstalled
        self.appURL = appURL
    }
}

@MainActor
final class TerminalLauncher {
    static let shared = TerminalLauncher()

    private struct KnownTerminal {
        let bundleID: String
        let name: String
        let icon: String
    }

    private static let knownTerminals: [KnownTerminal] = [
        KnownTerminal(bundleID: "com.apple.Terminal", name: "Terminal (系统终端)", icon: "terminal"),
        KnownTerminal(bundleID: "com.googlecode.iterm2", name: "iTerm2", icon: "terminal.fill"),
        KnownTerminal(bundleID: "com.mitchellh.ghostty", name: "Ghostty", icon: "ghost.fill"),
        KnownTerminal(bundleID: "dev.warp.Warp-Stable", name: "Warp", icon: "bolt.fill"),
        KnownTerminal(bundleID: "io.alacritty", name: "Alacritty", icon: "terminal"),
        KnownTerminal(bundleID: "net.kovidgoyal.kitty", name: "Kitty", icon: "cat.fill"),
        KnownTerminal(bundleID: "com.github.wez.wezterm", name: "WezTerm", icon: "terminal"),
        KnownTerminal(bundleID: "com.microsoft.VSCode", name: "VS Code", icon: "chevron.left.forwardslash.chevron.right"),
        KnownTerminal(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", icon: "cursorarrow.rays")
    ]

    private init() {}

    /// 检测本机已安装的终端软件列表，并包含“自动 / 系统默认”选项
    func installedTerminals() -> [TerminalAppInfo] {
        var result: [TerminalAppInfo] = [
            TerminalAppInfo(
                id: "auto",
                displayName: "settings.terminal.auto".localized(),
                iconName: "wand.and.stars",
                isInstalled: true,
                appURL: nil
            )
        ]

        for known in Self.knownTerminals {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundleID) {
                result.append(
                    TerminalAppInfo(
                        id: known.bundleID,
                        displayName: known.name,
                        iconName: known.icon,
                        isInstalled: true,
                        appURL: appURL
                    )
                )
            }
        }

        return result
    }

    /// 在指定终端或默认终端中启动命令，免 AppleScript 权限
    func launch(command: String, in directory: String? = nil, bundleID: String? = nil) async throws {
        let selectedID = bundleID ?? MenuBarSettingsManager.shared.selectedTerminalBundleID
        let targetAppURL: URL? = {
            if selectedID != "auto",
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selectedID) {
                return url
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        }()

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workDir = directory.flatMap { $0.isEmpty ? nil : $0 } ?? home

        // 创建临时安全执行脚本 (.command)，macOS 原生识别并在终端运行
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("quotio_terminal_launchers")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let scriptFileName = "quotio-\(UUID().uuidString.prefix(8)).command"
        let scriptURL = tempDir.appendingPathComponent(scriptFileName)

        let preferredShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shell = ["zsh", "bash", "fish", "sh"].contains(URL(fileURLWithPath: preferredShell).lastPathComponent)
            && FileManager.default.isExecutableFile(atPath: preferredShell) ? preferredShell : "/bin/zsh"
        let scriptContent = Self.commandScript(command: command, directory: workDir,
            shell: shell, scriptPath: scriptURL.path)

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.activates = true

        if let targetAppURL {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([scriptURL], withApplicationAt: targetAppURL, configuration: openConfig) { app, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(scriptURL)
        }
    }

    /// 脚本由用户自己的 shell 以 login/interactive 模式初始化环境，再执行 POSIX 正文。
    /// 外层不 source 任一配置文件，避免 Bash 解释 Zsh/Fish 语法；命令显示和目录都按字面参数
    /// 转义，不能因反引号、$() 或引号在“打印命令”时多执行一次。纯构造入口供离线回归复用。
    static func commandScript(command: String, directory: String, shell: String,
                              scriptPath: String, keepsShellOpen: Bool = true) -> String {
        let execute = "exec /bin/sh " + ShellCommand.argument(scriptPath) + " --quotio-execute"
        let finish = keepsShellOpen ? "exec " + ShellCommand.argument(shell) + " -l" : "exit \"$QUOTIO_EXIT_CODE\""
        return """
        #!/bin/sh
        if [ "${1-}" != "--quotio-execute" ]; then
            exec \(ShellCommand.argument(shell)) -lic \(ShellCommand.argument(execute))
        fi
        # 用户 shell 已选定 nvm/fnm/asdf 等环境，只追加常见目录，不能让 Homebrew 覆盖原 npm。
        export PATH="$PATH:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:$HOME/.bun/bin"
        cd \(ShellCommand.argument(directory)) || exit
        printf '%s\\n' \(ShellCommand.argument("==> Quotio CLI Launcher: " + command))
        \(command)
        QUOTIO_EXIT_CODE=$?
        printf '\\n[命令执行结束，退出码: %s]\\n' "$QUOTIO_EXIT_CODE"
        \(finish)
        """
    }

    /// 启动已安装智能体的 CLI 交互会话
    func launchAgent(agent: CLIAgent, binaryPath: String?, in directory: String? = nil) async throws {
        let command = ShellCommand.argument(binaryPath ?? agent.binaryNames.first ?? agent.rawValue)
        try await launch(command: command, in: directory)
    }
}
