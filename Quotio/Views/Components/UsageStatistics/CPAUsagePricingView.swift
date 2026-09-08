import SwiftUI

/// 价格页是系统 push 目的地，不再创建嵌套 NavigationStack，也不提供自绘返回按钮。
/// 继承首页筛选快照；价格表只在本页打开时计算，编辑使用单独的短任务弹窗。
struct CPAUsagePricingView: View {
    let store: UsageStatisticsStore
    @State private var selection: CPAUsageSelection
    @State private var model = CPAUsagePricingViewModel()
    @State private var editedRow: CPAUsagePriceRow?
    @State private var refreshID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    init(store: UsageStatisticsStore, selection: CPAUsageSelection) {
        self.store = store
        _selection = State(initialValue: selection)
    }
    private struct Query: Hashable {
        let selection: CPAUsageSelection
        let refreshID: UUID
        let active: Bool
    }
    private var query: Query { .init(selection: selection, refreshID: refreshID, active: scenePhase == .active) }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CPAUsageFilterBar(selection: $selection, options: model.result?.summary).quotioCard()
                    if let result = model.result {
                        HStack(spacing: 20) {
                            summary("usage.pricing.estimated", CPAUsagePriceFormatting.money(result.estimatedCost, isPartial: result.hasPartialEstimate))
                            // 精确筛选若无法纳入旧日桶，就缺少总体分母；已知部分全已定价也不能显示 100%。
                            summary("usage.pricing.coverage", result.omittedHistoricalRequests == 0 && result.summary.metrics.requests > 0
                                ? String(format: "%.1f%%", Double(result.pricedRequests) / Double(result.summary.metrics.requests) * 100) : "—")
                            summary("usage.pricing.pricedRequests", result.pricedRequests.formatted())
                            summary("usage.cpa.requests", result.omittedHistoricalRequests > 0
                                ? (result.summary.metrics.requests > 0 ? "≥ " + result.summary.metrics.requests.formatted() : "—")
                                : result.summary.metrics.requests.formatted())
                        }.quotioCard()
                    }
                }.padding(.horizontal, 24).padding(.top, 20)
            }.frame(height: 280)
            // 覆盖说明属于当前结果的必要上下文，放在固定表头外，避免被筛选区域的滚动高度遮住。
            pricingNotes.padding(.horizontal, 24)
            priceTable
                .overlay {
                    if model.result == nil && model.errorKey == nil { ProgressView() }
                    else if let key = model.errorKey, model.result == nil {
                        ContentUnavailableView(key.localized(), systemImage: "exclamationmark.triangle")
                    }
                    else if model.result?.rows.isEmpty == true {
                        ContentUnavailableView("usage.empty.title".localized(), systemImage: "dollarsign.circle",
                            description: Text("usage.records.noMatches".localized()))
                    }
                }
                .padding(.horizontal, 24)
            Text("usage.pricing.formula".localized())
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .quotioPage()
        .navigationTitle("usage.pricing.title".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refreshID = UUID() } label: { Label("action.refresh".localized(), systemImage: "arrow.clockwise") }
            }
        }
        .task(id: query) {
            let request = query
            guard request.active else { return }
            var lastRevision: Int?
            var lastPriceRevision: Int?
            var lastMinute: Int?
            while !Task.isCancelled {
                let revision = store.statisticsRevision
                let prices = store.priceRevision
                let minute = Int(Date().timeIntervalSince1970 / 60)
                if revision != lastRevision || prices != lastPriceRevision || minute != lastMinute {
                    if await model.load(request.selection, store: store) {
                        lastRevision = revision; lastPriceRevision = prices; lastMinute = minute
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(item: $editedRow) { row in
            CPAModelPriceEditor(store: store, row: row) { refreshID = UUID() }
        }
    }

    private var priceTable: some View {
        Table(model.result?.rows ?? []) {
            TableColumn("usage.model".localized()) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.model.isEmpty ? "usage.records.unknown".localized() : row.model)
                        .lineLimit(1).truncationMode(.middle).help(row.model)
                    HStack(spacing: 8) {
                        if row.historicalRequests > 0 {
                            Text(String(format: "usage.pricing.historyRow".localized(), row.historicalRequests.formatted()))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        // 编辑入口固定在模型列内，即使右侧价格指标需要横向滚动，也能立即为该模型定价。
                        Button { editedRow = row } label: {
                            if row.price == nil { Text("usage.pricing.configurePrice".localized()) }
                            else { Image(systemName: "pencil") }
                        }
                        .buttonStyle(.borderless).font(.caption).fixedSize()
                        .help("usage.pricing.edit".localized()).accessibilityLabel("usage.pricing.edit".localized())
                        .disabled(row.model.isEmpty)
                    }
                }
            }.width(min: 170, ideal: 230)
            TableColumn("usage.cpa.requests".localized()) { row in Text(row.requests.formatted()).monospacedDigit() }.width(85)
            TableColumn("Tokens") { row in Text(row.tokens.formattedCompact).monospacedDigit() }.width(90)
            TableColumn("usage.pricing.estimated".localized()) { row in
                Text(CPAUsagePriceFormatting.money(row.estimatedCost, isPartial: row.hasPartialEstimate)).monospacedDigit()
                    .help(row.price == nil ? "usage.pricing.unpricedRow".localized()
                        : (row.hasPartialEstimate ? "usage.pricing.partialNotice".localized() : "usage.pricing.formula".localized()))
            }.width(min: 100, ideal: 125)
            TableColumn("usage.pricing.inputPrice".localized()) { row in Text(CPAUsagePriceFormatting.rate(row.price?.input)).monospacedDigit() }.width(90)
            TableColumn("usage.pricing.outputPrice".localized()) { row in Text(CPAUsagePriceFormatting.rate(row.price?.output)).monospacedDigit() }.width(90)
            TableColumn("usage.pricing.coverage".localized()) { row in
                Text(String(format: "usage.pricing.rowCoverage".localized(), row.pricedRequests, row.requests))
                    .monospacedDigit().help(row.price == nil ? "usage.pricing.unconfigured".localized() : "usage.pricing.incomplete".localized())
            }.width(90)

        }
    }
    /// 历史存在、筛选遗漏、费用下界和读取错误分别保留明确文字，不用颜色替代统计口径。
    private var pricingNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let result = model.result {
                if result.summary.historicalRequests > 0 {
                    Label(String(format: "usage.pricing.historyNotice".localized(), result.summary.historicalRequests.formatted()),
                          systemImage: "calendar")
                }
                if result.omittedHistoricalRequests > 0 {
                    Label(String(format: "usage.records.historyOmitted".localized(), result.omittedHistoricalRequests.formatted()),
                          systemImage: "info.circle")
                }
                if result.hasPartialEstimate { Text("usage.pricing.partialNotice".localized()) }
            }
            Text("usage.pricing.notice".localized())
            if let key = model.errorKey {
                Label(key.localized(), systemImage: "exclamationmark.triangle").foregroundStyle(QuotioTheme.Colors.warning)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key.localized()).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 编辑字段使用系统表单及焦点行为。显式零价可保存，留空的缓存价格继续表示“未配置”。
private struct CPAModelPriceEditor: View {
    let store: UsageStatisticsStore
    let row: CPAUsagePriceRow
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var output: String
    @State private var cacheRead: String
    @State private var cacheWrite: String
    @State private var saving = false
    @State private var errorKey: String?

    init(store: UsageStatisticsStore, row: CPAUsagePriceRow, onSaved: @escaping () -> Void) {
        self.store = store; self.row = row; self.onSaved = onSaved
        _input = State(initialValue: row.price.map { String($0.input) } ?? "")
        _output = State(initialValue: row.price.map { String($0.output) } ?? "")
        _cacheRead = State(initialValue: row.price?.cacheRead.map { String($0) } ?? "")
        _cacheWrite = State(initialValue: row.price?.cacheWrite.map { String($0) } ?? "")
    }

    private var price: CPAModelPrice? {
        let read = cacheRead.trimmingCharacters(in: .whitespacesAndNewlines)
        let write = cacheWrite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inputValue = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let outputValue = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              read.isEmpty || Double(read) != nil, write.isEmpty || Double(write) != nil else { return nil }
        let value = CPAModelPrice(model: row.model, input: inputValue, output: outputValue,
                                  cacheRead: read.isEmpty ? nil : Double(read), cacheWrite: write.isEmpty ? nil : Double(write))
        return value.isValid ? value : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("usage.pricing.edit".localized()).font(.headline)
            Text(row.model).font(.callout).textSelection(.enabled)
            Form {
                Section("usage.pricing.unit".localized()) {
                    TextField("usage.pricing.inputPrice".localized(), text: $input)
                    TextField("usage.pricing.outputPrice".localized(), text: $output)
                    TextField("usage.pricing.cacheReadPrice".localized(), text: $cacheRead)
                    TextField("usage.pricing.cacheWritePrice".localized(), text: $cacheWrite)
                }
            }.formStyle(.grouped).disabled(saving)
            Text("usage.pricing.editHelp".localized()).font(.caption).foregroundStyle(.secondary)
            if let errorKey {
                Label(errorKey.localized(), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(QuotioTheme.Colors.danger)
            }
            HStack {
                Spacer()
                Button("action.cancel".localized()) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("action.save".localized()) {
                    guard let price, !saving else { return }
                    saving = true; errorKey = nil
                    Task {
                        defer { saving = false }
                        do { try await store.saveModelPrice(price); onSaved(); dismiss() }
                        catch { errorKey = "usage.pricing.saveFailed" }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || price == nil)
            }
        }
        .padding(20).frame(width: 520, height: 440).quotioPage().interactiveDismissDisabled(saving)
    }
}

/// 小额估算保留八位小数，避免正常的低单价请求被两位小数格式化成零费用。
private enum CPAUsagePriceFormatting {
    static func money(_ value: Double?, isPartial: Bool = false) -> String {
        // 金额下界仍必须有已知计价分量；没有单价或可估量时保持未知，不能显示 ≥ 0。
        value.map { (isPartial ? "≥ " : "") + $0.formatted(.currency(code: "USD").precision(.fractionLength(2...8))) } ?? "—"
    }
    static func rate(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...6))) } ?? "—"
    }
}
