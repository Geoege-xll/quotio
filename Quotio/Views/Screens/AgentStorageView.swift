//
//  AgentStorageView.swift
//  Quotio - Unified Agent Management
//

import SwiftUI

/// 存储用量和缓存操作的界面集中在此，避免与会话及技能状态交织。
// MARK: - Storage & Cache View

struct AgentStorageView: View {
    @Bindable var viewModel: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let report = viewModel.storageReport {
                storageContent(report: report)
                    .transition(.opacity)
            } else {
                storageLoadingLayer
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.storageReport != nil)
    }

    private func storageContent(report: WorkspaceStorageReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Top Storage Overview Card
                storageOverviewCard(report: report)

                // Per-Agent Breakdown Section
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("各智能体占用明细与专属清理")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.primary)
                            Text("会话历史、补全缓存与诊断日志分布概览")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(report.items) { item in
                            agentStorageCard(item: item)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Loading Layer

    private var storageLoadingLayer: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.xl, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.18), Color.purple.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.xl, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.5)
                    )

                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("正在分析智能体存储与缓存...")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                Text("正在快速度量各智能体的历史会话、模型补全缓存与诊断日志分布")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 4)

            // Agent Chips Indicators
            HStack(spacing: 8) {
                ForEach(WorkspaceAgent.allCases) { agent in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(agent.color)
                            .frame(width: 7, height: 7)
                        Text(agent.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule()
                            .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Overview Card

    private func storageOverviewCard(report: WorkspaceStorageReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 编码智能体总磁盘占用")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(formatBytes(report.totalBytes))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("覆盖 Claude Code、Codex、OpenCode、Pi、Antigravity 及 Quotio 网关")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Actions: One-click Cache Clean + 30-day Pruning (上下布局，空间利用更合理)
                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        Task { await viewModel.clearAllCaches() }
                    } label: {
                        if viewModel.cacheCleaningTarget == "all" { SmallProgressView() }
                        else {
                            Label("清空缓存 (\(formatBytes(report.totalCacheBytes)))", systemImage: "trash.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.quotioPrimaryMicroCapsule(height: 26))
                    .disabled(report.totalCacheBytes == 0 || viewModel.isCleaningStorage)

                    if report.oldSessionsCount > 0 {
                        Button {
                            Task { await viewModel.cleanOldSessions(days: 30) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                Text("清理旧会话 (\(formatBytes(report.oldSessionsBytes)))")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .buttonStyle(.quotioMicroCapsule(height: 26))
                        .disabled(viewModel.isCleaningStorage)
                    }
                }
            }

            // Proportional Multi-Agent Continuous Bar
            VStack(spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(report.items) { item in
                            if report.totalBytes > 0 && item.totalBytes > 0 {
                                let width = max(4, geo.size.width * CGFloat(item.totalBytes) / CGFloat(report.totalBytes))
                                Rectangle()
                                    .fill(item.agent.color)
                                    .frame(width: width)
                                    .help("\(item.agent.displayName): \(formatBytes(item.totalBytes))")
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 12)
                .background(
                    Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                )

                // Legend: 默认标准启动窗口下自适应 2 行，拉宽窗口自动伸展为 1 行
                QuotioLegendFlowLayout(spacing: 16, lineSpacing: 8) {
                    ForEach(report.items) { item in
                        HStack(spacing: 5) {
                            Circle().fill(item.agent.color).frame(width: 7, height: 7)
                            Text(item.agent.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(formatBytes(item.totalBytes))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.xl, padding: 20)
    }

    // MARK: - Agent Storage Card

    private func agentStorageCard(item: AgentStorageUsage) -> some View {
        VStack(spacing: 12) {
            // Tier 1: Agent Squircle Icon + Name & Path + Total Size
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                        .fill(item.agent.color.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    Image(systemName: item.agent.systemIcon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(item.agent.color)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.agent.displayName)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(.primary)

                        Text(agentStoragePathHint(for: item.agent))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                            )
                    }

                    Text("历史会话、模型补全与诊断日志")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Total size
                Text(formatBytes(item.totalBytes))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            // Tier 2: Capsule metric chips on left, Action Button on right
            HStack(spacing: 8) {
                metricTag(
                    icon: "bubble.left.fill",
                    label: "会话",
                    size: formatBytes(item.sessionBytes),
                    count: item.sessionCount > 0 ? "\(item.sessionCount) 个" : nil
                )

                metricTag(
                    icon: "bolt.fill",
                    label: "缓存",
                    size: formatBytes(item.cacheBytes),
                    count: nil,
                    isHighlighted: item.cacheBytes > 0
                )

                metricTag(
                    icon: "doc.text.fill",
                    label: "日志",
                    size: formatBytes(item.logBytes),
                    count: nil
                )

                Spacer()

                if item.cacheBytes > 0 {
                    Button {
                        Task { await viewModel.clearAgentCaches(item.agent) }
                    } label: {
                        if viewModel.cacheCleaningTarget == item.agent.rawValue { SmallProgressView() }
                        else { Label("清空缓存", systemImage: "trash").font(.system(size: 11, weight: .medium)) }
                    }
                    .buttonStyle(.quotioMicroCapsule(height: 24))
                    .disabled(viewModel.isCleaningStorage)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("缓存已空")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.04))
                    )
                }
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 14)
    }

    private func agentStoragePathHint(for agent: WorkspaceAgent) -> String {
        switch agent {
        case .claude: return "~/.claude"
        case .codex: return "~/.codex"
        case .opencode: return "~/.opencode"
        case .pi: return "~/.pi"
        case .agy: return "~/.gemini"
        }
    }

    private func metricTag(icon: String, label: String, size: String, count: String? = nil, isHighlighted: Bool = false) -> some View {
        HStack(spacing: 4.5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)

            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text(size)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            if let count {
                Text("(\(count))")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            Capsule()
                .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
