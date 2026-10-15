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
        Task {
            await viewModel?.refreshQuotasUnified()
        }
    }
    
    @objc func openApp() {
        Self.openMainWindow()
    }
    
    @objc func openQuotaHistory(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? QuotaHistoryWindowContext,
              canPresentHistory(context) else { return }
        StatusBarManager.shared.closeMenu()
        // 先结束原生菜单的跟踪，再切换关键窗口；避免菜单事件栈内激活窗口造成焦点争抢。
        DispatchQueue.main.async { [weak self] in self?.showQuotaHistory(context) }
    }

    private func showQuotaHistory(_ context: QuotaHistoryWindowContext) {
        guard canPresentHistory(context), let quotaHistory else { return }
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
        window.title = "quota.history.title".localized()
        let content = QuotaHistoryWindowContent(context: context, settings: viewModel?.menuBarSettings ?? .shared,
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

/// 独立窗口也观察应用语言；不依赖主窗口重建才能刷新日期、坐标和系统控件的语言环境。
private struct QuotaHistoryWindowContent: View {
    let context: QuotaHistoryWindowContext
    let settings: MenuBarSettingsManager
    let service: QuotaHistoryService
    let onClose: () -> Void

    var body: some View {
        QuotaHistoryView(account: context.account, accountName: context.displayName,
            settings: settings, service: service, onClose: onClose)
            .environment(\.locale, LanguageManager.shared.locale)
    }
}
