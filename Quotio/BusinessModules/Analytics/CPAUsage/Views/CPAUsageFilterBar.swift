import SwiftUI

/// 请求明细与价格统计共用筛选条；编辑仍通过各页自己的 Binding 即时生效。
/// 只改变控件密度与摆放，不改变请求条件、选项目录或分页触发路径。
struct CPAUsageFilterBar: View {
    @Binding var selection: CPAUsageSelection
    let options: CPAUsageEventPage?
    /// 明细和费用页面保留独立标题行；复用字段时可以由外层面板提供标题与操作。
    var showsHeader = true
    /// 仅覆盖模型搜索浮层的内容宽度；未指定时沿用菜单默认值，筛选控件和日期浮层不受影响。
    var modelSearchPopoverWidth: CGFloat? = nil
    @State private var showsDates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                CPAUsageFilterHeader(selection: $selection)
            }

            // 宽窗口优先一行；宽度递减时按六、三、二、一列排列，控件顺序与状态不变。
            CPAUsageAdaptiveGrid(maximumColumns: 6, minimumColumnWidth: 136, spacing: 8) {
                CPAUsageCompactFilterField(titleKey: "usage.records.range", isActive: selection.range != .all) { rangeMenu }
                CPAUsageOptionMenu(titleKey: "usage.provider", value: $selection.provider,
                                   options: options?.providers ?? [], searchable: false, isCompact: true)
                CPAUsageOptionMenu(titleKey: "usage.model", value: $selection.model,
                                   options: options?.models ?? [], searchable: true, isCompact: true,
                                   searchPopoverWidth: modelSearchPopoverWidth)
                CPAUsageOptionMenu(titleKey: "usage.records.source", value: $selection.source,
                                   options: options?.sources ?? [], searchable: false, isCompact: true)
                CPAUsageOptionMenu(titleKey: "usage.records.apiKey", value: $selection.apiKey,
                                   options: options?.apiKeys ?? [], searchable: false, isCompact: true)
                CPAUsageCompactFilterField(titleKey: "usage.records.result", isActive: selection.outcome != .all) {
                    CPAUsageFilterMenu(titleKey: "usage.records.result", value: selection.outcome.titleKey.localized()) {
                        Picker("usage.records.result".localized(), selection: $selection.outcome) {
                            ForEach(CPAUsageOutcome.allCases, id: \.self) { Text($0.titleKey.localized()).tag($0) }
                        }.labelsHidden()
                    }
                }
            }
        }
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
        .popover(isPresented: $showsDates) { dateFilters }
    }

    private var rangeTitle: String {
        CPAUsageFilterSummary(selection: selection, options: options).rangeTitle
    }

    private var dateFilters: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(CPAUsageTimeRange.custom.titleKey.localized()).font(.headline)
            CPAUsageCustomDateFields(selection: $selection)
            HStack {
                Spacer()
                Button("action.close".localized()) { showsDates = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 390)
    }
}

/// 子页的紧凑字段：标题以字重与勾号标出已启用条件，原生控件仍负责完整名称、值和焦点。
private struct CPAUsageCompactFilterField<Content: View>: View {
    let titleKey: String
    let isActive: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if isActive { Image(systemName: "checkmark") }
                Text(titleKey.localized())
            }
            .font(.caption.weight(isActive ? .semibold : .medium))
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .accessibilityHidden(true)

            if #available(macOS 26.0, *) { content.buttonSizing(.flexible) }
            else { content }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 选项菜单与搜索浮层都保留原生焦点。长名称靠提示及无障碍值完整传递，不撑宽栏位。
struct CPAUsageOptionMenu: View {
    let titleKey: String
    @Binding var value: String
    let options: [CPAUsageOption]
    let searchable: Bool
    var isCompact = false
    var searchPopoverWidth: CGFloat? = nil
    @State private var showsSearch = false

    private var title: String {
        if value.isEmpty { return "usage.records.outcome.all".localized() }
        if value == "__unknown__" { return "usage.records.unknown".localized() }
        return options.first { $0.id == value }?.title ?? value
    }

    var body: some View {
        if isCompact {
            CPAUsageCompactFilterField(titleKey: titleKey, isActive: !value.isEmpty) { optionControl }
        } else {
            CPAUsageFilterField(titleKey: titleKey) { optionControl }
        }
    }

    @ViewBuilder private var optionControl: some View {
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
                CPAUsageOptionSearch(titleKey: titleKey, value: $value, options: options,
                                     isPresented: $showsSearch, width: searchPopoverWidth ?? 390)
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

/// 搜索状态只属于打开的浮层，使用原生输入框和焦点环，关闭后不影响页面筛选。
private struct CPAUsageOptionSearch: View {
    let titleKey: String
    @Binding var value: String
    let options: [CPAUsageOption]
    @Binding var isPresented: Bool
    let width: CGFloat
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
        .padding(16).frame(width: width, height: 380)
        .onAppear { isSearchFocused = true }
    }

    private func option(_ id: String, title: String) -> some View {
        Button { value = id; isPresented = false } label: {
            HStack {
                Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if value == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(value == id ? .isSelected : [])
    }
}

