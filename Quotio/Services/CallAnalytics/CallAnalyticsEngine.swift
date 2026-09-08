// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 基于 AIUsage CallAnalyticsEngine 移植；Quotio 增加取消传播、来源失败隔离以及冷启动缓存。
import Foundation

/// 文件扫描串行运行在独立 actor，不阻塞 SwiftUI 主线程；只有摘要会交给展示层。
actor CallAnalyticsEngine {
    static let shared = CallAnalyticsEngine()
    private let homeDirectory: String
    private let timeZone: TimeZone
    private let environment: [String: String]
    private let archive: CallAnalyticsArchiveStore

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
         timeZone: TimeZone = .current, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
        archive = CallAnalyticsArchiveStore(homeDirectory: homeDirectory)
    }

    func cachedSnapshot() throws -> CallAnalyticsSnapshot { try archive.load() }

    /// 来源未变化时直接复用 SQL 日摘要；变化来源仍重建完整日聚合后按高水位合并。
    /// 当前阶段是来源级跳扫，不宣称逐文件追加解析；取消时绝不提交半份扫描或成功指纹。
    func refresh() throws -> CallAnalyticsSnapshot {
        try Task.checkCancellation()
        let archiveTimeZone = try archive.aggregationTimeZone(preferred: timeZone)
        let cached = try archive.load()
        let inventory = CallAnalyticsInventory(homeDirectory: homeDirectory, environment: environment)
        let skills = inventory.installedSkills()
        let servers = inventory.installedMCPServers()
        let knownServers = Set(servers.filter { $0.source == .opencode }.map(\.name))
        let checkpoints = CallAnalyticsScanCheckpoint(homeDirectory: homeDirectory, timeZone: archiveTimeZone, environment: environment)
        var entries: [CallAnalyticsEntry] = []
        var statuses: [CallSourceStatus] = []
        var invocations: [AgentInvocationCount] = []
        var scannedSources = Set<CallSourceKind>()
        var successfulFingerprints: [CallSourceKind: String] = [:]
        for source in CallSourceKind.allCases {
            try Task.checkCancellation()
            do {
                let before = try checkpoints.fingerprint(for: source, knownMCPServers: knownServers)
                if let previous = cached.sources.first(where: { $0.source == source }), previous.errorCode == nil,
                   try archive.successfulFingerprint(for: source) == before {
                    // 日行已经在数据库内，无须把旧快照再次作为 fresh 输入重写；状态保留真实来源数量。
                    statuses.append(CallSourceStatus(source: source, available: previous.available,
                        eventCount: previous.eventCount, filesScanned: 0, errorCode: nil))
                    continue
                }
                scannedSources.insert(source)
                switch source {
                case .pi:
                    // Pi 与其他客户端一样只读取本地事件，CPA 请求不会进入工具调用账本。
                    let result = try PiCallEventSource(homeDirectory: homeDirectory, timeZone: archiveTimeZone, environment: environment).collect(cutoff: nil)
                    entries += result.entries; statuses.append(result.status)
                case .claude:
                    let result = try ClaudeCallEventSource(homeDirectory: homeDirectory, timeZone: archiveTimeZone, environment: environment).collect(cutoff: nil)
                    entries += result.entries; statuses.append(result.status)
                    // 保留上游的会话日桶，纯文本子代理同样进入归档；空键代表日期未知。
                    invocations = result.agentInvocationsByDay.flatMap { day, values in
                        values.map { AgentInvocationCount(source: $0.source, agent: $0.agent,
                            count: $0.count, dayKey: day.isEmpty ? nil : day) }
                    }
                case .codex:
                    let result = try CodexCallEventSource(homeDirectory: homeDirectory, timeZone: archiveTimeZone, environment: environment).collect(cutoff: nil)
                    entries += result.entries; statuses.append(result.status)
                case .opencode:
                    let result = try OpenCodeCallEventSource(homeDirectory: homeDirectory, timeZone: archiveTimeZone, environment: environment, knownMCPServers: knownServers).collect(cutoff: nil)
                    entries += result.entries; statuses.append(result.status)
                }
                // 只有扫描前后来源完全一致且解析无部分错误，才推进成功指纹。
                // 扫描中追加的日志会在下一轮重试，避免把尚未读到的内容永久跳过。
                if statuses.last?.errorCode == nil,
                   try checkpoints.fingerprint(for: source, knownMCPServers: knownServers) == before {
                    successfulFingerprints[source] = before
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 失败不伪装成零调用；其它来源仍可展示，归档保留该来源已有统计。
                scannedSources.insert(source)
                statuses.removeAll { $0.source == source }
                statuses.append(CallSourceStatus(source: source, available: true, eventCount: 0, filesScanned: 0, errorCode: "read_failed"))
            }
        }
        try Task.checkCancellation()
        return try archive.merge(CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: entries,
            installedSkills: skills, installedMCPServers: servers, agentInvocations: invocations, sources: statuses,
            aggregationTimeZoneIdentifier: archiveTimeZone.identifier),
            scannedSources: scannedSources, successfulFingerprints: successfulFingerprints)
    }
}
