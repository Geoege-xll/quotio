//
//  MenuActionHandler.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏原有动作与主窗口唤起入口。
/// 保留 shared 实例和 viewModel 弱引用；刷新任务仍在原方法中创建，不向组件转移任务所有权。
// MARK: - Menu Action Handler

@MainActor
final class MenuActionHandler: NSObject, NSWindowDelegate {
    static let shared = MenuActionHandler()
    
    weak var viewModel: QuotaViewModel?
    /// 历史服务由 AppBootstrap 持有；动作入口只借用，不创建业务单例或第二个采样宿主。
    weak var quotaHistory: QuotaHistoryService?
    /// 历史窗口属于应用呈现层，复用一个原生窗口，不在账号 VM 中新增窗口或采集状态。
    private var historyWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    @objc func refresh() {
        // 原生选择器可能由已打开的菜单触发，仍在任务执行前核对 CPA 可用性。
        Task {
            guard let viewModel, viewModel.canRefreshAccountQuotas else { return }
            await viewModel.manualRefresh()
        }
    }
    
    @objc func openApp() {
        Self.openMainWindow()
    }
    
    @objc func openQuotaHistory(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? QuotaHistoryWindowContext,
              canPresentHistory(context) else { return }
        queueHistoryWindow(.account(context))
    }

    @objc func openLegacyQuotaHistory() {
        guard quotaHistory != nil else { return }
        queueHistoryWindow(.legacy)
    }

    private func queueHistoryWindow(_ source: QuotaHistoryWindowSource) {
        StatusBarManager.shared.closeMenu()
        // 先结束原生菜单的跟踪，再切换关键窗口；避免菜单事件栈内激活窗口造成焦点争抢。
        DispatchQueue.main.async { [weak self] in self?.showQuotaHistory(source) }
    }

    private func showQuotaHistory(_ source: QuotaHistoryWindowSource) {
        guard let quotaHistory else { return }
        if case .account(let context) = source, !canPresentHistory(context) { return }

        let window: NSWindow
        if let existing = historyWindow { window = existing }
        else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("quotio.quotaHistory")
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 520)
            window.center()
            historyWindow = window
        }
        window.title = source.titleKey.localized()
        let content = QuotaHistoryWindowContent(source: source, settings: viewModel?.menuBarSettings ?? .shared,
            service: quotaHistory, onClose: { [weak window] in window?.close() })
        window.contentView = NSHostingView(rootView: content)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func canPresentHistory(_ context: QuotaHistoryWindowContext) -> Bool {
        // 点击后还会异步切换关键窗口，因此实际呈现前再次校验，覆盖菜单动作与回调间的模式切换。
        guard let manager = viewModel?.modeManager else { return false }
        return context.isCurrent(mode: manager.currentMode, revision: manager.revision)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === historyWindow else { return }
        // 保留窗口壳用于下次打开，但释放 HostingView，取消其中 .task 和观察，关闭后不继续查库。
        window.contentView = nil
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    static func openMainWindow() {
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        if showInDock {
            StatusBarManager.shared.closeMenu()
        }

        NSApplication.shared.activate(ignoringOtherApps: true)

        let candidate = NSApplication.shared.windows.first(where: {
            $0.canBecomeMain && $0.level == .normal && $0.identifier?.rawValue != "quotio.quotaHistory"
        })

        if let window = candidate {
            window.makeKeyAndOrderFront(nil)

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            window.orderFrontRegardless()
        } else {
            AppBootstrap.shared.openWindowHandler?()
        }
    }
}

/// 原生菜单动作只携带账号身份与可遮罩显示名，不携带凭据或 API Key。
struct QuotaHistoryWindowContext {
    let account: QuotaHistoryAccount
    let displayName: String
    var sourceRevision: UInt64? = nil

    func isCurrent(mode: OperatingMode, revision: UInt64) -> Bool {
        account.mode == mode.rawValue && (sourceRevision == nil || sourceRevision == revision)
    }
}

/// 两个入口复用原窗口壳；旧历史选择不携带当前代理账号身份。
private enum QuotaHistoryWindowSource {
    case account(QuotaHistoryWindowContext)
    case legacy

