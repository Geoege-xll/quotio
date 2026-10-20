import Foundation
import SwiftUI

// 本文件维护路由页面的活动与展示规则；共享查询快照归 CPA 统计领域，原查询和消费任务不变。
// 光流身份、时钟、账号映射和状态回退保持原实现，不在本次归位中调整。

/// 光流是“新采集上游执行”的短时回放，并非请求实时在途状态。只保存脱敏身份和
/// 执行终态，不复制账号、访问密钥、邮箱等展示字段，也不写入账本或用户配置。
nonisolated struct CPARoutingActivity: Identifiable, Sendable {
    static let duration: TimeInterval = 1.8
    static let emphasisDuration: TimeInterval = 12
    static let maximumConcurrent = 3
    static let maximumRetained = 6

    let id: String
    let sourceID: String
    let targetID: String
    let outcome: CPAUsageOutcome
    let receivedAt: Date
    /// 调用方智能体客户端名称（如 "Claude Code"、"Codex"、"Cursor"、"OpenCode"），用于动态色彩呈现
    let client: String?

    init(event: CPAUsageEvent, receivedAt: Date) {
        id = event.id
        sourceID = CPARoutingPresentation.sourceID(for: event)
        targetID = CPARoutingPresentation.targetID(for: event)
        outcome = event.outcome
        self.receivedAt = receivedAt
        client = event.context.client
    }

    init(id: String, sourceID: String, targetID: String, outcome: CPAUsageOutcome, receivedAt: Date, client: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.outcome = outcome
        self.receivedAt = receivedAt
        self.client = client
    }

    /// 对应的智能体品牌特征色彩（出站请求粒子与光晕渲染）
    var agentColor: Color {
        CPARoutingPresentation.agentColor(for: client)
    }

    func isRecent(at date: Date, duration: TimeInterval = emphasisDuration) -> Bool {
        // 直接比较 Date 边界，避免减法浮点舍入把恰好 1.8 秒的结束帧当作仍在播放。
        date >= receivedAt && date < receivedAt.addingTimeInterval(duration)
    }
}

/// 三块卡片共用身份与状态规则；显示名称永远不参与身份匹配。
/// 保留历史记录的 nil 语义：证据不足时明确未知，不按账号列表顺序补全。
nonisolated enum CPARoutingPresentation {
    static func account(for event: CPAUsageEvent, files: [AuthFile]) -> AuthFile? {
        let files = AuthFileIdentity.deduplicated(files)
        if let index = event.context.authIndexID {
            // auth_index 是 CPA 执行身份，比邮箱更精确。索引无法匹配时可能账号已删除，
            // 不能退回同邮箱或同平台的新账号，把历史请求错误归因给另一个凭据。
            let matches = files.filter { file in
                file.authIndex.map(CPAUsageContext.authIdentity) == index
            }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let source = event.context.sourceID else { return nil }
        let matches = files.filter { file in
            guard provider(file.provider) == provider(event.provider) else { return false }
            // source 的官方取值含账号、项目和邮箱；只接受当前目录中的唯一精确匹配。
            // 不读取认证文件或 API 密钥，也不因“只有一个账号”而猜测。
            return [file.email, file.account, file.quotaProjectID].compactMap { $0 }
                .contains { CPAUsageContext.sourceIdentity($0) == source }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor static func accountName(for event: CPAUsageEvent, files: [AuthFile], hidden: Bool) -> String {
        account(for: event, files: files)?.quotaDisplayName.masked(if: hidden)
            ?? "routing.account.unknown".localizedStatic()
    }

    static func sourceID(for event: CPAUsageEvent) -> String {
        // 后四位可能碰撞，不能用 ****1234 作为节点主键。客户端分类只是展示证据，
        // 同一访问密钥被不同已识别客户端使用时也应分别显示来源节点。
        (event.context.client ?? "unknown") + ":" + (event.context.apiKeyID ?? "unknown-key")
    }

    /// 节点和光流必须使用同一上游身份；身份缺失时保留未知，不猜测当前账号。
    static func targetID(for event: CPAUsageEvent) -> String {
        event.provider + ":" + (event.context.authIndexID ?? event.context.sourceID ?? "unknown")
    }

    static func sourceName(for event: CPAUsageEvent, hidden: Bool) -> String {
        let client = event.context.client
        let key = hidden ? nil : event.context.apiKeyLabel
        if let client { return key.map { client + " · " + $0 } ?? client }
        let title = "routing.source.accessKey".localizedStatic()
        return key.map { title + " " + $0 } ?? "routing.source.unknown".localizedStatic()
    }

    static func outcomeKey(_ outcome: CPAUsageOutcome) -> String {
        switch outcome {
        case .success: "usage.records.outcome.success"
        case .canceled: "usage.records.outcome.canceled"
        case .failed: "usage.records.outcome.failed"
        case .all: "routing.value.unknown"
        }
    }

    /// 保留按执行时间判断的只读辅助接口；舞台动效使用 CPARoutingActivity 的
    /// 到达时钟，不能用这里的历史时间门槛排除刚完成的慢请求。
    static func isRecent(_ event: CPAUsageEvent, now: Date) -> Bool {
        let age = now.timeIntervalSince(event.timestamp)
        return age >= 0 && age < 12
    }

    /// 根据调用端智能体识别身份返回专属品牌色彩。
    /// 未知或未识别智能体使用系统主色 (accentColor) 兜底。
    static func agentColor(for client: String?) -> Color {
        guard let client else { return Color.accentColor }
        let lower = client.lowercased()
        if lower.contains("claude") {
            // Claude Code 官方专属暖橙色
            return Color(hex: "D97706") ?? .orange
        } else if lower.contains("codex") {
            // OpenAI Codex 官方翠绿色
            return Color(hex: "10A37F") ?? .green
        } else if lower.contains("cursor") {
            // Cursor 经典科技蓝
            return Color(hex: "007AFF") ?? .blue
        } else if lower.contains("opencode") {
            // OpenCode 典雅紫
            return Color(hex: "8B5CF6") ?? .purple
        } else if lower.contains("pi") {
            // Pi 活力珊瑚橙
            return Color(hex: "F97316") ?? .orange
        } else if lower.contains("amp") {
            // Amp 烈焰红
            return Color(hex: "FF5543") ?? .red
        } else if lower.contains("droid") || lower.contains("factory") {
            // Factory Droid 翠绿
            return Color(hex: "238636") ?? .green
        }
        return Color.accentColor
    }

    private static func provider(_ value: String) -> String {
        switch value.lowercased() {
        case "anthropic": "claude"
        case "copilot": "github-copilot"
        default: value.lowercased()
        }
    }
}
