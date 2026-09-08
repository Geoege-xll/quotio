// 调用分析的展示聚合：仅接收脱敏后的计数条目，不访问原始会话和用户配置。
import Foundation

nonisolated enum CallAnalyticsDateRange: String, CaseIterable, Identifiable {
    case today, week, month, all, custom
    var id: String { rawValue }
    var localizationKey: String { "callAnalytics.range." + rawValue }

    /// 与用户本机日历一致；自定义结束日期包含完整一天，避免时间选择器零点遗漏当天调用。
    func bounds(now: Date, start: Date, end: Date, calendar: Calendar = .current) -> (String?, String?) {
        let clock = CallAnalyticsClock(timeZone: calendar.timeZone)
        switch self {
        case .all: return (nil, nil)
        case .today: return (clock.dayKey(calendar.startOfDay(for: now)), clock.dayKey(now))
        case .week:
            // 与参考统计页面一致固定周一开周，不依赖系统地区把周日设为一周首日。
            let weekday = calendar.component(.weekday, from: now)
            let offset = (weekday + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))
            return (monday.map(clock.dayKey), clock.dayKey(now))
        case .month: return (calendar.dateInterval(of: .month, for: now).map { clock.dayKey($0.start) }, clock.dayKey(now))
        case .custom: return (clock.dayKey(min(start, end)), clock.dayKey(max(start, end)))
        }
    }
}

nonisolated struct CallAnalyticsRanking: Identifiable {
    let source: CallSourceKind
    let kind: CallKind
    let name: String
    var count: Int
    var knownOutcomes: Int
    var successes: Int
    var durationSamples: Int
    var totalDuration: Double
    var id: String { source.rawValue + ":" + kind.rawValue + ":" + name }
    var successRate: Double? { knownOutcomes > 0 ? Double(successes) / Double(knownOutcomes) : nil }
    var averageDuration: Double? { durationSamples > 0 ? totalDuration / Double(durationSamples) : nil }
}

nonisolated struct CallAnalyticsTrendPoint: Identifiable {
    let day: String
    let count: Int
    var id: String { day }
}

nonisolated struct CallAnalyticsUnusedItem: Identifiable {
    let source: CallSourceKind
    let kind: CallKind
    let name: String
    var id: String { source.rawValue + ":" + kind.rawValue + ":" + name }
}

