//
//  QuotioApp.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import AppKit
import SwiftUI
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

private var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

// MARK: - App Bootstrap (Singleton for headless initialization)

/// Manages app-wide initialization that must happen regardless of window visibility.
/// This ensures the app works correctly when launched at login without opening a window.
@MainActor
final class AppBootstrap {
    static let shared = AppBootstrap()

    let viewModel = QuotaViewModel(accountSnapshotDefaults: .standard)
    let logsViewModel = LogsViewModel()
    /// 历史业务服务由应用唯一装配，菜单、设置、独立窗口和维护入口复用同一实例。
    /// 不新增业务 static shared，窗口重建也不重复创建采样任务或数据库连接。
    let quotaHistory = QuotaHistoryService()
    private var quotaHistoryObservation: NSObjectProtocol?

    private var hasInitialized = false
    var openWindowHandler: (@MainActor () -> Void)?

    private let appearanceManager = AppearanceManager.shared
    private let statusBarManager = StatusBarManager.shared
    private let menuBarSettings = MenuBarSettingsManager.shared

    private init() {}

    /// 由应用委托在进程启动时调用，窗口重建或首次引导都不会重复启动服务。
    func initializeIfNeeded() async {
        guard !hasInitialized else { return }
        hasInitialized = true

        appearanceManager.applyAppearance()

        // Setup menu bar immediately so user can open it while data loads
        statusBarManager.setViewModel(viewModel, history: quotaHistory)
        updateStatusBar()

        // Listen for quota data changes to update menu bar even when window is closed
        NotificationCenter.default.addObserver(
            forName: QuotaViewModel.quotaDataDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusBar()
                StatusBarManager.shared.rebuildMenuInPlace()
            }
        }

        // 采样注册在真实取数前，来源模式与旧／新快照在提交时同步捕获。
        // 不从菜单通知反推来源，避免模式切换后的旧缓存被记作另一模式的新观测。
        if quotaHistoryObservation == nil {
            quotaHistoryObservation = NotificationCenter.default.addObserver(
                forName: QuotaHistoryPublication.notification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let publisher = notification.object as? QuotaViewModel,
                      let value = notification.userInfo?["publication"] as? QuotaHistoryPublication else { return }
                // 发布者始终是 MainActor 的同步 didSet；不派生 Task，保持源模式和快照提交顺序。
                // 进入隔离闭包前只提取 Sendable 值和 MainActor 引用，不跨域传递 Notification.userInfo。
                MainActor.assumeIsolated {
                    guard let self, publisher === self.viewModel else { return }
                    self.quotaHistory.submit(mode: value.mode, quotas: value.current, previous: value.previous)
                }
            }
        }

        // ViewModel 已装入上次确认的目录快照；启动只等待 CPA 管理接口确认新目录。
        guard !Task.isCancelled else { return }
        await viewModel.initialize()
        guard !Task.isCancelled else { return }

        #if canImport(Sparkle)
        UpdaterService.shared.checkForUpdatesInBackground()
        #endif
    }

    func updateStatusBar() {
        // 菜单栏的固定项来自当前账号目录，停机后沿用同样的已确认身份与额度快照。
        let items = quotaItems

        statusBarManager.updateStatusBar(
            items: items,
            colorMode: menuBarSettings.colorMode,
            quotaDisplayMode: menuBarSettings.quotaDisplayMode,
            isRunning: viewModel.canRefreshAccountQuotas || !items.isEmpty,
            showMenuBarIcon: menuBarSettings.showMenuBarIcon,
            showQuota: menuBarSettings.showQuotaInMenuBar
        )
    }

    private var quotaItems: [MenuBarQuotaDisplayItem] {
        // 所有状态栏消费者复用 ViewModel 的账号解析和配额投影，避免第二套计算漂移。
        viewModel.menuBarQuotaItems
    }
}

// MARK: - Window Chrome Configurator

struct WindowChromeConfigurator: NSViewRepresentable {
    class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyChrome(to: window)
        }

        func applyChrome(to window: NSWindow?) {
            guard let window else { return }
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 980, height: 620)
            if window.frame.width < 980 || window.frame.height < 620 {
                var frame = window.frame
                frame.size.width = max(frame.size.width, 1040)
                frame.size.height = max(frame.size.height, 680)
                window.setFrame(frame, display: true)
            }
        }
    }

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        DispatchQueue.main.async {
            view.applyChrome(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        DispatchQueue.main.async {
            nsView.applyChrome(to: nsView.window)
        }
    }
}

