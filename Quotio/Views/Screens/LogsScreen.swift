import SwiftUI
import AppKit

struct LogsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(LogsViewModel.self) private var logsViewModel
    @State private var followsLatest = true
    @State private var newestFirst = true
    @State private var filterLevel: LogEntry.LogLevel?
    @State private var searchText = ""
    @State private var selection: UUID?
    @State private var showsClearConfirmation = false
    @State private var hasNewLogs = false
    @State private var copyFeedback: String?
    @AppStorage("loggingToFile") private var loggingToFile = true

    /// 连接身份改变即重启页面轮询，避免沿用旧管理密钥或旧服务的文件游标。
    private var connectionIdentity: String {
        "\(viewModel.proxyManager.proxyStatus.running)|\(loggingToFile)|\(viewModel.proxyManager.managementURL)|\(viewModel.proxyManager.managementKey)"
    }

    private var filteredLogs: [LogEntry] {
        logsViewModel.logs.enumerated().filter { _, entry in
            (filterLevel == nil || entry.level == filterLevel)
                && (searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText))
        }.sorted { lhs, rhs in
            // 无时间记录固定放到末尾；相同时间使用文件原序作为稳定次序。
            switch (lhs.element.timestamp, rhs.element.timestamp) {
            case let (left?, right?) where left != right:
                return newestFirst ? left > right : left < right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    var body: some View {
        Group {
            if !viewModel.proxyManager.proxyStatus.running {
                ProxyRequiredView(description: "logs.startProxy".localized()) {
                    await viewModel.startProxy()
                }
            } else if !loggingToFile {
                ContentUnavailableView("logs.browser.disabled".localized(), systemImage: "doc.text",
                    description: Text("logs.browser.disabledHelp".localized()))
            } else {
                browser
            }
        }
        .modifier(SettingsPageBackground())
        .navigationTitle("logs.browser.title".localized())
        .searchable(text: $searchText, prompt: "logs.searchLogs".localized())
        .toolbar { toolbar }
        .confirmationDialog("logs.browser.clearTitle".localized(), isPresented: $showsClearConfirmation) {
            Button("logs.browser.clear".localized(), role: .destructive) {
                Task { await logsViewModel.clearLogs() }
            }
            Button("action.cancel".localized(), role: .cancel) { }
        } message: {
            Text("logs.browser.clearHelp".localized())
        }
        .task(id: connectionIdentity) {
            guard viewModel.proxyManager.proxyStatus.running, loggingToFile else {
                logsViewModel.reset()
                return
            }
            logsViewModel.configure(baseURL: viewModel.proxyManager.managementURL,
                                    authKey: viewModel.proxyManager.managementKey)
            while !Task.isCancelled {
                await logsViewModel.refreshLogs()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
        .onChange(of: logsViewModel.revision) { _, _ in
            if !followsLatest { hasNewLogs = true }
        }
        .onChange(of: followsLatest) { _, follows in
            if follows { hasNewLogs = false }
        }
    }

    private var browser: some View {
        let rows = filteredLogs
        return VStack(spacing: 0) {
            if let error = logsViewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if rows.isEmpty {
                ContentUnavailableView {
                    Label((logsViewModel.logs.isEmpty ? "logs.noLogs" : "logs.browser.noMatches").localized(),
                          systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text((logsViewModel.logs.isEmpty ? "logs.logsWillAppear" : "logs.browser.noMatchesHelp").localized())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeLogTable(rows: rows, newestFirst: $newestFirst,
                               followsLatest: $followsLatest, selection: $selection)
                    .frame(minHeight: 180)
            }
            if let selected = rows.first(where: { $0.id == selection }) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("logs.browser.details".localized()).font(.headline)
                        Spacer()
                        Button("action.copy".localized(), systemImage: "doc.on.doc") { copy(selected.message) }
                            .buttonStyle(.borderless)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        // 保留完整原文及多行堆栈，列表省略不代表日志内容被截断。
                        Text(selected.message)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
                .padding(12)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(); updateStatus }
                VStack(alignment: .leading, spacing: 6) { status; updateStatus }
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "logs.browser.retention".localized(), filteredLogs.count, logsViewModel.retainedLineLimit))
                .monospacedDigit()
            if logsViewModel.usesLegacySnapshot {
                Text("logs.browser.legacy".localized())
            }
            if let copyFeedback { Text(copyFeedback) }
        }
    }

    private var updateStatus: some View {
        HStack {
            if hasNewLogs {
                Button("logs.browser.newLogs".localized()) { followsLatest = true }
            }
            if logsViewModel.isRefreshing || logsViewModel.isClearing {
                ProgressView().controlSize(.small)
            } else if let updated = logsViewModel.lastUpdated {
                Text(updated, style: .time).monospacedDigit()
                    .help("logs.browser.updated".localized())
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("logs.browser.level".localized(), selection: $filterLevel) {
                Text("logs.all".localized()).tag(nil as LogEntry.LogLevel?)
                ForEach([LogEntry.LogLevel.info, .warn, .error, .debug, .unknown], id: \.self) { level in
                    Text(level.rawValue.uppercased()).tag(level as LogEntry.LogLevel?)
                }
            }
            .pickerStyle(.menu)
            Toggle("logs.browser.follow".localized(), isOn: $followsLatest)
                .help("logs.browser.followHelp".localized())
            Button("action.refresh".localized(), systemImage: "arrow.clockwise") {
                Task { await logsViewModel.refreshLogs() }
            }
            .disabled(logsViewModel.isRefreshing || logsViewModel.isClearing || !loggingToFile
                      || !viewModel.proxyManager.proxyStatus.running)
            Menu {
                Button("logs.browser.copyVisible".localized(), systemImage: "doc.on.doc") {
                    copy(filteredLogs.map(\.message).joined(separator: "\n"))
                }
                .disabled(filteredLogs.isEmpty)
                Divider()
                Button("logs.browser.clear".localized(), systemImage: "trash", role: .destructive) {
                    showsClearConfirmation = true
                }
                .disabled(logsViewModel.isRefreshing || logsViewModel.isClearing || !loggingToFile
                          || !viewModel.proxyManager.proxyStatus.running)
            } label: {
                Label("apiKeys.manager.more".localized(), systemImage: "ellipsis.circle")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        let succeeded = NSPasteboard.general.setString(text, forType: .string)
        copyFeedback = (succeeded ? "availableModels.copied" : "runtime.copyFailed").localized()
    }
}

/// 原生 AppKit 表格桥接仅负责列表交互，数据解析和排序规则仍由上层管理。
/// macOS 14 的 SwiftUI Table 缺少精确行滚动控制，因此直接使用系统 NSTableView，
/// 不通过查找 SwiftUI 私有视图树来实现跟随，也不自绘表头、选中态或滚动条。
private struct NativeLogTable: NSViewRepresentable {
    let rows: [LogEntry]
    @Binding var newestFirst: Bool
    @Binding var followsLatest: Bool
    @Binding var selection: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = NSTableView()
        table.style = .inset
        table.rowHeight = 30
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        for (key, title, width) in [
            ("time", "logs.browser.time", CGFloat(182)),
            ("level", "logs.browser.level", CGFloat(82)),
            ("message", "logs.browser.message", CGFloat(500))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title.localized()
            column.width = width
            if key == "message" {
                column.minWidth = 220
                column.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                column.minWidth = width
                column.maxWidth = width
                column.resizingMask = []
            }
            if key == "time" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: "time", ascending: false)
            }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "time", ascending: !newestFirst)]
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        // 只监听用户启动的滚动，不把程序化“跟随最新”误判成主动浏览历史。
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.userStartedScrolling(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let oldRows = coordinator.parent.rows
        // Binding 会即时读取最新状态，不能用旧 parent 中的 Binding 判断开关变化。
        // 读取上次实际应用到表格的独立快照，确保重新开启跟随时立即执行定位。
        let oldFollowing = coordinator.lastFollowsLatest
        let oldOrder = coordinator.lastNewestFirst
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        let changed = oldRows.map(\.id) != rows.map(\.id) || table.numberOfRows != rows.count
        coordinator.updating = true
        defer {
            coordinator.lastFollowsLatest = followsLatest
            coordinator.lastNewestFirst = newestFirst
            coordinator.updating = false
        }
        if changed {
            // 暂停跟随时以可见首行身份恢复位置，顶部插入或有界淘汰不会抢走阅读位置。
            let oldIndex = table.row(at: scroll.contentView.bounds.origin)
            let anchor = oldRows.indices.contains(oldIndex) ? oldRows[oldIndex].id : nil
            let previousOrigin = scroll.contentView.bounds.origin
            let rowOffset = oldIndex >= 0 ? previousOrigin.y - table.rect(ofRow: oldIndex).minY : 0
            table.reloadData()
            if let selection, let index = rows.firstIndex(where: { $0.id == selection }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
            if !followsLatest {
                let y = anchor.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
                    .map { table.rect(ofRow: $0).minY + rowOffset } ?? previousOrigin.y
                scroll.contentView.scroll(to: NSPoint(x: previousOrigin.x, y: max(0, y)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if followsLatest && (changed || !oldFollowing || oldOrder != newestFirst), !rows.isEmpty {
            // 未知时间排在末尾，正序跟随时应定位最后一个有时间的事件，而非未知记录。
            let latestIndex = newestFirst ? 0 : (rows.lastIndex { $0.timestamp != nil } ?? rows.count - 1)
            table.scrollRowToVisible(latestIndex)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeLogTable
        weak var table: NSTableView?
        var updating = false
        // 初始视为未跟随，使首次显示已有日志时也能定位最新事件。
        // 只在 updateNSView 完成后更新，避免双向绑定覆盖前一次呈现状态。
        var lastFollowsLatest = false
        var lastNewestFirst = true
        private let formatter: DateFormatter = {
            let value = DateFormatter()
            value.locale = Locale(identifier: "en_US_POSIX")
            value.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return value
        }()

        init(_ parent: NativeLogTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row), let column = tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView)
                ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = column.identifier
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingTail
                text.maximumNumberOfLines = 1
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            let entry = parent.rows[row]
            let text = cell.textField!
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textColor = .labelColor
            switch column.identifier.rawValue {
            case "time":
                text.stringValue = entry.timestamp.map { formatter.string(from: $0) }
                    ?? "logs.browser.unknownTime".localized()
                text.textColor = .secondaryLabelColor
            case "level":
                text.stringValue = entry.level.rawValue.uppercased()
                switch entry.level {
                case .error: text.textColor = .systemRed
                case .warn: text.textColor = .systemOrange
                case .debug, .unknown: text.textColor = .secondaryLabelColor
                case .info: break
                }
            default:
                text.stringValue = entry.message.components(separatedBy: .newlines).first ?? entry.message
            }
            cell.toolTip = entry.message
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            parent.newestFirst = !descriptor.ascending
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let row = table.selectedRow
            parent.selection = parent.rows.indices.contains(row) ? parent.rows[row].id : nil
            // 选中表示用户正在阅读详情，后续轮询不应强制移动列表。
            parent.followsLatest = false
        }

        @objc func userStartedScrolling(_ notification: Notification) {
            guard !updating else { return }
            parent.followsLatest = false
        }
    }
}
