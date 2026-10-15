// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 改编自 sylearn/AIUsage（bdb83bbe）；Quotio 修改：隔离扫描、可取消、私有统计归档与原生展示。
// 只保留调用分类与聚合元数据，不归档原始对话、工具参数或凭据。

import Foundation

// MARK: - Call Analytics Models
// 「调用分析」的统一数据模型：把 Claude Code / Codex / OpenCode 三家本地会话日志里的
// 工具调用、MCP 调用、Skill 调用归一化为同一套结构，供 UI 做 Top-N / 热力图 / 零调用检测。
// 数据来源（只读、零埋点）：
//   • Claude: ~/.claude/projects/**/*.jsonl 的 assistant.message.content[].tool_use
//   • Codex:  ~/.codex/sessions/**/*.jsonl 的 function_call / mcp_tool_call_end
//   • OpenCode: opencode.db 的 part 表（type==tool）
// 设计见 docs/CALL_ANALYTICS_DESIGN.md。

/// 调用类别。MCP 与 Skill 是本功能的高价值主线；内置工具量大价值低，单列便于 UI 折叠。
public nonisolated enum CallKind: String, Codable, Sendable, CaseIterable {
    case mcp
    case skill
    case builtin
    case webSearch
    case other
}

/// 数据来源（哪个 CLI）。
public nonisolated enum CallSourceKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
    case pi

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        }
    }
}

/// 一条按「日 × 来源 × 类别 × 名称(× MCP server)」聚合后的调用计数。
///
/// Phase 2：在 `count` 之外追加「成功率 / 平均耗时」的可累加分量。两者**分母独立**——
/// 只对真正提供该信号的样本计入（`outcomeKnownCount` / `durationSampleCount`），
/// 缺信号的来源（如 Claude 无逐工具计时）不会被计入分母，避免把均值/成功率拉低或显示成 0。
public nonisolated struct CallAnalyticsEntry: Codable, Sendable, Hashable {
    public let source: CallSourceKind
    public let kind: CallKind
    /// 展示名：MCP=`server/tool`，Skill=技能名，其它=工具名。
    public let name: String
    /// 仅 MCP 有值，便于「按 server 折叠」。
    public let server: String?
    /// 执行该调用的 agent：Claude 为 `"main"` / `"subagent"`（按 isSidechain 或 subagents/ 路径判定）；
    /// 其余来源无此概念为 nil。仅用于 Claude 的「按 agent 分组」，不影响既有排行（排行按名聚合时忽略）。
    public let agent: String?
    public let dayKey: String        // yyyy-MM-dd（本地时区）
    public var count: Int
    /// 有「成功/失败」结果信号的样本数（成功率分母）。无信号来源为 0。
    public var outcomeKnownCount: Int
    /// 其中判定为成功的样本数（成功率分子）。
    public var successCount: Int
    /// 有耗时数据的样本数（平均耗时分母）。无计时来源为 0。
    public var durationSampleCount: Int
    /// 耗时总和（毫秒，平均耗时分子）。
    public var durationMsTotal: Double

    public init(
        source: CallSourceKind,
        kind: CallKind,
        name: String,
        server: String?,
        agent: String? = nil,
        dayKey: String,
        count: Int,
        outcomeKnownCount: Int = 0,
        successCount: Int = 0,
        durationSampleCount: Int = 0,
        durationMsTotal: Double = 0
    ) {
        self.source = source
        self.kind = kind
        self.name = name
        self.server = server
        self.agent = agent
        self.dayKey = dayKey
        self.count = count
        self.outcomeKnownCount = outcomeKnownCount
        self.successCount = successCount
        self.durationSampleCount = durationSampleCount
        self.durationMsTotal = durationMsTotal
    }

    /// 成功率（0...1）。无结果信号时为 nil（UI 应显式留白，而非显示 0%）。
    public var successRate: Double? {
        outcomeKnownCount > 0 ? Double(successCount) / Double(outcomeKnownCount) : nil
    }

    /// 平均耗时（毫秒）。无计时数据时为 nil。
    public var avgDurationMs: Double? {
        durationSampleCount > 0 ? durationMsTotal / Double(durationSampleCount) : nil
    }
}

/// 一条「本地已安装/已配置」的清单项，带来源归属，用于按应用做零调用检测。
/// 同名项在不同来源各算一条（如同一技能装在 Claude/Codex/OpenCode 三处 → 三条）。
public nonisolated struct InstalledItem: Codable, Sendable, Hashable {
    public let source: CallSourceKind
    public let name: String

    public init(source: CallSourceKind, name: String) {
        self.source = source
        self.name = name
    }
}

