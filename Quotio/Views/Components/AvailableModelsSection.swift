import SwiftUI

/// 只展示真实 /v1/models 的只读目录。展开与详情属于视图状态，网络及竞态保护由 ViewModel 承担。
struct AvailableModelsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = false
    @State private var selectedModel: ModelCatalogEntry?
    @State private var copyFeedback: String?
    @State private var refreshID = UUID()
    @FocusState private var focusedModelID: String?
    @FocusState private var detailCloseFocused: Bool
    var onShowDetails: () -> Void = {}

    private var state: ModelCatalogState { viewModel.modelCatalog }
    private var isProxyRunning: Bool { viewModel.proxyManager.proxyStatus.running }
    private var groups: [ModelCatalogGroup] { ModelCatalog.groups(state.entries) }
    // 任何启停、全页刷新或目录刷新都会取消旧 task；ViewModel 另有令牌防护，不依赖网络遵守取消。
    private var loadIdentity: String {
        "\(viewModel.proxyManager.runtimeSessionID)-\(isProxyRunning)-\(viewModel.dashboardRefreshID)-\(refreshID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 区块标题栏
            HStack(spacing: 8) {
                Label("dashboard.availableModels".localized(), systemImage: "cpu")
                    .font(.headline)

                Text(String(format: "availableModels.modelCount".localized(), isProxyRunning ? state.entries.count : 0))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                    .foregroundStyle(.secondary)

                Spacer()

                if state.isLoading && isProxyRunning {
                    ProgressView().controlSize(.small)
                }

                Button {
                    refreshID = UUID()
                } label: {
                    Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(state.isLoading || !isProxyRunning)
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .quotioCard()
        .task(id: loadIdentity) { await viewModel.refreshDashboardModels() }
        .onChange(of: viewModel.proxyManager.runtimeSessionID) { _, _ in
            selectedModel = nil
            copyFeedback = nil
            expanded = false
        }
    }

    @ViewBuilder private var content: some View {
        if !isProxyRunning {
            note("pause.circle", "availableModels.proxyStopped")
        } else if state.isLoading && !state.hasCompletedFetch {
            note("arrow.triangle.2.circlepath", "availableModels.loading")
        } else if state.entries.isEmpty && state.lastFetchFailed {
            freshnessRow
            note("exclamationmark.triangle", "availableModels.error")
        } else if state.isEmptyLiveResult {
            freshnessRow
            note("tray", "availableModels.empty")
        } else if !state.entries.isEmpty {
            freshnessRow
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    // 分组标题：品牌专属微标 + 归属名称 + 模型数量
                    HStack(spacing: 7) {
                        ProviderGroupBrandBadge(ownerName: group.owner ?? "")

                        Text(group.owner ?? "availableModels.unknownOwner".localized())
                            .font(.subheadline.weight(.semibold))

                        Text(String(group.entries.count))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.4), in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                        ForEach(group.visibleEntries(expanded: expanded)) { entry in
                            modelButton(entry)
                        }
                    }
                }
            }
            if let entry = selectedModel, state.entries.contains(entry) { modelDetail(entry) }
            Text("availableModels.ownerNote".localized()).font(.caption2).foregroundStyle(.secondary)
            catalogFooter
        }
    }

    /// 页脚固定在目录内容末尾：数量左对齐，清晰的展开按钮靠右。
    /// 窄宽度下允许分为两行，仍保持按钮靠右，避免操作因长翻译被挤出视口。
    private var catalogFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                displayedCount
                Spacer(minLength: 12)
                expansionButton
            }
            VStack(alignment: .trailing, spacing: 8) {
                displayedCount.frame(maxWidth: .infinity, alignment: .leading)
                expansionButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var displayedCount: some View {
        // 计数取自各组实际可见条目，与网格使用相同折叠规则，不推算或漏计未分配归属的模型。
        let visibleCount = groups.reduce(0) { $0 + $1.visibleEntries(expanded: expanded).count }
        return Text(String(format: "availableModels.displayedCount".localized(), visibleCount, state.entries.count))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var expansionButton: some View {
        // 每组都不超过三项时没有隐藏内容；展开后仍保留同一按钮用于收起。
        if groups.contains(where: { $0.entries.count > 3 }) {
            Button { expanded.toggle() } label: {
                Label((expanded ? "availableModels.collapse" : "availableModels.expand").localized(),
                      systemImage: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
    }

    private func note(_ icon: String, _ key: String) -> some View {
        Label(key.localized(), systemImage: icon)
            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    @ViewBuilder private var freshnessRow: some View {
        switch state.freshness {
        case .never: EmptyView()
        case .live(let date):
            Label(String(format: "availableModels.live".localized(), timestamp(date)), systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        case .stale(let date):
            Label(String(format: "availableModels.stale".localized(), timestamp(date)), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func modelButton(_ entry: ModelCatalogEntry) -> some View {
        Button {
            selectedModel = entry
            copyFeedback = nil
            // 等待详情进入当前视图树，再转移键盘焦点并通知外层滚动容器显示结果。
            Task { @MainActor in
                await Task.yield()
                detailCloseFocused = true
                onShowDetails()
            }
        } label: {
            HStack(spacing: 8) {
                Text(entry.id).font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focusedModelID, equals: entry.id)
        .accessibilityLabel(entry.id)
        .accessibilityHint("availableModels.details".localized())
        .help(entry.id)
    }

    /// 详情直接使用完整 ID；关闭后恢复触发按钮焦点，长名称可换行和手动选取。
    private func modelDetail(_ entry: ModelCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("availableModels.details".localized()).font(.headline)
                Spacer()
                Button("action.close".localized()) {
                    detailCloseFocused = false
                    selectedModel = nil
                    focusedModelID = entry.id
                }
                .focused($detailCloseFocused)
            }
            Text(entry.id).font(.system(.body, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(String(format: "availableModels.owner".localized(), entry.displayOwner ?? "availableModels.unknownOwner".localized()))
                .font(.caption).textSelection(.enabled)
            HStack {
                Button("availableModels.copyID".localized()) {
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(entry.id, forType: .string)
                    copyFeedback = (copied ? "availableModels.copied" : "runtime.copyFailed").localized()
                }
                if let copyFeedback { Text(copyFeedback).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .id("model-catalog-details")
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

// MARK: - Provider Group Brand Badge

struct ProviderGroupBrandBadge: View {
    let ownerName: String

    var body: some View {
        let (icon, gradient) = badgeStyle(for: ownerName)
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(gradient)
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)

            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func badgeStyle(for name: String) -> (String, LinearGradient) {
        let lower = name.lowercased()
        if lower.contains("anthropic") || lower.contains("claude") {
            return (
                "sparkles",
                LinearGradient(
                    colors: [Color(red: 0.82, green: 0.48, blue: 0.35), Color(red: 0.90, green: 0.58, blue: 0.45)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        } else if lower.contains("openai") || lower.contains("gpt") {
            return (
                "circle.grid.cross.fill",
                LinearGradient(
                    colors: [Color(red: 0.06, green: 0.65, blue: 0.48), Color(red: 0.12, green: 0.78, blue: 0.58)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        } else if lower.contains("google") || lower.contains("gemini") {
            return (
                "sparkle",
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.45, blue: 0.95), Color(red: 0.55, green: 0.35, blue: 0.95)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        } else if lower.contains("deepseek") {
            return (
                "fish.fill",
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.45, blue: 0.85), Color(red: 0.20, green: 0.60, blue: 0.95)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        } else if lower.contains("qwen") || lower.contains("alibaba") {
            return (
                "cloud.fill",
                LinearGradient(
                    colors: [Color(red: 0.90, green: 0.40, blue: 0.10), Color(red: 0.98, green: 0.55, blue: 0.20)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        } else {
            return (
                "cpu.fill",
                LinearGradient(
                    colors: [Color(red: 0.35, green: 0.40, blue: 0.48), Color(red: 0.45, green: 0.50, blue: 0.58)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        }
    }
}
