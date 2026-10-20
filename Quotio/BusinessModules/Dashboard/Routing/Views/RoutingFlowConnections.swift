import SwiftUI

/// 锚点取自节点自身的 bounds，并在连线所在 GeometryReader 中解析。窗口缩放、
/// 节点数量变化及文本截断都会重新测量，不再用列宽或舞台中线猜测连接位置。
nonisolated enum RoutingNodeAnchor: Hashable {
    case source(String)
    case hub
    case target(String)
}

nonisolated struct RoutingNodeAnchorPreference: PreferenceKey {
    static let defaultValue: [RoutingNodeAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [RoutingNodeAnchor: Anchor<CGRect>],
                       nextValue: () -> [RoutingNodeAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// 三次曲线使用水平切线进入节点。光段和光点共用同一个参数取样，避免 Path 的
/// 弧长 trim 与贝塞尔参数混用，导致光点跑出尾迹；反向段沿同一条真实上游曲线返回。
nonisolated struct RoutingFlowCurve {
    let start: CGPoint
    let end: CGPoint

    func point(at value: CGFloat) -> CGPoint {
        let t = min(1, max(0, value)), u = 1 - t
        let midX = (start.x + end.x) / 2
        return CGPoint(
            x: u * u * u * start.x + 3 * u * u * t * midX + 3 * u * t * t * midX + t * t * t * end.x,
            y: u * u * u * start.y + 3 * u * u * t * start.y + 3 * u * t * t * end.y + t * t * t * end.y
        )
    }

    var path: Path {
        var result = Path()
        let midX = (start.x + end.x) / 2
        result.move(to: start)
        result.addCurve(to: end, control1: CGPoint(x: midX, y: start.y),
                        control2: CGPoint(x: midX, y: end.y))
        return result
    }

    func segment(from: CGFloat, to: CGFloat) -> Path {
        var result = Path()
        result.move(to: point(at: from))
        for step in 1...12 {
            result.addLine(to: point(at: from + (to - from) * CGFloat(step) / 12))
        }
        return result
    }
}

nonisolated struct RoutingFlowGeometry {
    let anchors: [RoutingNodeAnchor: CGRect]

    func source(_ id: String) -> RoutingFlowCurve? {
        guard let node = anchors[.source(id)], let hub = anchors[.hub] else { return nil }
        return RoutingFlowCurve(start: CGPoint(x: node.maxX + 2, y: node.midY),
                                end: CGPoint(x: hub.minX - 2, y: hub.midY))
    }

    func target(_ id: String) -> RoutingFlowCurve? {
        guard let node = anchors[.target(id)], let hub = anchors[.hub] else { return nil }
        return RoutingFlowCurve(start: CGPoint(x: hub.maxX + 2, y: hub.midY),
                                end: CGPoint(x: node.minX - 2, y: node.midY))
    }

    var allCurves: [RoutingFlowCurve] {
        anchors.keys.compactMap { key in
            switch key {
            case .source(let id): source(id)
            case .target(let id): target(id)
            case .hub: nil
            }
        }
    }
}

/// 一个有限回放分三段：来源向中枢输送、中枢向上游输送、上游结果返回中枢。
/// 中枢短暂停留用于交接；回程不延伸到客户端，避免把上游终态误示为客户端最终结果。
nonisolated struct RoutingFlowSample {
    enum Leg { case source, target, result }
    let leg: Leg
    let progress: CGFloat

    static func at(age: TimeInterval) -> Self? {
        guard age >= 0, age < CPARoutingActivity.duration else { return nil }
        switch age {
        case 0..<0.55: return Self(leg: .source, progress: age / 0.55)
        case 0.55..<0.7: return nil
        case 0.7..<1.2: return Self(leg: .target, progress: (age - 0.7) / 0.5)
        default: return Self(leg: .result, progress: (age - 1.2) / 0.6)
        }
    }

    var headParameter: CGFloat { leg == .result ? 1 - progress : progress }
    var tailParameter: CGFloat {
        let tail = max(0, progress - 0.26)
        return leg == .result ? 1 - tail : tail
    }
    var opacity: Double { Double(min(1, progress / 0.1, (1 - progress) / 0.12)) }
}

/// 纯绘制帧接受显式时间，生产 TimelineView 和回归截图共用同一渲染器。
/// 静态细线始终存在；缺失实际锚点时跳过该活动，绝不连到“第一个”或虚构账号。
struct RoutingFlowFrame: View {
    let geometry: RoutingFlowGeometry
    let activities: [CPARoutingActivity]
    let date: Date
    let isEnabled: Bool
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, _ in
            let baseOpacity = colorScheme == .dark ? 0.22 : 0.15
            for curve in geometry.allCurves {
                context.stroke(curve.path, with: .color(.primary.opacity(baseOpacity)),
                               style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            guard isEnabled else { return }
            for activity in activities.prefix(CPARoutingActivity.maximumConcurrent) {
                let age = date.timeIntervalSince(activity.receivedAt)
                guard activity.isRecent(at: date, duration: CPARoutingActivity.duration),
                      let source = geometry.source(activity.sourceID),
                      let target = geometry.target(activity.targetID) else { continue }
                if reduceMotion {
                    // 减少动态效果时只强调关联路径，无移动光点、位移或扩散。
                    context.stroke(source.path, with: .color(activity.agentColor.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                    context.stroke(target.path, with: .color(resultColor(activity.outcome).opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                    continue
                }
                if let sample = RoutingFlowSample.at(age: age) {
                    let curve = sample.leg == .source ? source : target
                    // 出站阶段（Agent -> Hub 以及 Hub -> Target）使用调用端 Agent 的专属品牌色彩；
                    // 结果回程阶段（Target -> Hub）使用执行结果终态色彩（绿/红/橙）。
                    let color = sample.leg == .result ? resultColor(activity.outcome) : activity.agentColor
                    let point = curve.point(at: sample.headParameter)
                    let beamSegment = curve.segment(from: sample.tailParameter, to: sample.headParameter)

                    // 1. 双层霓虹光段：外层弥散光晕 (Outer Soft Aura)
                    context.stroke(beamSegment,
                                   with: .color(color.opacity(sample.opacity * 0.35)),
                                   style: StrokeStyle(lineWidth: 4.2, lineCap: .round))

                    // 2. 双层霓虹光段：内层高能光核 (Inner Core Beam)
                    context.stroke(beamSegment,
                                   with: .color(color.opacity(sample.opacity * 0.95)),
                                   style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

                    // 3. 彗星粒子头部：外层微光晕 (Outer Halo)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 6.5, y: point.y - 6.5, width: 13, height: 13)),
                                 with: .color(color.opacity(sample.opacity * 0.20)))

                    // 4. 彗星粒子头部：中层辉光 (Middle Glow)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3.8, y: point.y - 3.8, width: 7.6, height: 7.6)),
                                 with: .color(color.opacity(sample.opacity * 0.50)))

                    // 5. 彗星粒子头部：高能中心粒子 (Core Particle)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 2.0, y: point.y - 2.0, width: 4.0, height: 4.0)),
                                 with: .color(.white.opacity(sample.opacity * 0.85)))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)),
                                 with: .color(color.opacity(sample.opacity)))
                }
                // 中枢交接、上游到达和结果回到中枢时，连接端轻微亮起并触发冲击波扩散
                pulse(context: &context, point: source.end, age: age - 0.55, color: activity.agentColor)
                pulse(context: &context, point: target.end, age: age - 1.18, color: resultColor(activity.outcome))
                pulse(context: &context, point: target.start, age: age - 1.55, color: resultColor(activity.outcome))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func resultColor(_ outcome: CPAUsageOutcome) -> Color {
        switch outcome {
        case .success: .green
        case .canceled: .orange
        case .failed: .red
        case .all: .secondary
        }
    }

    private func pulse(context: inout GraphicsContext, point: CGPoint, age: TimeInterval, color: Color) {
        guard age >= 0, age < 0.28 else { return }
        let fraction = age / 0.28
        let radius = 2.5 + fraction * 6.5
        let alpha = 1 - fraction
        context.stroke(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                             width: radius * 2, height: radius * 2)),
                       with: .color(color.opacity(alpha * 0.6)),
                       lineWidth: max(0.5, 1.4 * (1 - fraction * 0.5)))
        if fraction < 0.45 {
            let coreAlpha = (1 - fraction / 0.45) * 0.45
            context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                         with: .color(color.opacity(coreAlpha)))
        }
    }
}

/// 高频绘制局限在透明连线层。没有新活动、服务停止、场景隐藏或减少动态效果时
/// 暂停 Timeline；最后一条 1.8 秒回放结束后只做一次到期更新，不留下永久帧循环。
struct RoutingFlowConnections: View {
    let geometry: RoutingFlowGeometry
    let activities: [CPARoutingActivity]
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clockDate = Date()

    private struct ClockKey: Hashable {
        let lastArrival: Date?
        let enabled: Bool
        let reduced: Bool
    }
    private var clockKey: ClockKey {
        ClockKey(lastArrival: activities.map(\.receivedAt).max(), enabled: isEnabled, reduced: reduceMotion)
    }
    private var canAnimate: Bool {
        Self.shouldAnimate(activities: activities, date: clockDate, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }

    static func shouldAnimate(activities: [CPARoutingActivity], date: Date,
                              isEnabled: Bool, reduceMotion: Bool) -> Bool {
        isEnabled && !reduceMotion && activities.contains {
            $0.isRecent(at: date, duration: CPARoutingActivity.duration)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !canAnimate)) { context in
            RoutingFlowFrame(geometry: geometry, activities: activities,
                             date: canAnimate ? context.date : clockDate,
                             isEnabled: isEnabled, reduceMotion: reduceMotion)
        }
        .task(id: clockKey) {
            clockDate = .now
            guard isEnabled, let latest = clockKey.lastArrival else { return }
            let remaining = latest.addingTimeInterval(CPARoutingActivity.duration).timeIntervalSinceNow
            guard remaining > 0 else { return }
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            clockDate = .now
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
