import SwiftUI

/// 六个筛选条件共用原生菜单、选择器与搜索浮层，全部保留在 CPA 卡片下方。
/// 标题行承担重置与说明操作，字段按三列／两列排齐，不再混用自绘胶囊和系统下拉框。
struct CPAUsageFilterBar: View {
    @Binding var selection: CPAUsageSelection
    let options: CPAUsageEventPage?
    /// 明细和费用页面保留独立标题行；复用字段时可以由外层面板提供标题与操作。
    var showsHeader = true
    @State private var showsDates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                CPAUsageFilterHeader(selection: $selection)
            }

            CPAUsageAdaptiveGrid(maximumColumns: 3, minimumColumnWidth: 180) {
                CPAUsageFilterField(titleKey: "usage.records.range") { rangeMenu }
                CPAUsageOptionMenu(titleKey: "usage.provider", value: $selection.provider,
                                   options: options?.providers ?? [], searchable: false)
                CPAUsageOptionMenu(titleKey: "usage.model", value: $selection.model,
                                   options: options?.models ?? [], searchable: true)
                CPAUsageOptionMenu(titleKey: "usage.records.source", value: $selection.source,
                                   options: options?.sources ?? [], searchable: true)
                CPAUsageOptionMenu(titleKey: "usage.records.apiKey", value: $selection.apiKey,
                                   options: options?.apiKeys ?? [], searchable: true)
                CPAUsageFilterField(titleKey: "usage.records.result") {
                    CPAUsageFilterMenu(titleKey: "usage.records.result", value: selection.outcome.titleKey.localized()) {
                        Picker("usage.records.result".localized(), selection: $selection.outcome) {
                            ForEach(CPAUsageOutcome.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                        }.labelsHidden()
                    }
                }
            }
        }
        // 模型与提供商继续保持独立条件，外观调整不改变筛选语义或触发额外查询。
        .popover(isPresented: $showsDates) { dateFilters }
    }

    private var rangeMenu: some View {
        CPAUsageFilterMenu(titleKey: "usage.records.range", value: rangeTitle) {
            ForEach(CPAUsageTimeRange.allCases, id: \.self) { range in
                Button {
                    selection.range = range
                    if range == .custom { showsDates = true }
                } label: {
                    if selection.range == range { Label(range.titleKey.localized(), systemImage: "checkmark") }
                    else { Text(range.titleKey.localized()) }
                }
            }
        }
    }

    private var rangeTitle: String {
        CPAUsageFilterSummary(selection: selection, options: options).rangeTitle
    }

    private var dateFilters: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(CPAUsageTimeRange.custom.titleKey.localized()).font(.headline)
            DatePicker("callAnalytics.startDate".localized(), selection: $selection.start, in: ...selection.end,
                       displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.field)
            DatePicker("callAnalytics.endDate".localized(), selection: $selection.end, in: selection.start...,
                       displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.field)
            HStack {
                Spacer()
                Button("action.close".localized()) { showsDates = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 390)
    }
}

/// 少量提供商使用系统 Picker；模型、来源和密钥保留可搜索浮层。
/// 两种入口都使用系统边框和焦点反馈，长名称通过截断、提示及无障碍值完整保留。
struct CPAUsageOptionMenu: View {
    let titleKey: String
    @Binding var value: String
    let options: [CPAUsageOption]
    let searchable: Bool
    @State private var showsSearch = false

    private var title: String {
        if value.isEmpty { return "usage.records.outcome.all".localized() }
        if value == "__unknown__" { return "usage.records.unknown".localized() }
        return options.first { $0.id == value }?.title ?? value
    }

    var body: some View {
        CPAUsageFilterField(titleKey: titleKey) {
            if searchable {
                Button { showsSearch = true } label: {
                    HStack(spacing: 8) {
                        Text(title).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .help(title)
                .accessibilityLabel(titleKey.localized())
                .accessibilityValue(title)
                .popover(isPresented: $showsSearch) {
                    CPAUsageOptionSearch(titleKey: titleKey, value: $value, options: options, isPresented: $showsSearch)
                }
            } else {
                CPAUsageFilterMenu(titleKey: titleKey, value: title) {
                    Picker(titleKey.localized(), selection: $value) {
                        Text("usage.records.outcome.all".localized()).tag("")
                        Text("usage.records.unknown".localized()).tag("__unknown__")
                        ForEach(options) { item in Text(item.title).tag(item.id) }
                        if !value.isEmpty, value != "__unknown__", !options.contains(where: { $0.id == value }) {
                            // 后台重查选项时仍展示已有选择，不能暂时将其画成“全部”或无效标签。
                            Text(title).tag(value)
                        }
                    }.labelsHidden()
                }
            }
        }
    }
}

/// 搜索状态只属于打开的浮层，使用原生输入框和焦点环，关闭后不影响页面筛选。
private struct CPAUsageOptionSearch: View {
    let titleKey: String
    @Binding var value: String
    let options: [CPAUsageOption]
    @Binding var isPresented: Bool
    @State private var search = ""
    @FocusState private var isSearchFocused: Bool

    private var matchingOptions: [CPAUsageFilterChoice] {
        // 冻结选项快照可能不包含当前值；将它作为可选行补回，保证搜索面板中的选中标记可见。
        CPAUsageFilterChoice.options(options, selected: value,
            allTitle: "usage.records.outcome.all".localized(), unknownTitle: "usage.records.unknown".localized())
            .filter { !$0.id.isEmpty && $0.id != "__unknown__" }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey.localized()).font(.headline)
            TextField("usage.dashboard.search".localized(), text: $search)
                .textFieldStyle(.roundedBorder).focused($isSearchFocused)
                .accessibilityLabel("usage.dashboard.search".localized())
            List {
                option("", title: "usage.records.outcome.all".localized())
                option("__unknown__", title: "usage.records.unknown".localized())
                ForEach(matchingOptions) { item in
                    option(item.id, title: item.title)
                }
            }.listStyle(.plain)
        }
        .padding(16).frame(width: 390, height: 380)
        .onAppear { isSearchFocused = true }
    }

    private func option(_ id: String, title: String) -> some View {
        Button { value = id; isPresented = false } label: {
            HStack {
                Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if value == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// 图表设置保持在公共筛选卡底部，与六个数据条件分层，使用同样的字段和系统菜单。
struct CPAUsageChartControls: View {
    @Binding var dimension: CPAUsageDimension
    @Binding var metric: CPAUsageChartMetric

    var body: some View {
        CPAUsageAdaptiveGrid(maximumColumns: 2, minimumColumnWidth: 180) {
            CPAUsageFilterField(titleKey: "usage.dashboard.groupBy") {
                CPAUsageFilterMenu(titleKey: "usage.dashboard.groupBy", value: dimension.titleKey.localized()) {
                    Picker("usage.dashboard.groupBy".localized(), selection: $dimension) {
                        ForEach(CPAUsageDimension.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                    }.labelsHidden()
                }
            }
            CPAUsageFilterField(titleKey: "usage.dashboard.chartMetric") {
                CPAUsageFilterMenu(titleKey: "usage.dashboard.chartMetric", value: metric.titleKey.localized()) {
                    Picker("usage.dashboard.chartMetric".localized(), selection: $metric) {
                        ForEach(CPAUsageChartMetric.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                    }.labelsHidden()
                }
            }
        }
    }
}
