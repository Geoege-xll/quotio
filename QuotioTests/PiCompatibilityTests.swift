import XCTest
@testable import Quotio

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
