//
//  TerminalLauncherTests.swift
//  QuotioTests
//
//  Tests for TerminalLauncher, terminal selection settings, and agent lifecycle commands.
//

import AppKit
import Foundation
import XCTest
@testable import QuotioPlus

@MainActor
final class TerminalLauncherTests: XCTestCase {
    func testInstalledTerminalsAlwaysIncludesAutoAndDetectsSystemTerminal() {
        let terminals = TerminalLauncher.shared.installedTerminals()
        XCTAssertFalse(terminals.isEmpty)
        XCTAssertEqual(terminals.first?.id, "auto")
        XCTAssertEqual(terminals.first?.isInstalled, true)

        let systemTerminal = terminals.first { $0.id == "com.apple.Terminal" }
        XCTAssertNotNil(systemTerminal, "macOS 系统终端应被成功探测到")
        XCTAssertNotNil(systemTerminal?.appURL)
    }

    func testTerminalPreferencePersistence() {
        let suite = "quotio-terminal-pref-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Failed to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = MenuBarSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.selectedTerminalBundleID, "auto")

        settings.selectedTerminalBundleID = "com.googlecode.iterm2"
        XCTAssertEqual(settings.selectedTerminalBundleID, "com.googlecode.iterm2")
        XCTAssertEqual(defaults.string(forKey: "selectedTerminalBundleID"), "com.googlecode.iterm2")

        let reloaded = MenuBarSettingsManager(defaults: defaults)
        XCTAssertEqual(reloaded.selectedTerminalBundleID, "com.googlecode.iterm2")
    }

    func testCLIAgentLifecycleCommands() {
        for agent in CLIAgent.allCases {
            guard let pkg = agent.npmPackageName else { continue }
            XCTAssertFalse(pkg.isEmpty)
            XCTAssertEqual(agent.defaultInstallCommand, "npm install -g \(pkg)")
            XCTAssertEqual(agent.defaultUpgradeCommand, "npm install -g \(pkg)@latest")
            XCTAssertEqual(agent.defaultUninstallCommand, "npm uninstall -g \(pkg)")
        }
    }

    /// 执行的只有临时脚本和夹具 shell，不拉起终端、不 source 用户真实配置，也不运行真实包管理器。
    func testCommandRunnerUsesOwnShellAndTreatsDisplayAndDirectoryAsLiteral() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = directory.appendingPathComponent("dir ' $(touch must-not-run) `touch also-not-run`")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let shell = directory.appendingPathComponent("fixture-shell")
        let args = directory.appendingPathComponent("args")
        // 记录外层确实使用 -lic，随后由夹具代替用户 shell 启动 POSIX 正文。
        try "#!/bin/sh\nprintf '%s' \"$1\" > \(ShellCommand.argument(args.path))\nexec /bin/sh -c \"$2\"\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let script = directory.appendingPathComponent("runner ' $.command")
        let output = directory.appendingPathComponent("actual-directory")
        let pathOutput = directory.appendingPathComponent("actual-path")
        let command = "pwd > " + ShellCommand.argument(output.path)
            + "; printf '%s' \"$PATH\" > " + ShellCommand.argument(pathOutput.path) + "; false"
        let body = TerminalLauncher.commandScript(command: command, directory: work.path,
            shell: shell.path, scriptPath: script.path, keepsShellOpen: false)
        try body.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["PATH": "/fixture-chosen-node:/usr/bin:/bin", "HOME": directory.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1, "保留实际命令退出码")
        XCTAssertEqual(try String(contentsOf: args, encoding: .utf8), "-lic")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .newlines), work.path)
        XCTAssertTrue(try String(contentsOf: pathOutput, encoding: .utf8).hasPrefix("/fixture-chosen-node:/usr/bin:/bin:"),
            "原 shell 已选中的包管理器必须保留优先级")
        XCTAssertFalse(body.contains("source "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("must-not-run").path))
    }

    func testPackageUninstallFailureDoesNotDeleteBinaryOrConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("native-cli")
        try Data("native".utf8).write(to: executable)
        let npm = directory.appendingPathComponent("npm")
        try "#!/bin/sh\nexit 7\n".write(to: npm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentInstallMethod.npm(package: "fixture-package").uninstallCommand(for: .claudeCode, binaryPath: executable.path)]
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 7)
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "native")
    }

    func testSettingsTopicIncludesTerminalUnderGeneral() {
        let generalTopics = SettingsCategory.general.topics
        XCTAssertTrue(generalTopics.contains(.terminal))
        XCTAssertEqual(SettingsTopic.terminal.category, .general)
        XCTAssertTrue(SettingsTopic.terminal.matches("终端"))
        XCTAssertTrue(SettingsTopic.terminal.matches("terminal"))
        XCTAssertTrue(SettingsTopic.terminal.matches("ghostty"))
        XCTAssertTrue(SettingsTopic.terminal.matches("iterm"))
    }
}
