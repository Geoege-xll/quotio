import Foundation

/// 只接受 Pi SessionMessageEntry 的结构化工具声明及 toolResult，不搜索正文中的工具名称。
/// 工具声明和返回共享一次调用；缺少返回只表示结果未知，不伪造成功率或执行耗时。
nonisolated struct PiCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    private struct Call {
        let name: String
        let kind: CallKind
        let server: String?
        let timestamp: Date
        var success: Bool?
    }

    func collect(cutoff: Date?) throws -> (entries: [CallAnalyticsEntry], status: CallSourceStatus) {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        var available = false
        var hadErrors = false
        var paths = Set<String>()
        var calls: [String: Call] = [:]
        var filesScanned = 0
        for root in PiSessionPaths.sessionRoots(homeDirectory: homeDirectory, environment: environment)
            where FileManager.default.fileExists(atPath: root) {
            available = true
            do { paths.formUnion(try ClientUsageFiles.jsonlFiles(roots: [root])) }
            catch is CancellationError { throw CancellationError() }
            catch { hadErrors = true }
        }
        for path in paths.sorted() {
            try Task.checkCancellation()
            // 结果只关联当前文件中最近出现的相同 toolCallId，避免不同请求复用短 ID 时串线。
            var identities: [String: String] = [:]
            do {
                let stamp = try CodexUsageFileStamp(path: path)
                let result = try CodexUsageLineReader.read(path: path, offset: 0, limit: stamp.size,
                    acceptFinalLine: false, progress: { _ in }) { line in
                    let entry: [String: Any]
                    do {
                        guard let decoded = try PiSessionEntry.decode(line) else { return }
                        entry = decoded
                    } catch { hadErrors = true; return }
                    guard let type = entry["type"] as? String else { hadErrors = true; return }
                    guard type == "message", let message = entry["message"] as? [String: Any] else { return }
                    if message["role"] as? String == "toolResult" {
                        if let id = message["toolCallId"] as? String, let identity = identities[id],
                           let isError = message["isError"] as? Bool { calls[identity]?.success = !isError }
                        return
                    }
                    guard message["role"] as? String == "assistant" else { return }
                    guard let parts = message["content"] as? [[String: Any]],
                          let entryID = entry["id"] as? String, !entryID.isEmpty,
                          let date = PiSessionPaths.timestamp(entry: entry, message: message, clock: clock) else {
                        hadErrors = true; return
                    }
                    for part in parts where part["type"] as? String == "toolCall" {
                        guard let id = part["id"] as? String, !id.isEmpty,
                              let name = part["name"] as? String, !name.isEmpty else { hadErrors = true; continue }
                        let identity = ClientUsageDigest.sha256("\(entryID):\(date.timeIntervalSince1970):\(id)")
                        identities[id] = identity
                        guard calls[identity] == nil else { continue }
                        let classified = Self.classify(name: name, arguments: part["arguments"] as? [String: Any])
                        calls[identity] = Call(name: classified.name, kind: classified.kind,
                                               server: classified.server, timestamp: date)
                    }
                }
                hadErrors = hadErrors || result.oversized
                filesScanned += 1
            } catch is CancellationError { throw CancellationError() }
            catch { hadErrors = true }
        }
        var accumulator = CallEventAccumulator()
        for call in calls.values where cutoff == nil || call.timestamp >= cutoff! {
            accumulator.add(source: .pi, kind: call.kind, name: call.name, server: call.server,
                            dayKey: clock.dayKey(call.timestamp), success: call.success)
        }
        return (accumulator.entries(), CallSourceStatus(source: .pi, available: available,
            eventCount: accumulator.eventCount, filesScanned: filesScanned, errorCode: hadErrors ? "read_partial" : nil))
    }

    private static func classify(name: String, arguments: [String: Any]?) -> (name: String, kind: CallKind, server: String?) {
        if let mcp = CallAnalyticsNaming.parseClaudeMCP(name), !mcp.server.isEmpty {
            // Pi 的扩展没有统一 MCP 注册协议，只对明确带 server/tool 命名的调用进行归类。
            let server = String(mcp.server.prefix(256))
            return (CallAnalyticsNaming.mcpDisplayName(server: server, tool: String(mcp.tool.prefix(256))), .mcp, server)
        }
        if name == "read", let path = arguments?["path"] as? String, path.hasSuffix("/SKILL.md") {
            let skill = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            if !skill.isEmpty, skill.count <= 128, skill.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                // 与现有客户端一致，读取 SKILL.md 仅代表技能使用的启发式信号；不持久化原路径。
                return (skill, .skill, nil)
            }
        }
        return (String(name.prefix(512)), .builtin, nil)
    }
}