// MARK: - Sidebar Visual Effect View (Native macOS Translucency)

struct SidebarVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .followsWindowActiveState
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

@main
struct QuotioApp: App {
    private let userDefaultsMigration: Void = {
        guard !isRunningUnitTests else { return }
        AppIdentity.migrateLegacyUserDefaults()
    }()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Use shared bootstrap instance for viewModel
    private var bootstrap: AppBootstrap { AppBootstrap.shared }
    @State private var logsViewModel = LogsViewModel()
    // 应用持有统计模型，语言切换造成的 ContentView.id 重建和窗口重开均复用数据层。
    // 引擎惰性打开数据库，不在应用启动时主动扫描客户端历史。
    @State private var clientUsage = ClientUsageViewModel()
    @State private var callAnalytics = CallAnalyticsViewModel()
    @State private var storageMaintenance = AnalyticsMaintenanceCoordinator()
    @State private var menuBarSettingsStorage: MenuBarSettingsManager? = isRunningUnitTests ? nil : .shared
    @State private var statusBarManager = StatusBarManager.shared
    @State private var appearanceManagerStorage: AppearanceManager? = isRunningUnitTests ? nil : .shared
    @State private var languageManagerStorage: LanguageManager? = isRunningUnitTests ? nil : .shared
    @State private var showOnboarding = false
    @Environment(\.openWindow) private var openWindow

    private var viewModel: QuotaViewModel { bootstrap.viewModel }
    private var menuBarSettings: MenuBarSettingsManager { menuBarSettingsStorage! }
    private var appearanceManager: AppearanceManager { appearanceManagerStorage! }
    private var languageManager: LanguageManager { languageManagerStorage! }


