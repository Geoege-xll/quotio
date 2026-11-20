import SwiftUI

/// 原生 Sheet 的内容视图保持 internal，预览可以直接使用生产组件和构造数据。
/// 这里不持有外部条件的 Binding；每次打开创建独立草稿，只有“应用”回调一次完整值。
struct CPAUsageAdvancedFilterSheet: View {
    @State private var draft: CPAUsageFilterDraft
    @State private var availableOptions: CPAUsageFilterOptions
    @State private var isLoadingOptions = false
    @State private var optionsErrorKey: String?
    @State private var optionsLoadAttempt = 0
    @State private var didApply = false
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("usage.dashboard.allFilters".localized()).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("usage.dashboard.filtersDraftHint".localized()).font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    optionsStatus
                    filterGroup("usage.dashboard.filterGroup.time") { timeFields }
                    Divider()
                    filterGroup("usage.dashboard.filterGroup.request") { requestFields }
                    Divider()
                    filterGroup("usage.dashboard.filterGroup.display") { displayFields }
                    Text("usage.records.privacy".localized()).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 只滚动表单。重置、Esc 取消与 Return 应用始终位于 Sheet 的底部操作区。
            Divider()
            footer
                .padding([.horizontal, .bottom], 20)
        }
        .frame(minWidth: 380, idealWidth: 640, maxWidth: 740, minHeight: 340, idealHeight: 560, maxHeight: 720)
        // Sheet 的原生任务随关闭取消；重查只由打开或显式重试触发，任何草稿输入都不更改任务标识。
        .task(id: optionsLoadAttempt) { await loadCompleteOptions() }
    }

    @ViewBuilder private var optionsStatus: some View {
        if isLoadingOptions {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("usage.dashboard.filterOptionsLoading".localized()).font(.caption).foregroundStyle(.secondary)
            }
        } else if let optionsErrorKey {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(optionsErrorKey.localized(), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                Spacer(minLength: 0)
                Button("action.retry".localized()) { optionsLoadAttempt &+= 1 }
                    .controlSize(.small).fixedSize()
                    .accessibilityIdentifier("cpaFilterOptionsRetryButton")
            }
        }
    }

    private func filterGroup<Content: View>(_ titleKey: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey.localized()).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var timeFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            CPAUsageFilterField(titleKey: "usage.records.range") {
                CPAUsageFilterMenu(titleKey: "usage.records.range", value: draft.selection.range.titleKey.localized()) {
                    Picker("usage.records.range".localized(), selection: $draft.selection.range) {
                        ForEach(CPAUsageTimeRange.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                    }.labelsHidden()
                }
            }
            if draft.selection.range == .custom {
                CPAUsageCustomDateFields(selection: $draft.selection, allowsSideBySide: true)
            }
        }
    }

    private var requestFields: some View {
        CPAUsageAdaptiveGrid(maximumColumns: 2, minimumColumnWidth: 205, spacing: 10, allowsIncompleteLastRow: true) {
            CPAUsageOptionMenu(titleKey: "usage.provider", value: $draft.selection.provider,
                               options: availableOptions.providers, searchable: true)
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
        }
    }

    private var displayFields: some View {
        CPAUsageAdaptiveGrid(maximumColumns: 2, minimumColumnWidth: 205, spacing: 10) {
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
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                resetButton
                Spacer(minLength: 12)
                confirmButtons
            }
            VStack(alignment: .trailing, spacing: 8) {
                resetButton.frame(maxWidth: .infinity, alignment: .leading)
                confirmButtons
            }
        }
    }

    private var resetButton: some View {
        Button("usage.cpa.resetFilters".localized()) { draft.reset() }
            .fixedSize()
            .accessibilityIdentifier("cpaResetFilterDraftButton")
    }

    private var confirmButtons: some View {
        HStack(spacing: 8) {
            Button("action.cancel".localized()) { dismiss() }.keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cpaCancelFilterDraftButton")
            Button("action.apply".localized()) {
                // 快速重复按键或点击也只提交一次完整归一值；取消和重置没有外部写回路径。
                guard !didApply else { return }
                didApply = true
                onApply(draft.normalized)
                dismiss()
            }
            .disabled(didApply)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("cpaApplyFilterDraftButton")
        }
        .fixedSize()
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
    var allowsSideBySide = false

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
        Group {
            if allowsSideBySide {
                ViewThatFits(in: .horizontal) {
                    // 保留原生字段的完整宽度；窄窗口统一用纵排，不通过横向滚动隐藏分钟。
                    HStack(alignment: .top, spacing: 20) { fields }
                        .frame(minWidth: 420, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    stackedFields
                }
            } else {
                stackedFields
            }
        }
        .datePickerStyle(.field).controlSize(.small)
        .monospacedDigit()
    }

    private var stackedFields: some View {
        VStack(alignment: .leading, spacing: 8) { fields }
    }

    @ViewBuilder private var fields: some View {
        dateField("callAnalytics.startDate") {
            DatePicker("callAnalytics.startDate".localized(), selection: startBinding, in: ...upper,
                       displayedComponents: [.date, .hourAndMinute])
        }
        dateField("callAnalytics.endDate") {
            DatePicker("callAnalytics.endDate".localized(), selection: endBinding, in: lower...,
                       displayedComponents: [.date, .hourAndMinute])
        }
    }

    private func dateField<Content: View>(_ titleKey: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey.localized()).font(.caption.weight(.medium))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            content().labelsHidden().fixedSize()
        }
    }
}
