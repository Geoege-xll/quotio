import SwiftUI

/// 系统 push 的请求明细页面，继承首页筛选，不改变首页历史归档或本地客户端分析。
struct CPAUsageRecordsView: View {
    let store: UsageStatisticsStore
    @State private var viewModel: CPAUsageRecordsViewModel
    @State private var filters = CPAUsageSelection()
    @State private var page = 1
    @State private var historyPage = 1
    @State private var showsExtendedMetrics = false
    /// 单次请求在数据库查询层固定 LIMIT 20，历史日汇总在展示层独立分页，不混用两类页码。
    private let pageSize = CPAUsageTablePage.size
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
    private var historicalPage: CPAUsageTablePage {
        CPAUsageTablePage(totalCount: viewModel.result?.historicalBuckets.count ?? 0, number: historyPage)
    }
    private var tableLayoutIdentity: [String] {
        let identities = selectedSection == .history
            ? historicalPage.rows(from: viewModel.result?.historicalBuckets ?? []).map(\.id)
            : (viewModel.result?.events ?? []).map(\.id)
        return [selectedSection.rawValue, String(showsExtendedMetrics)] + identities
    }

    var body: some View {
        CPAUsageDetailPage {
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
                        .font(.caption).foregroundStyle(QuotioTheme.Colors.warning)
                }
            }
        } content: {
            CPAUsageTableCard(layoutIdentity: tableLayoutIdentity) {
                tableHeader
            } content: {
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
            } footer: {
                if selectedSection == .history {
                    VStack(alignment: .leading, spacing: 10) {
                        if let result = viewModel.result {
                            Text(String(format: "usage.records.historyCount".localized(), result.historicalBuckets.count.formatted(), result.historicalRequests.formatted()))
                                .monospacedDigit()
                        }
                        CPAUsageTablePagination(page: historicalPage, isLoading: viewModel.isLoading) { historyPage = $0 }
                    }
                } else {
                    pagination
                }
            }
            // 默认宽度只保留主要请求指标；TTFT/TPS 在足够宽时展开，完整指标始终保留在请求详情。
            .onGeometryChange(for: Bool.self) { $0.size.width >= 860 } action: { showsExtendedMetrics = $0 }
        }
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
        .onChange(of: filters) { _, _ in page = 1; historyPage = 1 }
        .onChange(of: viewModel.result?.historicalBuckets.count) { _, count in
            guard let count else { return }
            historyPage = CPAUsageTablePage(totalCount: count, number: historyPage).number
        }
        .onChange(of: viewModel.result?.page) { _, loadedPage in
            // 滚动时间范围使末页消失时，以数据库返回的有效页码继续翻页。
            if let loadedPage { page = loadedPage }
        }
        .onChange(of: viewModel.result == nil) { _, isMissing in
            // 只有首次加载按数据覆盖选择初始列表；后续刷新、筛选和新增明细尊重用户当前选择。
            guard !isMissing, !hasSelectedInitialSection, let result = viewModel.result else { return }
            selectedSection = result.events.isEmpty && result.allHistoricalRequests > 0 ? .history : .requests
            hasSelectedInitialSection = true
        }
        .sheet(item: $selectedEvent) { CPAUsageEventDetail(event: $0) }
    }

    /// 数据类型切换属于表格本身，与分页共用一张卡片，明确当前计数和操作对应哪类数据。
    @ViewBuilder
    private var tableHeader: some View {
        if let result = viewModel.result, result.allHistoricalRequests > 0 {
            let sections = [
                CPAUsageFilterChoice(id: CPAUsageRecordSection.requests.rawValue,
                    title: "usage.dashboard.records".localized() + " · " + result.metrics.requests.formatted()),
                CPAUsageFilterChoice(id: CPAUsageRecordSection.history.rawValue,
                    title: "usage.records.history".localized() + " · " + result.historicalBuckets.count.formatted())
            ]
            ScrollView(.horizontal, showsIndicators: false) {
                QuotioCapsuleSegmentedControl(sections, selection: Binding(get: {
                    sections.first { $0.id == selectedSection.rawValue } ?? sections[0]
                }, set: { choice in
                    if let section = CPAUsageRecordSection(rawValue: choice.id) { selectedSection = section }
                }), size: .small, tint: .accentColor, isEqualWidth: false, title: { $0.title })
                .monospacedDigit()
            }
            // 横向滚动只解决长标题，不参与垂直剩余空间分配；6pt 为共用分段控件的滑槽内边距。
            .frame(height: QuotioSegmentSize.small.height + 6)
        } else {
            Label("usage.dashboard.records".localized(), systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.semibold))
        }
    }

    /// 真实日汇总只能展示日、提供商、模型与累计数，不提供请求时间、结果或详情按钮。
    private var historicalTable: some View {
        Table(historicalPage.rows(from: viewModel.result?.historicalBuckets ?? [])) {
            TableColumn("usage.records.day".localized()) { bucket in
                Text(bucket.day.formatted(date: .abbreviated, time: .omitted)).monospacedDigit().padding(.vertical, 7)
            }.width(100)
            TableColumn("usage.model".localized()) { bucket in
                // 提供商与模型具有直接关联，作为模型的次级文字，减少独立列占用。
                modelIdentity(model: bucket.model, provider: bucket.provider)
                    .padding(.vertical, 6)
            }.width(min: 130, ideal: 180)
            TableColumn("usage.cpa.requests".localized()) { bucket in
                Text(bucket.requests.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }.width(70)
            TableColumn("Tokens") { bucket in
                Text(bucket.totalTokens.formattedCompact).monospacedDigit().help(bucket.totalTokens.formatted())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(80)
        }
    }

    private var recordsTable: some View {
        Table(viewModel.result?.events ?? []) {
            TableColumn("usage.records.time".localized()) { event in
                // 日期与时分秒分两行，保留精确时间但不再占据一整段横向空间。
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    Text(event.timestamp.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit()).padding(.vertical, 6)
                .help(event.timestamp.formatted(date: .complete, time: .standard))
            }.width(80)
            TableColumn("usage.model".localized()) { event in
                HStack(spacing: 6) {
                    modelIdentity(model: event.model, provider: event.provider)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { selectedEvent = event } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("usage.records.detail".localized()).accessibilityLabel("usage.records.detail".localized())
                }
                .padding(.vertical, 6)
            // 初始理想宽度也必须落在默认窗口预算内：原生 Table 首次加载会采用 ideal 值，
            // 只减小 min 仍会保留横向滚动；额外空间由这一弹性列接收。
            }.width(min: 120, ideal: 130)
            TableColumn("usage.records.result".localized()) { event in
                // 状态同时使用文字、符号和轻量底色，保持与项目状态胶囊一致且不只依赖颜色。
                Label(event.outcome.titleKey.localized(), systemImage: outcomeSymbol(event.outcome))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(outcomeColor(event.outcome).opacity(0.12), in: Capsule())
            }.width(82)
            TableColumn("Tokens") { event in
                Text(event.tokens.total.formattedCompact).monospacedDigit().help(event.tokens.total.formatted())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(68)
            TableColumn("usage.cpa.latency".localized()) { event in Text(milliseconds(event.latency)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }.width(80)
            if showsExtendedMetrics {
                TableColumn("TTFT") { event in Text(milliseconds(event.context.ttft)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }.width(84)
                TableColumn("TPS") { event in
                    Text(event.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(60)
            }
        }
    }

    /// 模型为主、提供商为辅，长名称保留悬停全文；不缩小字号来强行塞进默认窗口。
    private func modelIdentity(model: String, provider: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.isEmpty ? "usage.records.unknown".localized() : model)
                .fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(model)
            Text(provider.isEmpty ? "usage.unknownProvider".localized() : provider)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(provider)
        }
    }

    private var pagination: some View {
        CPAUsageTablePagination(page: CPAUsageTablePage(totalCount: viewModel.result?.metrics.requests ?? 0,
            number: viewModel.result?.page ?? page), isLoading: viewModel.isLoading) { page = $0 }
    }

    private func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    private func outcomeSymbol(_ outcome: CPAUsageOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "minus.circle.fill"
        case .all: return "circle"
        }
    }
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
            // 与价格摘要、历史摘要保持四列／两列节奏，避免三项排满后第四项独占一行。
            CPAUsageAdaptiveGrid(maximumColumns: 4, minimumColumnWidth: 130, spacing: 10) {
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
