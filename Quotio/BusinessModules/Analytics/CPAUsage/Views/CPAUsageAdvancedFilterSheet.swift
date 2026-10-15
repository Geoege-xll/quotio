import SwiftUI

/// 原生 Sheet 的内容视图保持 internal，预览可以直接使用生产组件和构造数据。
/// 这里不持有外部条件的 Binding；每次打开创建独立草稿，只有“应用”回调一次完整值。
struct CPAUsageAdvancedFilterSheet: View {
    @State private var draft: CPAUsageFilterDraft
    @State private var availableOptions: CPAUsageFilterOptions
    @State private var isLoadingOptions = false
    @State private var optionsErrorKey: String?
    @State private var optionsLoadAttempt = 0
    let loadOptions: (() async throws -> CPAUsageFilterOptions)?
    let onApply: (CPAUsageFilterDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    init(draft: CPAUsageFilterDraft, options: CPAUsageEventPage?,
         loadOptions: (() async throws -> CPAUsageFilterOptions)? = nil,
         onApply: @escaping (CPAUsageFilterDraft) -> Void) {
        _draft = State(initialValue: draft.normalized)
        _availableOptions = State(initialValue: CPAUsageFilterOptions(providers: options?.providers ?? [],
            models: options?.models ?? [], sources: options?.sources ?? [], apiKeys: options?.apiKeys ?? []))
        self.loadOptions = loadOptions
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("usage.dashboard.allFilters".localized()).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("usage.dashboard.filtersDraftHint".localized()).font(.callout).foregroundStyle(.secondary)
            }
            if isLoadingOptions {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("usage.dashboard.filterOptionsLoading".localized()).font(.caption).foregroundStyle(.secondary)
                }
            } else if let optionsErrorKey {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(optionsErrorKey.localized(), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(QuotioTheme.Colors.warning)
                    Spacer(minLength: 0)
                    Button("action.retry".localized()) { optionsLoadAttempt &+= 1 }
                        .buttonStyle(.borderless).fixedSize()
                        .accessibilityIdentifier("cpaFilterOptionsRetryButton")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CPAUsageAdaptiveGrid(maximumColumns: 2, minimumColumnWidth: 230) {
                        CPAUsageFilterField(titleKey: "usage.records.range") {
                            CPAUsageFilterMenu(titleKey: "usage.records.range", value: draft.selection.range.titleKey.localized()) {
                                Picker("usage.records.range".localized(), selection: $draft.selection.range) {
                                    ForEach(CPAUsageTimeRange.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                                }.labelsHidden()
                            }
                        }
                        CPAUsageOptionMenu(titleKey: "usage.provider", value: $draft.selection.provider,
                            options: availableOptions.providers, searchable: true)
                    }
                    if draft.selection.range == .custom {
                        ScrollView(.horizontal) {
                            CPAUsageCustomDateFields(selection: $draft.selection)
                        }.scrollIndicators(.hidden).frame(height: 32)
                    }
                    CPAUsageAdaptiveGrid(maximumColumns: 2, minimumColumnWidth: 230) {
                        CPAUsageOptionMenu(titleKey: "usage.model", value: $draft.selection.model,
                            options: availableOptions.models, searchable: true)
                        CPAUsageOptionMenu(titleKey: "usage.records.source", value: $draft.selection.source,
                            options: availableOptions.sources, searchable: false)
                        CPAUsageOptionMenu(titleKey: "usage.records.apiKey", value: $draft.selection.apiKey,
                            options: availableOptions.apiKeys, searchable: false)
                        CPAUsageFilterField(titleKey: "usage.records.result") {
                            CPAUsageFilterMenu(titleKey: "usage.records.result", value: draft.selection.outcome.titleKey.localized()) {
                                Picker("usage.records.result".localized(), selection: $draft.selection.outcome) {
                                    ForEach(CPAUsageOutcome.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                                }.labelsHidden()
                            }
                        }
                        CPAUsageFilterField(titleKey: "usage.dashboard.groupBy") {
                            CPAUsageFilterMenu(titleKey: "usage.dashboard.groupBy", value: draft.dimension.titleKey.localized()) {
                                Picker("usage.dashboard.groupBy".localized(), selection: $draft.dimension) {
                                    ForEach(CPAUsageDimension.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                                }.labelsHidden()
                            }
                        }
                        CPAUsageFilterField(titleKey: "usage.dashboard.chartMetric") {
                            CPAUsageFilterMenu(titleKey: "usage.dashboard.chartMetric", value: draft.metric.titleKey.localized()) {
                                Picker("usage.dashboard.chartMetric".localized(), selection: $draft.metric) {
                                    ForEach(CPAUsageChartMetric.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                                }.labelsHidden()
                            }
                        }
                    }
                    Text("usage.records.privacy".localized()).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            Divider()
            HStack(spacing: 10) {
                Button("usage.cpa.resetFilters".localized()) { draft.reset() }
                    .accessibilityIdentifier("cpaResetFilterDraftButton")
                Spacer()
                Button("action.cancel".localized()) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cpaCancelFilterDraftButton")
                Button("action.apply".localized()) {
                    // 同步回调只有一处；Sheet 编辑、重置和取消都不会触发外部查询。
                    onApply(draft.normalized)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cpaApplyFilterDraftButton")
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 740, minHeight: 450, idealHeight: 540, maxHeight: 680)
        // Sheet 的原生任务随关闭取消；重查只由打开或显式重试触发，任何草稿输入都不更改任务标识。
        .task(id: optionsLoadAttempt) { await loadCompleteOptions() }
    }

    @MainActor private func loadCompleteOptions() async {
        guard let loadOptions else { return }
        isLoadingOptions = true
        optionsErrorKey = nil
        defer { isLoadingOptions = false }
        do {
            let value = try await loadOptions()
            try Task.checkCancellation()
            // 只替换全时间选项目录，不改动用户已经编辑的时间、模型或其他草稿条件。
            availableOptions = value
        } catch {
            guard !Task.isCancelled else { return }
            optionsErrorKey = "usage.dashboard.filterOptionsFailed"
        }
    }
}

/// 完整筛选面板保留自定义起止字段与小时/分钟精度；仪表盘顶部只展示预设时间段。
/// 值的读取先归一上下界，兼容外部传入的反向时间；用户编辑只更新当前持有的 Binding。
struct CPAUsageCustomDateFields: View {
    @Binding var selection: CPAUsageSelection

    private var lower: Date { min(selection.start, selection.end) }
    private var upper: Date { max(selection.start, selection.end) }
    private var startBinding: Binding<Date> {
        Binding(get: { lower }, set: { date in
            var value = selection
            value.start = date; value.end = max(date, upper)
            selection = value
        })
    }
    private var endBinding: Binding<Date> {
        Binding(get: { upper }, set: { date in
            var value = selection
            value.end = date; value.start = min(date, lower)
            selection = value
        })
    }

    var body: some View {
        HStack(spacing: 12) {
            DatePicker("callAnalytics.startDate".localized(), selection: startBinding, in: ...upper,
                       displayedComponents: [.date, .hourAndMinute])
            DatePicker("callAnalytics.endDate".localized(), selection: endBinding, in: lower...,
                       displayedComponents: [.date, .hourAndMinute])
        }
        .datePickerStyle(.field).controlSize(.small)
        .font(.caption).monospacedDigit().fixedSize()
    }
}