    var titleKey: String {
        switch self {
        case .account: "quota.history.title"
        case .legacy: "quota.history.legacy"
        }
    }
}

/// 独立窗口也观察应用语言；不依赖主窗口重建才能刷新日期、坐标和系统控件的语言环境。
private struct QuotaHistoryWindowContent: View {
    let source: QuotaHistoryWindowSource
    let settings: MenuBarSettingsManager
    let service: QuotaHistoryService
    let onClose: () -> Void

    var body: some View {
        Group {
            switch source {
            case .account(let context):
                QuotaHistoryView(account: context.account, accountName: context.displayName,
                    settings: settings, service: service, onClose: onClose)
            case .legacy:
                LegacyQuotaHistoryContent(settings: settings, service: service, onClose: onClose)
            }
        }
        .environment(\.locale, LanguageManager.shared.locale)
    }
}

/// 打开旧历史窗口后才读取历史目录。选择状态只是精确数据库身份，不在当前账号之间做映射。
private struct LegacyQuotaHistoryContent: View {
    let settings: MenuBarSettingsManager
    let service: QuotaHistoryService
    let onClose: () -> Void
    @State private var accounts: [QuotaHistoryAccount] = []
    @State private var selection: QuotaHistoryAccount?
    @State private var isLoading = true
    @State private var errorKey: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().accessibilityLabel("quota.history.legacy".localized())
            } else if let errorKey {
                ContentUnavailableView(errorKey.localized(), systemImage: "exclamationmark.triangle")
            } else if let account = selection {
                VStack(spacing: 0) {
                    accountPickers(for: account)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)

                    // 账号变化时重建原图表查询状态，上一账号指标、悬停值和图不会闪到新账号。
                    QuotaHistoryView(account: account, accountName: account.accountKey,
                        settings: settings, service: service, isReadOnly: true, onClose: onClose)
                        .id(account)
                }
            } else {
                ContentUnavailableView("quota.history.legacy.empty".localized(), systemImage: "clock",
                    description: Text("quota.history.legacy.emptyHelp".localized()))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 旧观测不会被当前额度写入修改，只在首次进入或存储维护状态改变时更新目录。
        .task(id: service.isSuspended) { await loadAccounts() }
    }

    private func accountPickers(for account: QuotaHistoryAccount) -> some View {
        let providers = Set(accounts.map(\.provider)).sorted { $0.displayName < $1.displayName }
        let matching = accounts.filter { $0.provider == account.provider }
        let labels = matching.map { $0.accountKey.masked(if: settings.hideSensitiveInfo) }
        let counts = labels.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return HStack {
            Picker("quota.history.legacy.provider".localized(), selection: Binding(
                get: { selection?.provider ?? account.provider },
                set: { provider in selection = accounts.first { $0.provider == provider } }
            )) {
                ForEach(providers) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            Picker("quota.history.legacy.account".localized(), selection: Binding(
                get: { selection ?? account }, set: { selection = $0 }
            )) {
                ForEach(matching.indices, id: \.self) { index in
                    let label = labels[index]
                    // 只有脱敏后标签重名时才加序号；可区分选项且不追加任何原始键片段。
                    let display = counts[label, default: 0] > 1 ? "\(label) · \(index + 1)" : label
                    Text(verbatim: display).tag(matching[index])
                }
            }
        }
        .pickerStyle(.menu)
    }

    private func loadAccounts() async {
        guard !Task.isCancelled else { return }
        isLoading = true
        errorKey = nil
        defer { if !Task.isCancelled { isLoading = false } }

        do {
            let result = try await service.legacyAccounts()
            guard !Task.isCancelled else { return }
            accounts = result
            if selection.map({ !result.contains($0) }) ?? true {
                selection = result.first
            }
        } catch is CancellationError {
            // 维护开始或窗口被关闭时不提交旧查询；维护状态变化由 .task 重新加载。
        } catch {
            guard !Task.isCancelled else { return }
            if case QuotaHistoryError.busy = error { errorKey = "quota.history.maintenance" }
            else { errorKey = "quota.history.readFailed" }
        }
    }
}