/// 一个 agent 被「启动」的次数（Claude 专属）。
/// 主会话 `"main"` = 根会话文件数；子代理 = `subagents/` 下该 `agentType` 的会话数
/// （一份 `agent-<id>.jsonl` = 一次调用）。与「该 agent 调了多少工具」无关——
/// 纯文本输出、不调任何工具的子代理也会被计入，自定义子代理类型同样如此。
public nonisolated struct AgentInvocationCount: Codable, Sendable, Hashable {
    public let source: CallSourceKind
    /// `"main"` 或具体 `agentType`（Explore / Plan / ui-sketcher…，读不到类型时为 `"subagent"`）。
    public let agent: String
    public let count: Int

    /// 会话最早结构化事件所在日；旧归档或无可靠时间戳时为 nil，只能计入「全部」。
    public let dayKey: String?

    public init(source: CallSourceKind, agent: String, count: Int, dayKey: String? = nil) {
        self.source = source
        self.agent = agent
        self.count = count
        self.dayKey = dayKey
    }
}

/// 单个来源的采集状态，供 UI 区分「无数据」与「采集失败」。
public nonisolated struct CallSourceStatus: Codable, Sendable {
    public let source: CallSourceKind
    /// 数据目录/文件是否存在（未安装该 CLI 时为 false）。
    public let available: Bool
    public let eventCount: Int
    public let filesScanned: Int
    /// 采集失败时的错误码（如 db_open_failed）；成功为 nil。
    public let errorCode: String?

    public init(source: CallSourceKind, available: Bool, eventCount: Int, filesScanned: Int, errorCode: String?) {
        self.source = source
        self.available = available
        self.eventCount = eventCount
        self.filesScanned = filesScanned
        self.errorCode = errorCode
    }
}

/// 供界面读取的调用分析值快照；SQLite 按日行持久化，并保留无法从现存日志重建的旧高水位历史。
public nonisolated struct CallAnalyticsSnapshot: Codable, Sendable {
    // v2：installedSkills / installedMCPServers 从 [String] 升级为带来源的 [InstalledItem]，支持按应用做零调用检测。
    // v3：CallAnalyticsEntry 追加成功率 / 平均耗时聚合分量（Phase 2 第一批）。
    // v4：CallAnalyticsEntry 追加 agent 维度（Claude main/subagent，Phase 2 第二批）。版本号变更会令旧缓存自动失效、整份重建。
    // v5：新增 agentInvocations（Claude 各 agent 的「被调用次数」，按会话计），「按 Agent 分组」改用此口径——
    //     不再受「子代理是否调过工具」影响，纯文本输出 / 自定义子代理也能显示。
    // v6：解析窗口从「滚动天数 windowDays」改为「日历口径 rangeKey」（today/week/month/all，与用量统计同口径），
    //     并按事件日期精确过滤。字段类型变更会令旧缓存自动失效、整份重建。
    // v7：会话次数保留可选日期，兼容 v6 未知日期摘要，不用扫描日填充历史。
    public static let currentSchemaVersion = 7

    public let schemaVersion: Int
    public let generatedAt: Date
    /// 解析时间范围标识：`today` / `week` / `month` / `all`，或自定义区间键（如 `custom:2026-06-01:2026-06-10`）。
    /// 仅作缓存/快照身份标识用；实际裁剪由引擎按 cutoff/end 精确完成。
    public let rangeKey: String
    public let entries: [CallAnalyticsEntry]
    /// 本地已安装的 skill（带来源，用于按应用做零调用检测）。
    public let installedSkills: [InstalledItem]
    /// 本地已配置的 MCP server（带来源，用于按应用做零调用检测）。
    public let installedMCPServers: [InstalledItem]
    /// 各 agent 的被调用次数（当前仅 Claude 提供），供「按 Agent 分组」展示。
    public let agentInvocations: [AgentInvocationCount]
    public let sources: [CallSourceStatus]
    /// 日摘要首次进入 SQL 后固定统计时区，避免旅行或系统时区变化把同一历史重复归入新日桶。
    /// 旧归档没有时区证据时为 nil；首次采集后记录实际采用的时区，筛选使用同一口径。
    public let aggregationTimeZoneIdentifier: String?

    public init(
        schemaVersion: Int = CallAnalyticsSnapshot.currentSchemaVersion,
        generatedAt: Date,
        rangeKey: String,
        entries: [CallAnalyticsEntry],
        installedSkills: [InstalledItem],
        installedMCPServers: [InstalledItem],
        agentInvocations: [AgentInvocationCount] = [],
        sources: [CallSourceStatus],
        aggregationTimeZoneIdentifier: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.rangeKey = rangeKey
        self.entries = entries
        self.installedSkills = installedSkills
        self.installedMCPServers = installedMCPServers
        self.agentInvocations = agentInvocations
        self.sources = sources
        self.aggregationTimeZoneIdentifier = aggregationTimeZoneIdentifier
    }

    public static let empty = CallAnalyticsSnapshot(
        generatedAt: .distantPast,
        rangeKey: "all",
        entries: [],
        installedSkills: [],
        installedMCPServers: [],
        agentInvocations: [],
        sources: []
    )

    public var isEmpty: Bool { entries.isEmpty }
    public var totalCalls: Int { entries.reduce(0) { $0 + $1.count } }
}