/// 所有卡片、排行与趋势共享同一个过滤结果；未知成功率/耗时保留 nil，不伪造 0。
nonisolated struct CallAnalyticsReport {
    let entries: [CallAnalyticsEntry]
    /// 独立的会话次数维度，不受 MCP / Skill / 工具排行筛选影响。
    let agentInvocations: [AgentInvocationCount]
    let hasUndatedAgentInvocations: Bool
    let rankings: [CallAnalyticsRanking]
    let trend: [CallAnalyticsTrendPoint]
    let unused: [CallAnalyticsUnusedItem]
    /// 首次扫描失败/来源缺失时没有统计依据；只有成功读取或已有历史条目才能显示计数。
    let canDisplayTotals: Bool
    let hasReadFailures: Bool
    var totalCalls: Int { entries.reduce(0) { $0 + $1.count } }
    var knownOutcomes: Int { entries.reduce(0) { $0 + $1.outcomeKnownCount } }
    var durationSamples: Int { entries.reduce(0) { $0 + $1.durationSampleCount } }
    var successRate: Double? {
        knownOutcomes > 0 ? Double(entries.reduce(0) { $0 + $1.successCount }) / Double(knownOutcomes) : nil
    }
    var averageDuration: Double? {
        durationSamples > 0 ? entries.reduce(0) { $0 + $1.durationMsTotal } / Double(durationSamples) : nil
    }

    init(snapshot: CallAnalyticsSnapshot, lowerDay: String?, upperDay: String?, source: CallSourceKind?, kind: CallKind?) {
        entries = snapshot.entries.filter {
            (source == nil || $0.source == source) && (kind == nil || $0.kind == kind)
            && (lowerDay == nil || $0.dayKey >= lowerDay!) && (upperDay == nil || $0.dayKey <= upperDay!)
        }
        let scopedInvocations = snapshot.agentInvocations.filter { source == nil || $0.source == source }
        hasUndatedAgentInvocations = scopedInvocations.contains { $0.dayKey == nil && $0.count > 0 }
        agentInvocations = scopedInvocations.filter { value in
            guard let day = value.dayKey else { return lowerDay == nil && upperDay == nil }
            return (lowerDay == nil || day >= lowerDay!) && (upperDay == nil || day <= upperDay!)
        }
        let relevantStatuses = snapshot.sources.filter { source == nil || $0.source == source }
        let readableSources = Set(relevantStatuses.filter { $0.available && $0.errorCode == nil }.map(\.source))
        canDisplayTotals = !entries.isEmpty || !readableSources.isEmpty
        hasReadFailures = relevantStatuses.contains { $0.errorCode != nil }
        var rows: [String: CallAnalyticsRanking] = [:]
        for entry in entries {
            let id = entry.source.rawValue + ":" + entry.kind.rawValue + ":" + entry.name
            var row = rows[id] ?? CallAnalyticsRanking(source: entry.source, kind: entry.kind, name: entry.name,
                count: 0, knownOutcomes: 0, successes: 0, durationSamples: 0, totalDuration: 0)
            row.count += entry.count; row.knownOutcomes += entry.outcomeKnownCount; row.successes += entry.successCount
            row.durationSamples += entry.durationSampleCount; row.totalDuration += entry.durationMsTotal
            rows[id] = row
        }
        rankings = rows.values.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
        trend = Dictionary(grouping: entries, by: \.dayKey).map { day, values in
            CallAnalyticsTrendPoint(day: day, count: values.reduce(0) { $0 + $1.count })
        }.sorted { $0.day < $1.day }
        let usedSkills = Set(entries.filter { $0.kind == .skill }.map { $0.source.rawValue + ":" + $0.name })
        let usedMCP = Set(entries.filter { $0.kind == .mcp }.compactMap { entry in entry.server.map { entry.source.rawValue + ":" + $0 } })
        var missing: [CallAnalyticsUnusedItem] = []
        if kind == nil || kind == .skill {
            missing += snapshot.installedSkills.filter { readableSources.contains($0.source) && (source == nil || $0.source == source) && !usedSkills.contains($0.source.rawValue + ":" + $0.name) }
                .map { CallAnalyticsUnusedItem(source: $0.source, kind: .skill, name: $0.name) }
        }
        if kind == nil || kind == .mcp {
            missing += snapshot.installedMCPServers.filter { readableSources.contains($0.source) && (source == nil || $0.source == source) && !usedMCP.contains($0.source.rawValue + ":" + $0.name) }
                .map { CallAnalyticsUnusedItem(source: $0.source, kind: .mcp, name: $0.name) }
        }
        unused = missing.sorted { $0.id < $1.id }
    }
}

// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 下列展示派生移植自 AIUsage CallAnalyticsDerived；沿用现有 Quotio 时间过滤与失败状态契约。
nonisolated enum CallReplicaScope: String, CaseIterable, Identifiable {
    case all, claude, codex, opencode, pi
    var id: String { rawValue }
    var source: CallSourceKind? { CallSourceKind(rawValue: rawValue) }
}

nonisolated enum CallReplicaLens: String, CaseIterable, Identifiable {
    case mcp, skill, tools
    var id: String { rawValue }
}

nonisolated struct CallReplicaRankRow: Identifiable {
    let id: String
    let name: String
    let count: Int
    let sources: Set<CallSourceKind>
    let successRate: Double?
    let duration: Double?
    var drillable = false
}

nonisolated struct CallReplicaInventoryRow: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
    var used: Bool { count > 0 }
}

nonisolated struct CallReplicaAgentRow: Identifiable {
    let id: String
    let count: Int
}

