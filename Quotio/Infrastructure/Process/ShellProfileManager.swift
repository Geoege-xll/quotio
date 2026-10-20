//
//  ShellProfileManager.swift
//  Quotio - Manage shell profile modifications
//

import Foundation

actor ShellProfileManager {
    private let fileManager = FileManager.default
    /// 原管理器继续持有 Shell 事务；只读路径和原子写入依赖供临时 home／失败回归注入。
    private let profilePath: @Sendable (ShellType) -> String
    private let writeProfile: @Sendable (String, String) throws -> Void
    init(profilePath: @escaping @Sendable (ShellType) -> String = { $0.profilePath },
         writeProfile: @escaping @Sendable (String, String) throws -> Void = { text, path in
             try text.write(toFile: path, atomically: true, encoding: .utf8)
         }) {
        self.profilePath = profilePath
        self.writeProfile = writeProfile
    }
    
    func detectShell() -> ShellType {
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            if shell.contains("zsh") { return .zsh }
            if shell.contains("bash") { return .bash }
            if shell.contains("fish") { return .fish }
        }
        return .zsh
    }
    
    func getProfilePath(for shell: ShellType) -> String {
        profilePath(shell)
    }
    
    func addToProfile(
        shell: ShellType,
        configuration: String,
        agent: CLIAgent
    ) async throws {
        let profilePath = getProfilePath(for: shell)
        let marker = "# CLIProxyAPI Configuration for \(agent.displayName)"
        let endMarker = "# End CLIProxyAPI Configuration for \(agent.displayName)"
        
        if agent == .claudeCode, fileManager.fileExists(atPath: profilePath) { _ = try createBackup(shell: shell) }
        let before = fileManager.fileExists(atPath: profilePath)
            ? try String(contentsOfFile: profilePath, encoding: .utf8) : ""
        var content = try removingManagedBlocks(before, marker: marker, endMarker: endMarker)

        let newConfig = """
        
        \(marker)
        \(configuration)
        \(endMarker)
        """
        
        content.append(newConfig)
        
        if fileManager.fileExists(atPath: profilePath) {
            let current = try String(contentsOfFile: profilePath, encoding: .utf8)
            guard current == before else {
                throw ShellProfileError.changed
            }
        }
        try writeProfile(content, URL(fileURLWithPath: profilePath).resolvingSymlinksInPath().path)
    }

    func removeFromProfile(
        shell: ShellType,
        agent: CLIAgent
    ) async throws {
        let profilePath = getProfilePath(for: shell)
        let marker = "# CLIProxyAPI Configuration for \(agent.displayName)"
        let endMarker = "# End CLIProxyAPI Configuration for \(agent.displayName)"

        guard fileManager.fileExists(atPath: profilePath) else { return }

        let before = try String(contentsOfFile: profilePath, encoding: .utf8)
        let content = try removingManagedBlocks(before, marker: marker, endMarker: endMarker)
        guard content != before else { return }
        if agent == .claudeCode { _ = try createBackup(shell: shell) }
        let currentAfter = try String(contentsOfFile: profilePath, encoding: .utf8)
        guard currentAfter == before else {
            throw ShellProfileError.changed
        }
        try writeProfile(content, URL(fileURLWithPath: profilePath).resolvingSymlinksInPath().path)
    }

    /// 历史版本可能重复追加管理段；逐段撤下，保留区间外每个字节及命令换行。
    /// 标记不成对时禁止追加／清理，避免保留旧高优先级变量却报告成功，或误删后续用户命令。
    private func removingManagedBlocks(_ original: String, marker: String, endMarker: String) throws -> String {
        var content = original
        while let start = content.range(of: marker) {
            guard let end = content.range(of: endMarker, range: start.upperBound..<content.endIndex) else {
                throw ShellProfileError.incompleteBlock
            }
            var upper = end.upperBound
            if upper < content.endIndex, content[upper] == "\n" { upper = content.index(after: upper) }
            content.removeSubrange(start.lowerBound..<upper)
        }
        return content
    }

    enum ShellProfileError: LocalizedError {
        case incompleteBlock, changed
        var errorDescription: String? {
            switch self {
            case .incompleteBlock: "agents.catalog.shellMalformed".localizedStatic()
            case .changed: "agents.catalog.fileChanged".localizedStatic()
            }
        }
    }

    func isConfiguredInProfile(
        shell: ShellType,
        agent: CLIAgent
    ) -> Bool {
        let profilePath = getProfilePath(for: shell)
        let marker = "# CLIProxyAPI Configuration for \(agent.displayName)"
        
        guard let content = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
            return false
        }
        
        return content.contains(marker)
    }
    
    func createBackup(shell: ShellType) throws -> String {
        let profilePath = getProfilePath(for: shell)
        var timestamp = Int(Date().timeIntervalSince1970)
        var backupPath = "\(profilePath).backup.\(timestamp)"
        // 同秒内保存／恢复也必须保留每份备份，不能覆盖旧文件或因重名跳过保护。
        while fileManager.fileExists(atPath: backupPath) {
            timestamp += 1
            backupPath = "\(profilePath).backup.\(timestamp)"
        }
        
        if fileManager.fileExists(atPath: profilePath) {
            try Data(contentsOf: URL(fileURLWithPath: profilePath)).write(to: URL(fileURLWithPath: backupPath), options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
        }
        
        return backupPath
    }
}
