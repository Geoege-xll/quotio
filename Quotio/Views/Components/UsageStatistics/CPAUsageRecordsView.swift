import SwiftUI

/// 系统 push 的请求明细页面，继承首页筛选，不改变首页历史归档或本地客户端分析。
struct CPAUsageRecordsView: View {
    let store: UsageStatisticsStore
    @State private var viewModel: CPAUsageRecordsViewModel
    @State private var filters = CPAUsageSelection()
    @State private var page = 1
    @State private var pageSize = 50
    @State private var refreshID = UUID()
    @State private var selectedEvent: CPAUsageEvent?
    @State private var isManuallyRefreshing = false
    @State private var minuteTick = 0
    @State private var selectedSection = CPAUsageRecordSection.requests
    @State private var hasSelectedInitialSection = false

    init(store: UsageStatisticsStore, selection: CPAUsageSelection = CPAUsageSelection()) {
        self.store = store
        _filters = State(initialValue: selection)
        _viewModel = State(initialValue: CPAUsageRecordsViewModel(store: store))
    }

    private struct RequestIdentity: Hashable {
        let filters: CPAUsageSelection
        let page: Int
        let size: Int
        let revision: Int
        let minuteTick: Int
        let refreshID: UUID
    }
    private var requestIdentity: RequestIdentity {
        RequestIdentity(filters: filters, page: page, size: pageSize,
                        revision: store.statisticsRevision, minuteTick: minuteTick, refreshID: refreshID)
    }

