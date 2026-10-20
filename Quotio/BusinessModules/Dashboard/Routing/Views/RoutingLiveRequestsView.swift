// 上游执行列表：共享本地账本投影，保留暂停、刷新、展开明细、Token、TTFT 与 TPS。
// 每行是 CPA 用量事件，不能当作一次独立入站请求或客户端最终错误。

import SwiftUI

struct RoutingLiveRequestsView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme

    @Environment(CPARoutingViewModel.self) private var routing
    @State private var settings: MenuBarSettingsManager
    /// 展开选择仅由当前列表交互维护，初次进入默认收起，不再暴露一次性截图参数。
    init(settings: MenuBarSettingsManager = .shared) {
        _settings = State(initialValue: settings)
    }
    @State private var selectedEventID: String?
    private let maxDisplayCount = 15
    private var requests: [CPAUsageEvent] { routing.displayedEvents }
    private var isLoading: Bool { routing.isLoading }

    private var store: UsageStatisticsStore { viewModel.usageMonitor }
    private var isRunning: Bool { viewModel.proxyManager.proxyStatus.running }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            if requests.isEmpty {
                emptyRequestsPlaceholder
            } else {
                requestsListView
            }
        }
        .quotioCard()
        .onChange(of: requests.map(\.id)) {
            // 清除、跨日或分页更新后，已不存在的展开行不能继续持有选择状态。
            if let selectedEventID, !requests.contains(where: { $0.id == selectedEventID }) {
                self.selectedEventID = nil
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Label("routing.requests.title".localized(), systemImage: "bolt.horizontal.circle.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            // 手动刷新按钮
            Button {
                Task {
                    await routing.reload { now in try await store.queryRoutingSnapshot(now: now) }
                    await routing.reloadConfiguration(client: isRunning ? viewModel.apiClient : nil)
                }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                }
            }
            .buttonStyle(.quotioMicroCapsule)
            .accessibilityIdentifier("routing.requests.refresh")
            .disabled(isLoading)
            .help("action.refresh".localized())
        }
    }

    // MARK: - Empty State

    private var emptyRequestsPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            VStack(spacing: 3) {
                Text("routing.requests.waitingTitle".localized())
                    .font(.system(size: 13, weight: .semibold))

                Text("routing.requests.waitingSubtitle".localized())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Requests List

    private var requestsListView: some View {
        VStack(spacing: 6) {
            ForEach(requests.prefix(maxDisplayCount)) { event in
                requestRow(event: event)
            }
        }
    }

    // MARK: - Request Row

    private func requestRow(event: CPAUsageEvent) -> some View {
        let isSelected = selectedEventID == event.id

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedEventID = isSelected ? nil : event.id
                }
            } label: {
                // 每条记录固定两层：第一层辨认时间、来源与结果，第二层查看模型、
                // 实际上游和指标。保留同一个 Button，点击／键盘展开行为不受排版影响。
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(event.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        clientSourceBadge(event: event)
                        Spacer(minLength: 4)
                        statusBadge(event: event)
                            .fixedSize()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isSelected ? 90 : 0))
                    }
                    HStack(spacing: 10) {
                        modelRoute(event: event)
                        Spacer(minLength: 0)
                        // 数值指标保持完整，长模型和账号只在自身区域截断；完整内容
                        // 仍可通过展开明细及辅助功能读取，不通过缩小整行字号来挤空间。
                        metricsPill(event: event)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("routing.execution." + event.id)

            // 展开的详细信息
            if isSelected {
                eventDetailBox(event: event)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme).opacity(isSelected ? 0.8 : 0.4),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
        )
    }

    // MARK: - Row Subviews

    /// 调用的模型与确认上游使用不同文字层次；账号名称复用已有身份解析和隐私
    /// 遮罩，缺失证据仍显示未知，不按平台首个账号推测历史执行目标。
    /// 上游品牌按模型 ID 特征校准，跨协议接入的第三方模型不再误标协议家族名。
    private func modelRoute(event: CPAUsageEvent) -> some View {
        let account = CPARoutingPresentation.accountName(for: event, files: viewModel.authFiles,
                                                         hidden: settings.hideSensitiveInfo)
        let upstreamBrand = ProviderDisplayName.eventProviderName(provider: event.provider, model: event.model)
        return HStack(spacing: 5) {
            Text(event.model)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                // 模型与账号按同一布局优先级分配宽度，长模型不能吞掉整个上游区。
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Circle()
                .fill(providerColor(for: upstreamBrand))
                .frame(width: 5, height: 5)
            Text(upstreamBrand + " / " + account)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(event.model + " → " + upstreamBrand + " / " + account)
    }

    private func clientSourceBadge(event: CPAUsageEvent) -> some View {
        let label = CPARoutingPresentation.sourceName(for: event, hidden: settings.hideSensitiveInfo)
        return HStack(spacing: 3) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(QuotioTheme.Colors.cardElevated(for: colorScheme), in: Capsule())
    }

    private func metricsPill(event: CPAUsageEvent) -> some View {
        HStack(spacing: 8) {
            // 响应延迟
            if let latency = event.latency {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text("\(Int(latency))ms")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            }

            // 首字响应 (TTFT)
            if let ttft = event.context.ttft, ttft > 0 {
                Text("TTFT: \(Int(ttft))ms")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Token 吞吐
            if event.tokens.total > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "number")
                        .font(.system(size: 9))
                    Text(event.tokens.total.formattedCompact)
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func statusBadge(event: CPAUsageEvent) -> some View {
        let outcome = event.outcome
        let explanation = CPAUsageFailureExplanation.make(for: event)
        return HStack(spacing: 4) {
            Circle()
                .fill(outcome == .success ? Color.green : (outcome == .canceled ? Color.orange : Color.red))
                .frame(width: 5, height: 5)

            Text(explanation?.summary ?? CPARoutingPresentation.outcomeKey(outcome).localized())
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(outcome == .success ? Color.green : (outcome == .canceled ? Color.orange : Color.red))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            (outcome == .success ? Color.green : (outcome == .canceled ? Color.orange : Color.red)).opacity(0.12),
            in: Capsule()
        )
        .help(explanation?.help ?? CPARoutingPresentation.outcomeKey(outcome).localized())
    }

    private func eventDetailBox(event: CPAUsageEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.3)

            HStack(spacing: 16) {
                detailKV(label: "Tokens", value: "in: \(event.tokens.input) · out: \(event.tokens.output) · cached: \(event.tokens.cached)")
                if let tps = event.tokensPerSecond {
                    detailKV(label: "Speed", value: String(format: "%.1f t/s", tps))
                }
                if let endpoint = event.context.endpoint {
                    detailKV(label: "Endpoint", value: endpoint)
                }
            }

            // 两行摘要可能截断长模型，在展开明细补充完整请求模型，键盘用户同样
            // 能查看和复制；其余明细字段及隐私规则保留。
            detailKV(label: "routing.detail.requestedModel".localized(), value: event.model)

            // 明细展示确认账号、上游响应模型及摘要关联；原始追踪 ID 和 User-Agent 不进入界面。
            detailKV(label: "routing.detail.account".localized(), value:
                CPARoutingPresentation.accountName(for: event, files: viewModel.authFiles, hidden: settings.hideSensitiveInfo))
            // 两行摘要只放状态和失败类型；展开后补原因、建议和证据来源。
            if let explanation = CPAUsageFailureExplanation.make(for: event) {
                RoutingFailureDetailsView(explanation: explanation)
                    .accessibilityIdentifier("routing.execution.failureDetails." + event.id)
            } else if let status = event.context.statusCode {
                // 失败说明已经包含状态码，不在同一明细里重复显示；成功和取消仍
                // 沿用原 CPA 状态字段，不能因新增解释丢失原有遥测。
                detailKV(label: "routing.detail.status".localized(), value: "HTTP \(status)")
            }
            if let responseModel = event.context.responseModel, responseModel != event.model {
                detailKV(label: "routing.detail.responseModel".localized(), value: responseModel)
            }
            if let inbound = event.context.inboundID ?? event.context.traceID {
                detailKV(label: "routing.detail.correlation".localized(), value: "#" + inbound.prefix(12))
            }
            if let alias = event.context.alias {
                Text(String(format: "routing.requests.aliasMapped".localized(), alias, event.model))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 2)
    }

    private func detailKV(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    /// 接收校准后的品牌展示名；第三方品牌沿用与账号目录一致的品牌色。
    private func providerColor(for brand: String) -> Color {
        switch brand {
        case "Anthropic", "Claude": return Color(hex: "D97706") ?? .orange
        case "OpenAI", "Codex": return Color(hex: "10A37F") ?? .green
        case "GLM": return Color(hex: "3B82F6") ?? .blue
        case "DeepSeek": return Color(hex: "1E88E5") ?? .blue
        case "Moonshot": return Color(hex: "6366F1") ?? .indigo
        case "Qwen": return Color(hex: "7C3AED") ?? .purple
        case "MiniMax": return Color(hex: "FF4D4F") ?? .red
        case "Google", "Gemini", "Vertex AI": return Color.blue
        default: return Color.purple
        }
    }

}
