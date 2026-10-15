import Foundation

/// 设置与路由中心实际共用的 CPA 策略选择和展示规则，按共同业务用途整体归位。
/// 当前底层接口保留原始策略字符串；本类型不参与网络发送，不必把规范化和显示再拆成转发层。
/// 原策略值、选项顺序、本地化键、别名及未知值回退完整保留，不触发配置写入。
/// 路由策略只有这一份名称映射，设置、路由总览与请求详情共同使用。
/// 接受官方别名但不据此改写磁盘；未知策略直接显示原值，不能误报为“优先填充”。
nonisolated enum CPARoutingStrategy: String, CaseIterable, Sendable {
    case roundRobin = "round-robin"
    case weightedRoundRobin = "weighted-round-robin"
    case fillFirst = "fill-first"

    static func canonicalValue(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "round-robin": return roundRobin.rawValue
        case "weighted-round-robin", "weightedroundrobin", "wrr": return weightedRoundRobin.rawValue
        case "fill-first", "fillfirst", "ff": return fillFirst.rawValue
        default: return value
        }
    }

    var titleKey: String {
        switch self {
        case .roundRobin: "settings.roundRobin"
        case .weightedRoundRobin: "settings.weightedRoundRobin"
        case .fillFirst: "settings.fillFirst"
        }
    }

    var descriptionKey: String {
        switch self {
        case .roundRobin: "settings.roundRobinDesc"
        case .weightedRoundRobin: "settings.weightedRoundRobinDesc"
        case .fillFirst: "settings.fillFirstDesc"
        }
    }

    static func displayName(for value: String) -> String {
        Self(rawValue: canonicalValue(value))?.titleKey.localizedStatic() ?? value
    }
}