    var body: some Scene {
        let _ = setupBootstrapOpenWindow()
        Window(AppIdentity.displayName, id: "main") {
            if isRunningUnitTests {
                EmptyView()
            } else {
                ContentView(clientUsage: clientUsage, callAnalytics: callAnalytics)
                    .frame(minWidth: 960, minHeight: 600)
                    .id(languageManager.currentLanguage) // Force re-render on language change
                    .environment(viewModel)
                    .environment(logsViewModel)
                    .environment(clientUsage)
                    .environment(callAnalytics)
                    .environment(storageMaintenance)
                    .environment(bootstrap.quotaHistory)
                    .environment(\.locale, languageManager.locale)
                    .background(WindowChromeConfigurator())
                    .task {
                        showOnboarding = !OperatingModeManager.shared.hasCompletedOnboarding
                    }
                    .onChange(of: viewModel.proxyManager.proxyStatus.running) {
                        bootstrap.updateStatusBar()
                    }
                    .onChange(of: viewModel.isLoadingQuotas) {
                        bootstrap.updateStatusBar()
                        // Rebuild menu when loading state changes so loader updates
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: languageManager.currentLanguage) { _, _ in
                        // Rebuild menu bar when language changes
                        bootstrap.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: appearanceManager.appearanceMode) {
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: menuBarSettings.showQuotaInMenuBar) {
                        bootstrap.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.showMenuBarIcon) {
                        bootstrap.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.selectedItems) {
                        bootstrap.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.colorMode) {
                        bootstrap.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.quotaDisplayMode) {
                        bootstrap.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: menuBarSettings.stackPairedQuotaMetrics) {
                        bootstrap.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.totalUsageMode) {
                        bootstrap.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: menuBarSettings.modelAggregationMode) {
                        bootstrap.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: viewModel.providerQuotas.count) {
                        bootstrap.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: viewModel.directAuthFiles.count) {
                        bootstrap.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .sheet(isPresented: $showOnboarding) {
                        OnboardingFlow()
                    }
            }
        }
        .defaultSize(width: 960, height: 600)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }

            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdaterService.shared.checkForUpdates()
                }
                .disabled(!UpdaterService.shared.canCheckForUpdates)
            }
            #endif
        }
    }

    private func setupBootstrapOpenWindow() -> Bool {
        // Scene 构建早于窗口内容的测试分支，必须在访问单例前退出。
        // 否则单元测试仍会初始化真实代理并读取系统钥匙串，可能停在授权弹窗而无法开始测试。
        guard !isRunningUnitTests else { return false }
        bootstrap.openWindowHandler = { [openWindow] in
            openWindow(id: "main")
        }
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private nonisolated(unsafe) var windowWillCloseObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeKeyObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeMainObserver: NSObjectProtocol?
    private nonisolated(unsafe) var appDidResignActiveObserver: NSObjectProtocol?
    private var launchTask: Task<Void, Never>?
    private enum TerminationState {
        case idle, cleaning, ready
    }
    private var terminationState = TerminationState.idle
    private var pendingForegroundReassert = false
    private weak var trackedDashboardWindow: NSWindow?
    private var lastDashboardActivationDate: Date?
    private var hasTriggeredAntiDropForCurrentActivation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnitTests else { return }

        UserDefaults.standard.register(defaults: [
            "showInDock": true,
            "totalUsageMode": TotalUsageMode.sessionOnly.rawValue,
            "modelAggregationMode": ModelAggregationMode.lowest.rawValue
        ])

        TelemetryService.shared.configureIfAllowed()

        // Apply initial dock visibility based on saved preference
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        if showInDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.bringMainWindowToFront(in: NSApp)
                }
            }
        }

        // 应用委托持有启动任务。关闭窗口不会取消初始化，退出时才撤销后续启动工作。
        launchTask = Task { @MainActor in
            await AppBootstrap.shared.initializeIfNeeded()
            guard !Task.isCancelled else { return }

            // Start background polling for CLIProxyAPI updates (every 5 minutes)
            // Uses Atom feed with ETag caching for efficiency
            AtomFeedUpdateService.shared.startPolling(
                getCurrentVersion: { CLIProxyManager.shared.currentVersion ?? CLIProxyManager.shared.installedProxyVersion }
            )
        }

        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let closingWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.handleWindowWillClose(closingWindow)
            }
        }

        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey()
            }
        }

        windowDidBecomeMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let mainWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeMain(mainWindow)
            }
        }

        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationDidResignActive()
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        _ = bringMainWindowToFront(in: sender)
        return true
    }

    private var shouldUseAccessoryPolicy: Bool {
        !UserDefaults.standard.bool(forKey: "showInDock")
    }

    private func ensureRegularPolicyForMainWindowForeground(in app: NSApplication) -> Bool {
        guard shouldUseAccessoryPolicy else { return true }

        if app.activationPolicy() == .regular {
            return true
        }

        guard app.setActivationPolicy(.regular) else {
            return false
        }

        return true
    }

    private func promoteToRegularPolicyIfNeeded() -> Bool {
        guard shouldUseAccessoryPolicy else { return true }

        if NSApp.activationPolicy() == .regular {
            return true
        }

        _ = NSApp.setActivationPolicy(.regular)
        return NSApp.activationPolicy() == .regular
    }

    private func promoteToRegularPolicyWithRetry(reason: String, remainingAttempts: Int = 3) {
        guard remainingAttempts > 0 else { return }

        if promoteToRegularPolicyIfNeeded() {
            if let window = mainWindow(in: NSApp) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.promoteToRegularPolicyWithRetry(reason: reason, remainingAttempts: remainingAttempts - 1)
        }
    }

    private func restoreAccessoryPolicyIfNeeded(in app: NSApplication) {
        guard shouldUseAccessoryPolicy else { return }

        let hasVisibleMainCapableWindow = app.windows.contains { window in
            window.canBecomeMain && window.isVisible && !window.isMiniaturized
        }

        if !hasVisibleMainCapableWindow && app.activationPolicy() != .accessory {
            app.setActivationPolicy(.accessory)
        }
    }

    private func bringMainWindowToFront(in app: NSApplication) -> Bool {
        guard ensureRegularPolicyForMainWindowForeground(in: app) else { return false }

        guard let window = mainWindow(in: app) else {
            AppBootstrap.shared.openWindowHandler?()
            app.activate(ignoringOtherApps: true)
            return true
        }

        trackedDashboardWindow = window
        pendingForegroundReassert = true

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        configureWindowChrome(window)
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])

            if let refreshedWindow = self.mainWindow(in: app) {
                self.trackedDashboardWindow = refreshedWindow
                refreshedWindow.makeKeyAndOrderFront(nil)
            }

            if !app.isActive {
                window.orderFrontRegardless()
            } else {
                self.pendingForegroundReassert = false
            }

        }

        return true
    }

    private func mainWindow(in app: NSApplication) -> NSWindow? {
        if let trackedDashboardWindow,
           app.windows.contains(where: { $0 === trackedDashboardWindow }),
           isDashboardWindowCandidate(trackedDashboardWindow) {
            return trackedDashboardWindow
        }

        let dashboardCandidates = app.windows.filter { isDashboardWindowCandidate($0) }
        return dashboardCandidates.first
    }

    private func isDashboardWindowCandidate(_ window: NSWindow) -> Bool {
        window.canBecomeMain
            && window.level == .normal
            // 独立额度历史不是控制中心；不能被主窗口防下沉逻辑扩成 960pt 或替代 Dock 唤起目标。
            && window.identifier?.rawValue != "quotio.quotaHistory"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningUnitTests else { return .terminateNow }
        switch terminationState {
        case .ready: return .terminateNow
        case .cleaning: return .terminateCancel
        case .idle: terminationState = .cleaning
        }

        launchTask?.cancel()
        AtomFeedUpdateService.shared.stopPolling()

        // AppKit 的延迟退出会同步进入嵌套事件循环。若菜单从主队列发起退出，
        // MainActor 收尾可能一直得不到执行。先返回当前退出请求，保留事件循环，
        // 并行等待两份有界清理完成后，再从主运行循环提交唯一一次退出。
        Task { @MainActor in
            async let stopTunnel: Void = TunnelManager.shared.shutdownForApplicationExit()
            await CLIProxyManager.shared.shutdownForApplicationExit()
            await stopTunnel
            terminationState = .ready
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    sender.terminate(nil)
                }
            }
        }
        return .terminateCancel
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let keyWindowIsDashboardCandidate = NSApp.keyWindow.map(isDashboardWindowCandidate) ?? false

        if keyWindowIsDashboardCandidate {
            promoteToRegularPolicyWithRetry(reason: "didBecomeActive")
            lastDashboardActivationDate = Date()
            hasTriggeredAntiDropForCurrentActivation = false
        }

        guard pendingForegroundReassert else { return }
        guard let window = mainWindow(in: NSApp) else {
            pendingForegroundReassert = false
            return
        }

        window.makeKeyAndOrderFront(nil)
        pendingForegroundReassert = false
    }

    private func configureWindowChrome(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 960, height: 600)
        if window.frame.width < 960 || window.frame.height < 600 {
            var frame = window.frame
            frame.size.width = max(frame.size.width, 960)
            frame.size.height = max(frame.size.height, 600)
            window.setFrame(frame, display: true)
        }
    }

    private func handleWindowDidBecomeMain(_ window: NSWindow?) {
        guard let window else { return }
        guard isDashboardWindowCandidate(window) else { return }

        trackedDashboardWindow = window
        configureWindowChrome(window)
    }

    private func handleApplicationDidResignActive() {
        guard !hasTriggeredAntiDropForCurrentActivation else { return }
        guard let activationDate = lastDashboardActivationDate else { return }

        let elapsedSinceActivation = Date().timeIntervalSince(activationDate)
        guard elapsedSinceActivation <= 0.5 else { return }
        guard let dashboardWindow = mainWindow(in: NSApp), dashboardWindow.isVisible else { return }

        hasTriggeredAntiDropForCurrentActivation = true

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            dashboardWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func handleWindowDidBecomeKey() {
        guard let keyWindow = NSApp.keyWindow else { return }
        guard let appMainWindow = mainWindow(in: NSApp), keyWindow === appMainWindow else { return }

        promoteToRegularPolicyWithRetry(reason: "didBecomeKey")
        guard ensureRegularPolicyForMainWindowForeground(in: NSApp) else { return }

        configureWindowChrome(keyWindow)

        if !NSApp.isActive {
            pendingForegroundReassert = true
            NSApp.activate(ignoringOtherApps: true)
            keyWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func handleWindowWillClose(_ closingWindow: NSWindow?) {
        let isClosingDashboardWindow = closingWindow.map {
            ($0 === trackedDashboardWindow) || isDashboardWindowCandidate($0)
        } ?? false

        guard isClosingDashboardWindow || closingWindow?.identifier?.rawValue == "quotio.quotaHistory" else { return }

        DispatchQueue.main.async {
            self.restoreAccessoryPolicyIfNeeded(in: NSApp)
        }
    }
    
    deinit {
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowDidBecomeMainObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct ContentView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    // 这里只注入应用持有的统计状态，侧栏或语言切换不能重新构造引擎。
    let clientUsage: ClientUsageViewModel
    let callAnalytics: CallAnalyticsViewModel
    /// 导航状态由侧栏的稳定宿主持有。离开统计页或从仪表盘跳转时，CPA 筛选与上次 Tab
    /// 都不会随子页面重建而丢失；此对象只保存展示状态，不会启动任何本地采集。
    @State private var analyticsNavigation = AnalyticsNavigationState()
    
    var body: some View {
        @Bindable var vm = viewModel
        
        NavigationSplitView {
            VStack(spacing: 0) {
                // App Header (macOS System Settings style: icon, name, version)
                SidebarHeaderView()
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                List(selection: $vm.currentPage) {
                    Section {
                        ForEach(NavigationPage.sidebarPages) { page in
                            SidebarLabel(title: page.titleKey.localized(), page: page)
                                .tag(page)
                        }
                    }
                }
                .scrollContentBackground(.hidden)

                // 侧栏只显示状态。服务操作统一由路由中心和菜单栏提供。
                ProxyStatusRow(viewModel: viewModel)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            .background(
                SidebarVisualEffectView()
                    .overlay(QuotioTheme.Colors.sidebarBackground(for: colorScheme))
                    .ignoresSafeArea()
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            Group {
                switch viewModel.currentPage {
                case .dashboard:
                    // 仪表盘及其明细共用系统导航栈，返回、标题和过渡由 macOS 管理。
                    NavigationStack { DashboardScreen() }
                case .analytics:
                    StatisticsAnalyticsScreen(clientUsage: clientUsage, callAnalytics: callAnalytics,
                        store: viewModel.usageMonitor, totalAccounts: viewModel.totalAccounts,
                        readyAccounts: viewModel.readyAccounts)
                case .quota, .providers:
                    // 旧额度路由和现有管理路由都落到融合页，保留程序化入口兼容性。
                    ProvidersScreen()
                case .agents:
                    AgentSetupScreen()
                case .agentManagement:
                    AgentManagementScreen()
                case .apiKeys:
                    APIKeysScreen()
                case .logs:
                    // 兼容既有程序化入口，并保留完整的系统返回路径。
                    // App 提供原维护目的地，Settings 只消费导航入口；环境仍沿用窗口注入的同一协调器与统计实例。
                    SettingsScreen(opensLogs: true) { StorageDataDestination() }
                case .settings:
                    SettingsScreen { StorageDataDestination() }
                case .about:
                    AboutScreen()
                }
            }
            .frame(minWidth: 660)
            .quotioPage()
        }
        .environment(analyticsNavigation)
    }
}

// MARK: - Sidebar Status Rows

/// 侧栏的服务只读状态随同一个代理管理器更新。
struct ProxyStatusRow: View {
    let viewModel: QuotaViewModel
    
    var body: some View {
        HStack {
            if viewModel.isRestartingProxy || viewModel.proxyManager.isStarting {
                SmallProgressView(size: 8)
            } else {
                Circle()
                    .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            
            if viewModel.isRestartingProxy {
                Text("runtime.restarting".localized())
                    .font(.caption)
            } else if viewModel.proxyManager.isStarting {
                Text("status.starting".localized())
                    .font(.caption)
            } else {
                Text(viewModel.proxyManager.proxyStatus.running ? "status.running".localized() : "status.stopped".localized())
                    .font(.caption)
            }
            
            Spacer()
            
            Text(":" + String(viewModel.proxyManager.port))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
