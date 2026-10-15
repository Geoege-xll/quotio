import XCTest
@testable import QuotioPlus

/// 使用隔离的安装目录和匿名会话覆盖本机问题；测试不运行用户的 Pi、不读取凭据、不写真实统计库。
final class PiCompatibilityTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotio-pi-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ contents: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    private func installation(_ home: URL, environment: [String: String] = [:], system: [String] = []) -> PiAgentInstallation {
        PiAgentInstallation(homeDirectory: home.path, environment: environment, systemBinaryDirectories: system)
    }

    private func assistant(id: String = "parent", call: String = "tool-1") -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"2026-09-06T08:00:00Z","message":{"role":"assistant","timestamp":1788681600000,"model":"test-model","provider":"test-provider","content":[{"type":"toolCall","id":"\(call)","name":"read","arguments":{"path":"file.swift"}}],"usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":5,"reasoning":10,"totalTokens":155}}}
        """
    }

    private func result(call: String = "tool-1", isError: Bool = false) -> String {
        """
        {"type":"message","id":"result-\(call)","timestamp":"2026-09-06T08:00:01Z","message":{"role":"toolResult","toolCallId":"\(call)","isError":\(isError),"content":[]}}
        """
    }

    private func transcript(kind: String = "message") -> String {
        """
        {"version":1,"recordType":"\(kind)","source":"async","runId":"run-1","agent":"worker","timestamp":"2026-09-06T08:00:00Z","message":{"role":"assistant","usage":{"input":99999,"output":88888},"content":[]}}
        """
    }

    private func session(_ home: URL, name: String, lines: [String]) throws -> URL {
        let file = home.appendingPathComponent(".pi/agent/sessions/project/" + name)
        try write(lines.joined(separator: "\n") + "\n", to: file)
        return file
    }

    func testPackageManagerAndStandaloneLocationsWorkWithoutShellPATH() throws {
        // 包括 Homebrew 的两种架构前缀、官方安装脚本/npm、本地 Bun/pnpm/Yarn 和版本管理器 shim。
        for relative in ["opt/homebrew/bin", "usr/local/bin", ".local/bin", "bin", ".npm-global/bin", ".bun/bin",
                         "Library/pnpm", ".local/share/pnpm", ".yarn/bin", ".volta/bin", ".asdf/shims", ".local/share/mise/shims"] {
            let home = try temporary()
            let binary = home.appendingPathComponent(relative + "/pi")
            try write("#!/bin/sh\nexit 0\n", to: binary, executable: true)
            let resolver = installation(home, system: [home.appendingPathComponent("opt/homebrew/bin").path,
                                                     home.appendingPathComponent("usr/local/bin").path])
            XCTAssertEqual(resolver.findBinary(), binary.path, relative)
        }
    }

    func testExplicitPrefixesAndPATHAreRespected() throws {
        for (key, suffix) in [("HOMEBREW_PREFIX", "/bin"), ("NPM_CONFIG_PREFIX", "/bin"),
                              ("npm_config_prefix", "/bin"), ("PNPM_HOME", ""), ("BUN_INSTALL", "/bin"),
                              ("VOLTA_HOME", "/bin"), ("ASDF_DATA_DIR", "/shims"), ("PATH", "")] {
            let home = try temporary(), prefix = try temporary()
            let binary = URL(fileURLWithPath: prefix.path + suffix + "/pi")
            try write("#!/bin/sh\nexit 0\n", to: binary, executable: true)
            XCTAssertEqual(installation(home, environment: [key: prefix.path]).findBinary(), binary.path, key)
        }
    }

    func testNodeVersionManagersPreferNumericNewestAndMacFNMDirectory() throws {
        let home = try temporary()
        for version in ["v9.0.0", "v22.19.0"] {
            try write("#!/bin/sh\n", to: home.appendingPathComponent(".nvm/versions/node/\(version)/bin/pi"), executable: true)
        }
        XCTAssertTrue(try XCTUnwrap(installation(home).findBinary()).contains("v22.19.0"))
        for (key, base) in [("NVM_DIR", "versions/node/v24.0.0/bin"), ("FNM_DIR", "node-versions/v24.0.0/installation/bin")] {
            let custom = try temporary(), emptyHome = try temporary()
            let binary = custom.appendingPathComponent(base + "/pi")
            try write("#!/bin/sh\n", to: binary, executable: true)
            XCTAssertEqual(installation(emptyHome, environment: [key: custom.path]).findBinary(), binary.path)
        }
        let macHome = try temporary()
        let binary = macHome.appendingPathComponent("Library/Application Support/fnm/node-versions/v24.0.0/installation/bin/pi")
        try write("#!/bin/sh\n", to: binary, executable: true)
        XCTAssertEqual(installation(macHome).findBinary(), binary.path)
    }

    func testNewAndLegacyNPMPackageVersionsResolveThroughSymlinks() async throws {
        for name in ["@earendil-works/pi-coding-agent", "@mariozechner/pi-coding-agent"] {
            let home = try temporary()
            let package = home.appendingPathComponent(".local/lib/node_modules/" + name)
            // 探测不应执行脚本；若误执行会写出 sentinel 并返回错误版本。
            let sentinel = home.appendingPathComponent("executed")
            try write("#!/bin/sh\ntouch '\(sentinel.path)'\nexit 1\n", to: package.appendingPathComponent("dist/cli.js"), executable: true)
            try write("{\"name\":\"\(name)\",\"version\":\"0.84.2\"}", to: package.appendingPathComponent("package.json"))
            let binary = home.appendingPathComponent(".local/bin/pi")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: package.appendingPathComponent("dist/cli.js"))
            let resolver = installation(home)
            XCTAssertEqual(resolver.findBinary(), binary.path)
            let version = await resolver.version(binaryPath: binary.path)
            XCTAssertEqual(version, "0.84.2")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    func testVersionProbeAndInstallerEnvironmentCanFindNodeFromGUI() async throws {
        let home = try temporary()
        let binary = home.appendingPathComponent(".local/bin/pi")
        try write("#!/usr/bin/env node\n", to: binary, executable: true)
        let node = home.appendingPathComponent("runtime/bin/node")
        try write("#!/bin/sh\nprintf '0.84.2\\n'\n", to: node, executable: true)
        let resolver = installation(home, environment: ["PATH": "/usr/bin:/bin"], system: [node.deletingLastPathComponent().path])
        let version = await resolver.version(binaryPath: binary.path)
        XCTAssertEqual(version, "0.84.2")
        XCTAssertTrue(try XCTUnwrap(resolver.processEnvironment(binaryPath: binary.path)["PATH"]).hasPrefix(binary.deletingLastPathComponent().path + ":"))
    }

    func testFailedVersionOutputIsNotPresentedAsVersion() async throws {
        let home = try temporary(), binary = home.appendingPathComponent(".local/bin/pi")
        for contents in ["#!/bin/sh\nprintf '0.84.2\\n'\nexit 1\n", "#!/bin/sh\nprintf 'env: node: No such file or directory\\n'\n"] {
            try write(contents, to: binary, executable: true)
            let version = await installation(home).version(binaryPath: binary.path)
            XCTAssertNil(version)
        }
    }

    func testUnresponsiveVersionProbeDoesNotBlockAgentDetection() async throws {
        let home = try temporary(), binary = home.appendingPathComponent("bin/pi")
        // exec 让被测子进程本身阻塞，验证超时能结束探测，且不会留下 shell 派生的睡眠进程。
        try write("#!/bin/sh\nexec /bin/sleep 30\n", to: binary, executable: true)
        let start = ContinuousClock.now
        let version = await installation(home).version(binaryPath: binary.path)
        XCTAssertNil(version)
        XCTAssertLessThan(start.duration(to: .now), .seconds(10))
    }

    func testSessionHistoryAndBrokenSymlinksDoNotMeanInstalled() throws {
        let home = try temporary()
        _ = try session(home, name: "history.jsonl", lines: [assistant()])
        let binary = home.appendingPathComponent(".local/bin/pi")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: binary.path, withDestinationPath: home.appendingPathComponent("missing").path)
        XCTAssertNil(installation(home).findBinary())
    }

    func testInstalledAndConfiguredStatusesHaveSeparateLocalizationKeys() {
        var status = AgentStatus(agent: .pi, installed: true, configured: false)
        XCTAssertEqual(status.statusLocalizationKey, "agents.installed")
        status.configured = true
        XCTAssertEqual(status.statusLocalizationKey, "agents.configured")
        status.installed = false
        XCTAssertEqual(status.statusLocalizationKey, "agents.notInstalled")
    }

    func testAgentInstallMethodDetectionAndCommandGeneration() {
        // 1. Homebrew Cask 探测与命令
        let caskMethod = AgentInstallMethod.detect(for: .claudeCode, binaryPath: "/opt/homebrew/Caskroom/claude-code/2.1.292/claude")
        XCTAssertEqual(caskMethod, .homebrewCask(name: "claude-code"))
        XCTAssertEqual(caskMethod.displayName, "Homebrew (Cask)")
        XCTAssertEqual(caskMethod.upgradeCommand(for: .claudeCode), "brew upgrade --cask claude-code")
        XCTAssertEqual(caskMethod.uninstallCommand(for: .claudeCode), "brew uninstall --cask claude-code")

        // 2. Homebrew Formula 探测与命令
        let formulaMethod = AgentInstallMethod.detect(for: .openCode, binaryPath: "/opt/homebrew/Cellar/opencode/0.1.0/bin/opencode")
        XCTAssertEqual(formulaMethod, .homebrewFormula(name: "opencode"))
        XCTAssertEqual(formulaMethod.displayName, "Homebrew")
        XCTAssertEqual(formulaMethod.upgradeCommand(for: .openCode), "brew upgrade opencode")
        XCTAssertEqual(formulaMethod.uninstallCommand(for: .openCode), "brew uninstall opencode")

        // 3. 只有前缀不能确认包管理器；不存在的入口保持未知，不读取测试机的真实 Homebrew。
        XCTAssertEqual(AgentInstallMethod.detect(for: .claudeCode,
            binaryPath: "/isolated/opt/homebrew/bin/claude"), .unknown)

        // 4. npm 全局 / NVM 目录探测
        let npmMethod = AgentInstallMethod.detect(for: .claudeCode, binaryPath: "/Users/test/.nvm/versions/node/v20.10.0/bin/claude")
        XCTAssertEqual(npmMethod, .npm(package: "@anthropic-ai/claude-code"))
        XCTAssertEqual(npmMethod.displayName, "npm")
        XCTAssertEqual(npmMethod.upgradeCommand(for: .claudeCode), "npm install -g @anthropic-ai/claude-code@latest")
        XCTAssertEqual(npmMethod.uninstallCommand(for: .claudeCode), "npm uninstall -g @anthropic-ai/claude-code")

        // 5. pnpm 目录探测
        let pnpmMethod = AgentInstallMethod.detect(for: .claudeCode, binaryPath: "/Users/test/Library/pnpm/claude")
        XCTAssertEqual(pnpmMethod, .pnpm(package: "@anthropic-ai/claude-code"))
        XCTAssertEqual(pnpmMethod.displayName, "pnpm")
        XCTAssertEqual(pnpmMethod.upgradeCommand(for: .claudeCode), "pnpm add -g @anthropic-ai/claude-code@latest")
        XCTAssertEqual(pnpmMethod.uninstallCommand(for: .claudeCode), "pnpm remove -g @anthropic-ai/claude-code")

        // 6. bun 目录探测
        let bunMethod = AgentInstallMethod.detect(for: .claudeCode, binaryPath: "/Users/test/.bun/bin/claude")
        XCTAssertEqual(bunMethod, .bun(package: "@anthropic-ai/claude-code"))
        XCTAssertEqual(bunMethod.displayName, "bun")
        XCTAssertEqual(bunMethod.upgradeCommand(for: .claudeCode), "bun add -g @anthropic-ai/claude-code@latest")
        XCTAssertEqual(bunMethod.uninstallCommand(for: .claudeCode), "bun remove -g @anthropic-ai/claude-code")

        // 7. 独立安装脚本 (例如 opencode ~/.opencode/bin)
        let standaloneMethod = AgentInstallMethod.detect(for: .openCode, binaryPath: "/Users/test/.opencode/bin/opencode")
        XCTAssertEqual(standaloneMethod, .standalone(binaryPath: "/Users/test/.opencode/bin/opencode"))
        XCTAssertEqual(standaloneMethod.upgradeCommand(for: .openCode), "/Users/test/.opencode/bin/opencode upgrade")
        XCTAssertEqual(standaloneMethod.uninstallCommand(for: .openCode), "rm -f -- /Users/test/.opencode/bin/opencode")

        // 8. 空路径 / 未知
        XCTAssertEqual(AgentInstallMethod.detect(for: .claudeCode, binaryPath: nil), .unknown)
        XCTAssertEqual(AgentInstallMethod.detect(for: .claudeCode, binaryPath: ""), .unknown)

        // 9. AgentStatus 升级与卸载命令动态映射
        let status = AgentStatus(
            agent: .claudeCode,
            installed: true,
            configured: true,
            binaryPath: "/opt/homebrew/bin/claude",
            version: "2.1.292",
            installMethod: .homebrewCask(name: "claude-code")
        )
        XCTAssertEqual(status.upgradeCommand, "brew upgrade --cask claude-code")
        XCTAssertEqual(status.uninstallCommand, "brew uninstall --cask claude-code")

        // 10. npm 自行处理包入口，不能在卸载失败后额外删除二进制文件。
        let npmStatus = AgentStatus(
            agent: .pi,
            installed: true,
            configured: false,
            binaryPath: "/Users/test/.local/bin/pi",
            version: "0.85.1",
            installMethod: .npm(package: "@earendil-works/pi-coding-agent")
        )
        XCTAssertEqual(npmStatus.upgradeCommand, "npm install -g @earendil-works/pi-coding-agent@latest")
        XCTAssertTrue(npmStatus.uninstallCommand.contains("npm uninstall -g @earendil-works/pi-coding-agent"))
        XCTAssertFalse(npmStatus.uninstallCommand.contains("rm "))
    }

    func testDynamicPackageNameDetectionFromNodeModules() throws {
        let home = try temporary()
        let packageDir = home.appendingPathComponent("lib/node_modules/@earendil-works/pi-coding-agent")
        let binDir = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: packageDir.appendingPathComponent("dist/bundle"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let packageJSON = packageDir.appendingPathComponent("package.json")
        try Data("{\"name\": \"@earendil-works/pi-coding-agent\", \"version\": \"0.85.1\"}".utf8).write(to: packageJSON)

        let script = packageDir.appendingPathComponent("dist/bundle/cli.js")
        try write("#!/usr/bin/env node\n", to: script, executable: true)

        let symlink = binDir.appendingPathComponent("pi")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: script)

        let method = AgentInstallMethod.detect(for: .pi, binaryPath: symlink.path)
        XCTAssertEqual(method, .npm(package: "@earendil-works/pi-coding-agent"))
    }

    func testNativeBinariesRemainStandaloneAndUpgradeTheDetectedEntry() throws {
        let home = try temporary()
        for agent in [CLIAgent.claudeCode, .codexCLI, .openCode] {
            let path = home.appendingPathComponent("native bin/\(agent.binaryNames[0])")
            try write("#!/bin/sh\n", to: path, executable: true)
            let method = AgentInstallMethod.detect(for: agent, binaryPath: path.path)
            XCTAssertEqual(method, .standalone(binaryPath: path.path))
            let command = method.upgradeCommand(for: agent)
            XCTAssertTrue(command.hasPrefix(ShellCommand.argument(path.path)))
            XCTAssertFalse(command.contains("npm"))
        }
        XCTAssertTrue(AgentInstallMethod.unknown.upgradeCommand(for: .claudeCode).isEmpty)
        XCTAssertTrue(AgentInstallMethod.unknown.uninstallCommand(for: .claudeCode).isEmpty)
    }

    func testHomebrewPrefixNpmLinkUsesActualNodePackage() throws {
        // 精确覆盖旧实现的 hasPrefix("/opt/homebrew/")，不创建或读取真实包文件。
        XCTAssertEqual(AgentInstallMethod.detect(for: .claudeCode,
            binaryPath: "/opt/homebrew/lib/node_modules/quotio-fixture-\(UUID().uuidString)/cli.js"),
            .npm(package: "@anthropic-ai/claude-code"))
        let home = try temporary()
        let binary = home.appendingPathComponent("opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js")
        try write("#!/usr/bin/env node\n", to: binary, executable: true)
        try write(#"{"name":"@anthropic-ai/claude-code"}"#, to: binary.deletingLastPathComponent().appendingPathComponent("package.json"))
        let entry = home.appendingPathComponent("opt/homebrew/bin/claude")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: binary)
        XCTAssertEqual(AgentInstallMethod.detect(for: .claudeCode, binaryPath: entry.path), .npm(package: "@anthropic-ai/claude-code"))
    }

    @MainActor
    func testLifecycleFailureAndUnknownSourceUseVisibleCardMessageWithoutLosingState() async {
        var launched: [String] = []
        let vm = AgentSetupViewModel(launchCommand: { command in
            launched.append(command)
            throw NSError(domain: "fixture-launch", code: 7, userInfo: [NSLocalizedDescriptionKey: "fixture terminal failure"])
        })
        let status = AgentStatus(agent: .claudeCode, installed: true, configured: true,
            binaryPath: "/fixture/claude", installMethod: .npm(package: "@anthropic-ai/claude-code"))
        vm.agentStatuses = [status]
        await vm.upgradeAgent(status)
        XCTAssertEqual(vm.updateMessages[.claudeCode], "fixture terminal failure")
        await vm.uninstallAgent(status)
        XCTAssertEqual(vm.updateMessages[.claudeCode], "fixture terminal failure")
        XCTAssertEqual(launched.count, 2)
        XCTAssertTrue(vm.agentStatuses.first?.configured == true)
        var unknown = status
        unknown.installMethod = .unknown
        await vm.upgradeAgent(unknown)
        XCTAssertEqual(vm.updateMessages[.claudeCode], "agents.update.manualSource".localized())
        await vm.uninstallAgent(unknown)
        await vm.upgradeAgent(.codexCLI)
        await vm.uninstallAgent(.codexCLI)
        XCTAssertEqual(vm.updateMessages[.codexCLI], "agents.update.manualSource".localized())
        XCTAssertEqual(launched.count, 2, "未知来源不能偷偷启动 npm 或删除入口")
    }

    @MainActor
    func testCleanVersionStringAndHasNewerVersionLogic() {
        // 1. 版本号解析验证
        XCTAssertEqual(AgentSetupViewModel.cleanVersionString("2.1.292 (Claude Code)"), "2.1.292")
        XCTAssertEqual(AgentSetupViewModel.cleanVersionString("v0.85.1"), "0.85.1")
        XCTAssertEqual(AgentSetupViewModel.cleanVersionString("0.85.1"), "0.85.1")
        XCTAssertEqual(AgentSetupViewModel.cleanVersionString("codex-cli 0.1.0"), "0.1.0")

        // 2. 版本比对与升级按钮显示逻辑
        let vm = AgentSetupViewModel()
        let claudeStatus = AgentStatus(
            agent: .claudeCode,
            installed: true,
            configured: true,
            binaryPath: "/usr/local/bin/claude",
            version: "2.1.292 (Claude Code)"
        )

        // 场景 A：远程版本与本地版本一致 -> 已是最新，不应显示升级按钮
        vm.remoteVersions[.claudeCode] = "2.1.292"
        XCTAssertFalse(vm.hasNewerVersion(for: claudeStatus), "同版本或已是最新时，不得显示升级按钮")

        // 场景 B：远程版本低于本地版本 -> 本地更新，不应显示升级按钮
        vm.remoteVersions[.claudeCode] = "2.1.291"
        XCTAssertFalse(vm.hasNewerVersion(for: claudeStatus), "远程版本更低时不应显示升级按钮")

        // 场景 C：远程版本高于本地版本 -> 存在新版本，必须显示升级按钮
        vm.remoteVersions[.claudeCode] = "2.1.293"
        XCTAssertTrue(vm.hasNewerVersion(for: claudeStatus), "远程版本更高时必须触发升级提示与按钮")
    }

    func testNativeChildSessionsCountOnceWhileTranscriptsAreIgnored() throws {
        let home = try temporary()
        _ = try session(home, name: "parent.jsonl", lines: [assistant(), result()])
        // 正式子会话即使嵌套在 artifacts 下也必须保留；不能按目录整体排除。
        let child = [assistant(id: "child", call: "child-tool"), result(call: "child-tool", isError: true)]
        _ = try session(home, name: "subagent-artifacts/nested/session.jsonl", lines: child)
        _ = try session(home, name: "copied-child.jsonl", lines: child)
        _ = try session(home, name: "subagent-artifacts/transcript.jsonl",
                        lines: ["message", "tool_start", "tool_end", "stdout", "stderr", "truncated"].map { transcript(kind: $0) })
        let usage = try PiClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
        XCTAssertTrue(usage.available); XCTAssertFalse(usage.hasErrors)
        XCTAssertEqual(usage.records.count, 2); XCTAssertEqual(usage.records.reduce(0) { $0 + $1.total }, 310)
        XCTAssertEqual(usage.records.first?.input, 135); XCTAssertEqual(usage.records.first?.cached, 35)
        let calls = try PiCallEventSource(homeDirectory: home.path, timeZone: zone, environment: [:]).collect(cutoff: nil)
        XCTAssertNil(calls.status.errorCode); XCTAssertEqual(calls.status.eventCount, 2)
        XCTAssertEqual(calls.entries.reduce(0) { $0 + $1.successCount }, 1)
        XCTAssertEqual(calls.entries.reduce(0) { $0 + $1.outcomeKnownCount - $1.successCount }, 1)
    }

    func testMalformedRecordsStillReportPartialResultsInBothReaders() throws {
        for invalid in ["{broken", "{}", transcript().replacingOccurrences(of: "\"version\":1", with: "\"version\":1.5"),
                        transcript().replacingOccurrences(of: "\"recordType\":\"message\"", with: "\"recordType\":\"unknown\"")] {
            let home = try temporary()
            _ = try session(home, name: "session.jsonl", lines: [assistant(), result(), invalid])
            let usage = try PiClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
            XCTAssertTrue(usage.hasErrors); XCTAssertEqual(usage.records.count, 1)
            let calls = try PiCallEventSource(homeDirectory: home.path, timeZone: zone, environment: [:]).collect(cutoff: nil)
            XCTAssertEqual(calls.status.errorCode, "read_partial"); XCTAssertEqual(calls.status.eventCount, 1)
        }
    }

    func testTranscriptOnlyDirectoryDoesNotInventNativeUsageOrCalls() throws {
        let home = try temporary()
        _ = try session(home, name: "transcript-only.jsonl", lines: [transcript()])
        // 只有转录也不是损坏文件，但不能据此伪造正式会话统计；两页的 Pi 口径说明明确此覆盖限制。
        let usage = try PiClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
        let calls = try PiCallEventSource(homeDirectory: home.path, timeZone: zone, environment: [:]).collect(cutoff: nil)
        XCTAssertTrue(usage.available); XCTAssertFalse(usage.hasErrors); XCTAssertTrue(usage.records.isEmpty)
        XCTAssertTrue(calls.status.available); XCTAssertNil(calls.status.errorCode); XCTAssertEqual(calls.status.eventCount, 0)
    }

    func testCustomAgentAndSessionDirectoriesAreSharedByBothReaders() throws {
        let home = try temporary()
        let custom = home.appendingPathComponent("custom agent"), extra = home.appendingPathComponent("extra sessions")
        try write(assistant() + "\n", to: custom.appendingPathComponent("sessions/parent.jsonl"))
        try write(assistant(id: "child", call: "child-tool") + "\n", to: extra.appendingPathComponent("child.jsonl"))
        let environment = ["PI_CODING_AGENT_DIR": "~/custom agent", "PI_CODING_AGENT_SESSION_DIR": "~/extra sessions"]
        let usage = try PiClientUsageSource(homeDirectory: home.path, environment: environment).collect()
        let calls = try PiCallEventSource(homeDirectory: home.path, timeZone: zone, environment: environment).collect(cutoff: nil)
        XCTAssertFalse(usage.hasErrors); XCTAssertEqual(usage.records.count, 2)
        XCTAssertNil(calls.status.errorCode); XCTAssertEqual(calls.status.eventCount, 2)
    }

    func testOldPiErrorCacheRepairsAndPersistsWithoutResettingSQLite() throws {
        let home = try temporary()
        let file = try session(home, name: "transcript.jsonl", lines: [transcript()])
        let store = ClientUsageSQLiteStore(databaseURL: home.appendingPathComponent("analytics.sqlite"))
        var old = try store.loadLineCache(source: .pi, legacyURL: nil)
        // 模拟旧版把辅助日志标记为错误，文件指纹保持不变；新版必须主动重读并清除旧状态。
        old.files[ClaudeClientUsageReader.key(for: file.path)] = try ClaudeClientUsageReader.read(
            path: file.path, previous: nil, bytesRead: { _ in }, parse: { _ in (nil, true) })
        try store.saveLineCache(old, source: .pi)
        _ = try session(home, name: "session.jsonl", lines: [assistant(), result()])
        let source = PiClientUsageSource(homeDirectory: home.path, environment: [:])
        let repaired = try source.collect(cacheStore: store)
        XCTAssertFalse(repaired.hasErrors); XCTAssertEqual(repaired.records.count, 1)
        let reopened = try source.collect(cacheStore: ClientUsageSQLiteStore(databaseURL: home.appendingPathComponent("analytics.sqlite")))
        XCTAssertFalse(reopened.hasErrors); XCTAssertEqual(reopened.records, repaired.records)
    }

    func testCallAnalysisRefreshReusesSuccessfulPiSQLiteSnapshot() async throws {
        let home = try temporary()
        _ = try session(home, name: "session.jsonl", lines: [assistant(), result()])
        _ = try session(home, name: "transcript.jsonl", lines: [transcript()])
        let first = try await CallAnalyticsEngine(homeDirectory: home.path, timeZone: zone, environment: [:]).refresh()
        let initial = try XCTUnwrap(first.sources.first { $0.source == .pi })
        XCTAssertNil(initial.errorCode); XCTAssertEqual(initial.eventCount, 1); XCTAssertEqual(initial.filesScanned, 2)
        let next = try await CallAnalyticsEngine(homeDirectory: home.path, timeZone: zone, environment: [:]).refresh()
        let reused = try XCTUnwrap(next.sources.first { $0.source == .pi })
        XCTAssertNil(reused.errorCode); XCTAssertEqual(reused.eventCount, 1); XCTAssertEqual(reused.filesScanned, 0)
    }
}