/// 视觉分区复用同一份已过滤 report，不让排行维度切换反过来影响 KPI 和趋势。
nonisolated struct CallReplicaDerived {
    let report: CallAnalyticsReport
    let snapshot: CallAnalyticsSnapshot
    let source: CallSourceKind?
    var entries: [CallAnalyticsEntry] { report.entries }
    var mcpCalls: Int { entries.filter { $0.kind == .mcp }.reduce(0) { $0 + $1.count } }
    var skillCalls: Int { entries.filter { $0.kind == .skill }.reduce(0) { $0 + $1.count } }
    var activeServers: Int { Set(entries.filter { $0.kind == .mcp }.compactMap(\.server)).count }
    var unusedSkills: Int { inventory(kind: .skill).filter { !$0.used }.count }

    private struct Aggregate {
        var count = 0
        var known = 0
        var success = 0
        var samples = 0
        var duration = 0.0
        var sources = Set<CallSourceKind>()
        mutating func add(_ entry: CallAnalyticsEntry) {
            count += entry.count; known += entry.outcomeKnownCount; success += entry.successCount
            samples += entry.durationSampleCount; duration += entry.durationMsTotal; sources.insert(entry.source)
        }
        func row(id: String, name: String, drillable: Bool) -> CallReplicaRankRow {
            CallReplicaRankRow(id: id, name: name, count: count, sources: sources,
                successRate: known > 0 ? Double(success) / Double(known) : nil,
                duration: samples > 0 ? duration / Double(samples) : nil, drillable: drillable)
        }
    }

    func ranking(_ lens: CallReplicaLens) -> [CallReplicaRankRow] {
        let subset = entries.filter {
            switch lens {
            case .mcp: return $0.kind == .mcp
            case .skill: return $0.kind == .skill
            case .tools: return [.builtin, .webSearch, .other].contains($0.kind)
            }
        }
        return ranked(subset, key: { lens == .mcp ? $0.server ?? $0.name : $0.name }, drillable: lens == .mcp)
    }

    func tools(server: String) -> [CallReplicaRankRow] {
        let rows = ranked(entries.filter { $0.kind == .mcp && ($0.server ?? $0.name) == server }, key: \.name)
        let prefix = server + "/"
        return rows.map { row in
            CallReplicaRankRow(id: row.id, name: row.name.hasPrefix(prefix) ? String(row.name.dropFirst(prefix.count)) : row.name,
                count: row.count, sources: row.sources, successRate: row.successRate, duration: row.duration)
        }
    }

    private func ranked(_ subset: [CallAnalyticsEntry], key: (CallAnalyticsEntry) -> String, drillable: Bool = false) -> [CallReplicaRankRow] {
        var values: [String: Aggregate] = [:]
        for entry in subset { values[key(entry), default: Aggregate()].add(entry) }
        return values.map { $0.value.row(id: $0.key, name: $0.key, drillable: drillable) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// “全部”时同名项目合并，任一可用来源已调用即算已用；失败来源不凭安装记录推断零调用。
    func inventory(kind: CallKind) -> [CallReplicaInventoryRow] {
        let readable = Set(snapshot.sources.filter { $0.available && $0.errorCode == nil && (source == nil || $0.source == source) }.map(\.source))
        let installed = kind == .skill ? snapshot.installedSkills : snapshot.installedMCPServers
        var names = Set(installed.filter { readable.contains($0.source) }.map(\.name))
        var counts: [String: Int] = [:]
        for entry in entries where entry.kind == kind {
            let name = kind == .mcp ? entry.server ?? entry.name : entry.name
            counts[name, default: 0] += entry.count
            names.insert(name)
        }
        return names.map { CallReplicaInventoryRow(name: $0, count: counts[$0] ?? 0) }.sorted {
            if $0.used != $1.used { return $0.used }
            return $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }
    }

    /// 与 AIUsage 一致，按日期范围内的会话启动次数分组；纯文本子代理也计一次。
    var agents: [CallReplicaAgentRow] {
        guard source == nil || source == .claude else { return [] }
        var counts: [String: Int] = [:]
        for invocation in report.agentInvocations where invocation.source == .claude {
            counts[invocation.agent, default: 0] += invocation.count
        }
        guard counts.contains(where: { $0.key != "main" && $0.value > 0 }) else { return [] }
        return counts.map { CallReplicaAgentRow(id: $0.key, count: $0.value) }.sorted {
            if $0.id == "main" || $1.id == "main" { return $0.id == "main" && $1.id != "main" }
            return $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count
        }
    }
}
