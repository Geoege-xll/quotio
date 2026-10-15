// 最近上游执行概览：统一今日范围、执行账号和 CPA 上报结果。
// 用量事件没有候选顺序或客户端最终状态，不据当前策略推断历史选号理由。

import SwiftUI

struct RoutingLastRequestTraceView: View {
    @Environment(QuotaViewModel.self) private var viewModel

    @Environment(CPARoutingViewModel.self) private var routing
    @State private var settings: MenuBarSettingsManager
    init(settings: MenuBarSettingsManager = .shared) { _settings = State(initialValue: settings) }
    private var latestEvent: CPAUsageEvent? { routing.snapshot.events.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. 今日上游执行概览：执行记录 · 取消 · 失败尝试，三项使用同一时间范围。
            decisionHeader

            Divider().opacity(0.4)

            // 2. 核心链路：最近一个请求是怎么路由的
            traceStepsSection
        }
        .quotioCard()
        .help("routing.data.scopeHelp".localized())
    }

    // MARK: - 1. Decision Header & 3 Core Metrics

    private var decisionHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            // 左侧：最近一次上游执行与时间
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("routing.trace.latestExecution".localized())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                if let event = latestEvent {
                    Text(String(format: "routing.trace.lastAt".localized(), event.timestamp.formatted(date: .omitted, time: .standard)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("routing.trace.noRequests".localized())
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 此处统计上游执行，不声称取消是改道或上游失败已被 Agent 看到。
            HStack(spacing: 18) {
                metricCounter(
                    value: routing.snapshot.executions,
                    label: "routing.trace.requests".localized(),
                    color: .primary
                )

                metricCounter(
                    value: routing.snapshot.canceled,
                    label: "routing.trace.rerouted".localized(),
                    color: routing.snapshot.canceled > 0 ? .orange : .secondary
                )

                metricCounter(
                    value: routing.snapshot.failures,
                    label: "routing.trace.errors".localized(),
                    color: routing.snapshot.failures > 0 ? .red : .secondary
                )
            }
            .fixedSize()
        }
    }

    private func metricCounter(value: Int, label: String, color: Color) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(routing.hasReadError ? "—" : "\(value)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 46)
    }

    private func accountName(_ event: CPAUsageEvent) -> String {
        CPARoutingPresentation.accountName(for: event, files: viewModel.authFiles,
            hidden: settings.hideSensitiveInfo)
    }

    // MARK: - 2. Trace Steps: 最近一个请求是怎么路由的

    private var traceStepsSection: some View {
        Group {
            if let event = latestEvent {
                VStack(alignment: .leading, spacing: 8) {
                    // Step 1: 客户端来源与目标模型
                    traceStepRow(
                        bulletColor: .secondary.opacity(0.8),
                        icon: nil,
                        content: step1Description(event: event)
                    )

                    // Step 2: 已确认的执行账号；没有候选顺序时不推导选择理由。
                    traceStepRow(
                        bulletColor: Color.blue,
                        icon: "person.crop.circle.badge.checkmark",
                        content: step2Description(event: event)
                    )

                    // Step 3: CPA 上报的上游执行结果。
                    traceStepRow(
                        bulletColor: event.outcome == .success ? Color.green : (event.outcome == .canceled ? Color.orange : Color.red),
                        icon: event.outcome == .success ? "checkmark.circle.fill" : "xmark.circle.fill",
                        content: step3Description(event: event)
                    )
                    // CPA 上报失败时直接在下方展示诊断原因与修复建议，无需二次点击折叠展开。
                    if let explanation = CPAUsageFailureExplanation.make(for: event) {
                        RoutingFailureDetailsView(explanation: explanation)
                            .padding(.top, 4)
                            .padding(.leading, 22)
                            .accessibilityIdentifier("routing.latest.failureDetails")
                    }
                }
                .padding(.leading, 4)
            } else {
                Text("routing.requests.waitingSubtitle".localized())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func traceStepRow(bulletColor: Color, icon: String?, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(bulletColor)
                    .frame(width: 14)
            } else {
                Circle()
                    .fill(bulletColor)
                    .frame(width: 5.5, height: 5.5)
                    .frame(width: 14, alignment: .center)
            }

            Text(content)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelWithProvider(provider: String, model: String) -> String {
        if provider.isEmpty || model.hasPrefix("\(provider)/") || model.contains("/") {
            return model
        }
        return "\(provider)/\(model)"
    }

    private func step1Description(event: CPAUsageEvent) -> String {
        // User-Agent 仅提供产品分类，密钥只是入口凭据；未知客户端不按密钥猜名字。
        let model = modelWithProvider(provider: event.provider, model: event.model)
        return String(format: "routing.trace.executionInput".localized(),
            CPARoutingPresentation.sourceName(for: event, hidden: settings.hideSensitiveInfo), model)
    }

    private func step2Description(event: CPAUsageEvent) -> String {
        String(format: "routing.trace.executionAccount".localized(), accountName(event))
    }

    private func step3Description(event: CPAUsageEvent) -> String {
        // 缺失遥测保留未知；CPA 归一化状态码也不声称是厂商原始 HTTP 返回码。
        var latency = event.latency.map { "\(Int($0))ms" } ?? "routing.latency.unknown".localized()
        if event.outcome == .success {
            var metrics: [String] = []
            if let ttft = event.context.ttft, ttft > 0 {
                metrics.append("TTFT: \(Int(ttft))ms")
            }
            if let tps = event.tokensPerSecond, tps > 0 {
                metrics.append(String(format: "%.1f t/s", tps))
            }
            if event.tokens.cached > 0 {
                metrics.append(String(format: "routing.trace.cacheHitFormat".localized(), event.tokens.cached.formattedCompact))
            }
            if !metrics.isEmpty {
                latency += " (\(metrics.joined(separator: " · ")))"
            }
        }
        let status = CPAUsageFailureExplanation.make(for: event)?.summary
            ?? event.context.statusCode.map { "HTTP \($0)" } ?? "routing.status.unknown".localized()
        return String(format: "routing.trace.executionResult".localized(),
            CPARoutingPresentation.outcomeKey(event.outcome).localized(), latency, status)
    }
}