    var body: some View {
        Group {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        CPAUsageFilterBar(selection: $filters, options: viewModel.result).quotioCard()
                        if let result = viewModel.result {
                            if selectedSection == .history {
                                CPAUsageHistoricalMetrics(buckets: result.historicalBuckets)
                            } else {
                                CPAUsageRecordMetrics(metrics: result.metrics)
                            }
                            if selectedSection == .requests, let date = result.collectionStartedAt {
                                Text("usage.records.startedAt".localized() + " " + date.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if result.omittedHistoricalRequests > 0 {
                                Label(String(format: "usage.records.historyOmitted".localized(), result.omittedHistoricalRequests.formatted()),
                                      systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text((selectedSection == .history ? "usage.records.historyNotice" : "usage.records.coverage").localized())
                            .font(.caption).foregroundStyle(.secondary)
                        if store.state == .legacy || store.state == .unsupported {
                            Label("usage.records.legacy".localized(), systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let key = viewModel.errorKey {
                            Label(key.localized(), systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .frame(height: 310)

                if let result = viewModel.result, result.allHistoricalRequests > 0 {
                    // 历史日桶与真实事件分开切换，表头、计数和分页始终对应实际展示的数据。
                    let sections = [
                        CPAUsageFilterChoice(id: CPAUsageRecordSection.requests.rawValue,
                            title: "usage.dashboard.records".localized() + " · " + result.metrics.requests.formatted()),
                        CPAUsageFilterChoice(id: CPAUsageRecordSection.history.rawValue,
                            title: "usage.records.history".localized() + " · " + result.historicalBuckets.count.formatted())
                    ]
                    // 页面级切换复用项目胶囊控件；可读选项同时包含数量，供 VoiceOver 朗读。
                    QuotioCapsuleSegmentedControl(sections, selection: Binding(get: {
                        sections.first { $0.id == selectedSection.rawValue } ?? sections[0]
                    }, set: { choice in
                        if let section = CPAUsageRecordSection(rawValue: choice.id) { selectedSection = section }
                    }), size: .medium, tint: .accentColor, isEqualWidth: false, title: { $0.title })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                }
                Group {
                    if selectedSection == .history { historicalTable }
                    else { recordsTable }
                }
                    .overlay {
                        if viewModel.isLoading && viewModel.result == nil { ProgressView() }
                        else if let key = viewModel.errorKey, viewModel.result == nil {
                            ContentUnavailableView(key.localized(), systemImage: "exclamationmark.triangle")
                        } else if let result = viewModel.result {
                            if selectedSection == .history, result.historicalBuckets.isEmpty {
                                ContentUnavailableView("usage.empty.title".localized(), systemImage: "calendar",
                                    description: Text("usage.records.noMatches".localized()))
                            } else if selectedSection == .requests, result.events.isEmpty {
                                let hasHistory = !result.hasStoredEvents && result.allHistoricalRequests > 0
                                ContentUnavailableView((hasHistory ? "usage.records.noIndividualTitle" : "usage.empty.title").localized(),
                                    systemImage: "list.bullet.rectangle",
                                    description: Text((hasHistory ? "usage.records.noIndividualDescription" : "usage.records.noMatches").localized()))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                if selectedSection == .history, let result = viewModel.result {
                    Text(String(format: "usage.records.historyCount".localized(), result.historicalBuckets.count.formatted(), result.historicalRequests.formatted()))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                } else {
                    pagination.padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
            .quotioPage()
            .navigationTitle("usage.dashboard.records".localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !isManuallyRefreshing else { return }
                        isManuallyRefreshing = true
                        Task {
                            defer { isManuallyRefreshing = false }
                            await store.refresh(); refreshID = UUID()
                        }
                    } label: {
                        Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                    }
                    .disabled(isManuallyRefreshing)
                }
            }
        }
        // 宽表由系统 Table 处理横向滚动，不再沿用弹窗的 920pt 最小窗口宽度。
        .task(id: requestIdentity) {
            await viewModel.load(selection: filters, page: page, pageSize: pageSize, now: Date())
        }
        .task {
            // 无新请求也推进滚动时间窗；不订阅两秒一次的采集时间心跳。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                minuteTick &+= 1
            }
        }
        .onChange(of: filters) { _, _ in page = 1 }
        .onChange(of: pageSize) { _, _ in page = 1 }
        .onChange(of: viewModel.result == nil) { _, isMissing in
            // 只有首次加载按数据覆盖选择初始列表；后续刷新、筛选和新增明细尊重用户当前选择。
            guard !isMissing, !hasSelectedInitialSection, let result = viewModel.result else { return }
            selectedSection = result.events.isEmpty && result.allHistoricalRequests > 0 ? .history : .requests
            hasSelectedInitialSection = true
        }
        .sheet(item: $selectedEvent) { CPAUsageEventDetail(event: $0) }
    }

    /// 真实日汇总只能展示日、提供商、模型与累计数，不提供请求时间、结果或详情按钮。
    private var historicalTable: some View {
        Table(viewModel.result?.historicalBuckets ?? []) {
            TableColumn("usage.records.day".localized()) { bucket in
                Text(bucket.day.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
            }.width(min: 105, ideal: 135)
            TableColumn("usage.provider".localized()) { bucket in
                Text(bucket.provider.isEmpty ? "usage.unknownProvider".localized() : bucket.provider)
                    .lineLimit(1).help(bucket.provider)
            }.width(min: 85, ideal: 120)
            TableColumn("usage.model".localized()) { bucket in
                Text(bucket.model.isEmpty ? "usage.records.unknown".localized() : bucket.model)
                    .lineLimit(1).truncationMode(.middle).help(bucket.model)
            }.width(min: 155, ideal: 230)
            TableColumn("usage.cpa.requests".localized()) { bucket in
                Text(bucket.requests.formatted()).monospacedDigit()
            }.width(min: 75, ideal: 100)
            TableColumn("Tokens") { bucket in
                Text(bucket.totalTokens.formattedCompact).monospacedDigit().help(bucket.totalTokens.formatted())
            }.width(min: 90, ideal: 120)
        }
    }

    private var recordsTable: some View {
        Table(viewModel.result?.events ?? []) {
            TableColumn("usage.records.time".localized()) { event in
                Text(event.timestamp.formatted(.dateTime.month().day().hour().minute().second()))
                    .font(.caption.monospacedDigit())
            }.width(min: 120, ideal: 135)
            TableColumn("usage.model".localized()) { event in
                Text(event.model).lineLimit(1).truncationMode(.middle).help(event.model)
            }.width(min: 145, ideal: 190)
            TableColumn("usage.provider".localized()) { event in
                Text(event.provider.isEmpty ? "usage.unknownProvider".localized() : event.provider).lineLimit(1)
            }.width(min: 70, ideal: 90)
            TableColumn("usage.records.result".localized()) { event in
                Text(event.outcome.titleKey.localized()).foregroundStyle(outcomeColor(event.outcome))
            }.width(62)
            TableColumn("Tokens") { event in
                Text(event.tokens.total.formattedCompact).monospacedDigit().help(event.tokens.total.formatted())
            }.width(80)
            TableColumn("usage.cpa.latency".localized()) { event in Text(milliseconds(event.latency)).monospacedDigit() }.width(84)
            TableColumn("TTFT") { event in Text(milliseconds(event.context.ttft)).monospacedDigit() }.width(84)
            TableColumn("TPS") { event in
                Text(event.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
            }.width(60)
            TableColumn("") { event in
                Button { selectedEvent = event } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help("usage.records.detail".localized())
                    .accessibilityLabel("usage.records.detail".localized())
            }.width(30)
        }
    }

    private var pagination: some View {
        HStack(spacing: 12) {
            if viewModel.isLoading && viewModel.result == nil { ProgressView().controlSize(.small) }
            if let result = viewModel.result {
                Text(String(format: "usage.records.pageInfo".localized(), result.page, result.totalPages, result.metrics.requests))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Picker("usage.records.pageSize".localized(), selection: $pageSize) {
                ForEach([25, 50, 100, 200], id: \.self) { Text(String($0)).tag($0) }
            }.frame(width: 155)
            Button { page = max(1, (viewModel.result?.page ?? page) - 1) } label: { Image(systemName: "chevron.left") }
                .help("usage.records.previous".localized()).accessibilityLabel("usage.records.previous".localized())
                .disabled(viewModel.isLoading || (viewModel.result?.page ?? 1) <= 1)
            Button { page = (viewModel.result?.page ?? page) + 1 } label: { Image(systemName: "chevron.right") }
                .help("usage.records.next".localized()).accessibilityLabel("usage.records.next".localized())
                .disabled(viewModel.isLoading || (viewModel.result?.page ?? 1) >= (viewModel.result?.totalPages ?? 1))
        }
    }

    private func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    private func outcomeColor(_ outcome: CPAUsageOutcome) -> Color {
        switch outcome {
        case .success: return QuotioTheme.Colors.success
        case .failed: return QuotioTheme.Colors.danger
        case .canceled: return QuotioTheme.Colors.warning
        case .all: return .secondary
        }
    }
}

private enum CPAUsageRecordSection: String, Hashable { case requests, history }

/// 历史列表的摘要以实际日桶计数为准，避免复用事件指标后显示“零请求”的误导。
private struct CPAUsageHistoricalMetrics: View {
    let buckets: [UsageBucket]
    var body: some View {
        let totals = UsageTotals(buckets: buckets)
        CPAUsageAdaptiveGrid(maximumColumns: 4, minimumColumnWidth: 130) {
            value("usage.records.historyRequests", totals.requests.formatted())
            value("usage.tokens", totals.totalTokens.formattedCompact)
            value("usage.records.historyDays", Set(buckets.map(\.day)).count.formatted())
            value("usage.records.historyModels", Set(buckets.map { $0.model.lowercased() }).count.formatted())
        }
    }
    private func value(_ key: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(key.localized()).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).quotioInsetCard()
    }
}

private struct CPAUsageRecordMetrics: View {
    let metrics: CPAUsageEventMetrics
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                value("usage.cpa.requests", metrics.requests.formatted())
                value("usage.tokens", metrics.tokens.formattedCompact)
                value("usage.records.successRate", decimal(metrics.successRate, suffix: "%"))
                value("usage.cpa.latency", decimal(metrics.latency, suffix: " ms"))
            }
            DisclosureGroup("usage.records.moreMetrics".localized(), isExpanded: $expanded) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    value("usage.records.outcome.success", metrics.successes.formatted())
                    value("usage.records.outcome.failed", metrics.failures.formatted())
                    value("usage.records.outcome.canceled", metrics.canceled.formatted())
                    value("usage.inputTokens", metrics.input.formattedCompact)
                    value("usage.outputTokens", metrics.output.formattedCompact)
                    value("usage.reasoningTokens", metrics.reasoning.formattedCompact)
                    value("usage.records.cacheRead", metrics.requests > 0 && metrics.cacheReadSamples == metrics.requests ? metrics.cacheRead.formattedCompact : "—")
                    value("usage.records.cacheWrite", metrics.requests > 0 && metrics.cacheWriteSamples == metrics.requests ? metrics.cacheWrite.formattedCompact : "—")
                    value("usage.records.cacheRate", decimal(metrics.cacheReadRate, suffix: "%"))
                    value("usage.records.rpm", decimal(metrics.rpm))
                    value("usage.records.tpm", decimal(metrics.tpm))
                    value("usage.records.ttft", decimal(metrics.ttft, suffix: " ms"))
                    value("usage.records.tps", decimal(metrics.tps, suffix: " t/s"))
                }
                .padding(.top, 10)
                Text("usage.records.metricRules".localized()).font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
            }
            .font(.caption)
        }
    }

    private func value(_ key: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.localized()).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotioInsetCard()
    }
    private func decimal(_ value: Double?, suffix: String = "") -> String {
        value.map { String(format: "%.1f", $0) + suffix } ?? "—"
    }
}

/// 单条详情仅展示脱敏投影，不提供原始响应、密钥或正文展开入口。
private struct CPAUsageEventDetail: View {
    let event: CPAUsageEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("usage.records.detail".localized()).font(.headline); Spacer(); Button("action.close".localized()) { dismiss() } }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    row("usage.records.time", event.timestamp.formatted(date: .complete, time: .standard))
                    row("usage.model", event.model)
                    row("usage.provider", event.provider)
                    row("usage.records.result", event.outcome.titleKey.localized())
                    row("usage.records.source", event.context.sourceID.map { "#" + $0.prefix(12) } ?? "—")
                    row("usage.records.apiKey", event.context.apiKeyID.map { (event.context.apiKeyLabel ?? "Key") + " · #" + $0.prefix(8) } ?? "—")
                    row("usage.records.alias", event.context.alias ?? "—")
                    row("usage.records.effort", event.context.reasoningEffort ?? "—")
                    row("usage.records.endpoint", event.context.endpoint ?? "—")
                    row("usage.records.statusCode", event.context.statusCode.map(String.init) ?? "—")
                    row("usage.tokens", event.tokens.total.formatted())
                    row("usage.inputTokens", event.tokens.input.formatted())
                    row("usage.outputTokens", event.tokens.output.formatted())
                    row("usage.reasoningTokens", event.tokens.reasoning.formatted())
                    row("usage.records.cacheRead", event.context.cacheRead.map { $0.formatted() } ?? "—")
                    row("usage.records.cacheWrite", event.context.cacheWrite.map { $0.formatted() } ?? "—")
                    row("usage.cpa.latency", event.latency.map { String(format: "%.0f ms", $0) } ?? "—")
                    row("usage.records.ttft", event.context.ttft.map { String(format: "%.0f ms", $0) } ?? "—")
                    row("usage.records.tps", event.tokensPerSecond.map { String(format: "%.1f t/s", $0) } ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .quotioInsetCard()
            }
        }
        .padding(20)
        .frame(width: 600, height: 640)
        .quotioPage()
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key.localized()).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
