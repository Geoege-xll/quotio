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

    let viewModel = QuotaViewModel()
    let logsViewModel = LogsViewModel()

    private(set) var hasInitialized = false
    private(set) var needsOnboarding = false
    var openWindowHandler: (@MainActor () -> Void)?

    private let modeManager = OperatingModeManager.shared
    private let appearanceManager = AppearanceManager.shared
    private let statusBarManager = StatusBarManager.shared
    private let menuBarSettings = MenuBarSettingsManager.shared

    private init() {}

    /// Initialize core app services. Safe to call multiple times - only runs once.
    /// Called from AppDelegate.applicationDidFinishLaunching for headless launch support.
    func initializeIfNeeded() async {
        guard !hasInitialized else { return }
        hasInitialized = true

        appearanceManager.applyAppearance()

        // Check if onboarding is needed - if so, defer full initialization until after onboarding
        if !modeManager.hasCompletedOnboarding {
            needsOnboarding = true
            return
        }

        await performFullInitialization()
    }

    /// Called after onboarding completes to finish initialization
    func completeOnboarding() async {
        needsOnboarding = false
        await performFullInitialization()
    }

    private func performFullInitialization() async {
        // Scan auth files immediately (fast filesystem scan)
        // This allows menu bar to show providers before quota API calls complete
        await viewModel.loadDirectAuthFiles()

        // Setup menu bar immediately so user can open it while data loads
        statusBarManager.setViewModel(viewModel)
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

        // Load data in background (includes proxy auto-start if enabled)
        await viewModel.initialize()

        #if canImport(Sparkle)
        UpdaterService.shared.checkForUpdatesInBackground()
        #endif
    }

    func updateStatusBar() {
        // Menu bar should show quota data regardless of proxy status
        // The quota is fetched directly and doesn't need proxy
        let hasQuotaData = !viewModel.providerQuotas.isEmpty

        statusBarManager.updateStatusBar(
            items: quotaItems,
            colorMode: menuBarSettings.colorMode,
            quotaDisplayMode: menuBarSettings.quotaDisplayMode,
            isRunning: hasQuotaData,
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
    @State private var modeManagerStorage: OperatingModeManager? = isRunningUnitTests ? nil : .shared
    @State private var appearanceManagerStorage: AppearanceManager? = isRunningUnitTests ? nil : .shared
    @State private var languageManagerStorage: LanguageManager? = isRunningUnitTests ? nil : .shared
    @State private var showOnboarding = false
    @Environment(\.openWindow) private var openWindow

    private var viewModel: QuotaViewModel { bootstrap.viewModel }
    private var menuBarSettings: MenuBarSettingsManager { menuBarSettingsStorage! }
    private var modeManager: OperatingModeManager { modeManagerStorage! }
    private var appearanceManager: AppearanceManager { appearanceManagerStorage! }
    private var languageManager: LanguageManager { languageManagerStorage! }


    var body: some Scene {
        let _ = setupBootstrapOpenWindow()
        Window(AppIdentity.displayName, id: "main") {
            if isRunningUnitTests {
                EmptyView()
            } else {
                ContentView(clientUsage: clientUsage, callAnalytics: callAnalytics)
                    .id(languageManager.currentLanguage) // Force re-render on language change
                    .environment(viewModel)
                    .environment(logsViewModel)
                    .environment(clientUsage)
                    .environment(callAnalytics)
                    .environment(storageMaintenance)
                    .environment(\.locale, languageManager.locale)
                    .background(WindowChromeConfigurator())
                    .task {
                        // Initialize via bootstrap (idempotent - safe to call multiple times)
                        // This handles the case where window opens before AppDelegate finishes
                        await bootstrap.initializeIfNeeded()

                        // Show onboarding if needed
                        if bootstrap.needsOnboarding {
                            showOnboarding = true
                        }
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
                    .onChange(of: modeManager.currentMode) {
                        bootstrap.updateStatusBar()
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
                        OnboardingFlow {
                            Task {
                                await bootstrap.completeOnboarding()
                            }
                        }
                    }
            }
        }
        .defaultSize(width: 1000, height: 700)
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
    private var pendingForegroundReassert = false
    private weak var trackedDashboardWindow: NSWindow?
    private var lastDashboardActivationDate: Date?
    private var hasTriggeredAntiDropForCurrentActivation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnitTests else { return }

        // Move orphan cleanup off main thread to avoid blocking app launch
        DispatchQueue.global(qos: .utility).async {
            TunnelManager.cleanupOrphans()
        }

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

        // CRITICAL: Initialize app services immediately on launch.
        // This ensures proxy auto-start works even when launched at login
        // without opening a window (e.g., when showInDock=false).
        // The bootstrap.initializeIfNeeded() is idempotent and safe to call
        // multiple times - the window's .task will also call it but it's a no-op
        // if already initialized.
        Task { @MainActor in
            await AppBootstrap.shared.initializeIfNeeded()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop background polling
        AtomFeedUpdateService.shared.stopPolling()

        CLIProxyManager.terminateProxyOnShutdown()
        
        // Use semaphore to ensure tunnel cleanup completes before app terminates
        // with a timeout to prevent hanging termination
        let semaphore = DispatchSemaphore(value: 0)
        let cleanupTimeout: DispatchTime = .now() + .milliseconds(1500)
        
        Task { @MainActor in
            await TunnelManager.shared.stopTunnel()
            semaphore.signal()
        }
        
        let result = semaphore.wait(timeout: cleanupTimeout)
        if result == .timedOut {
            // Fallback: force kill orphan processes if stopTunnel timed out
            TunnelManager.cleanupOrphans()
            NSLog("[AppDelegate] Tunnel cleanup timed out, forced orphan cleanup")
        }
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

        guard isClosingDashboardWindow else { return }

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
    @AppStorage("loggingToFile") private var loggingToFile = true
    @State private var modeManager = OperatingModeManager.shared
    // 这里只注入应用持有的统计状态，侧栏或语言切换不能重新构造引擎。
    let clientUsage: ClientUsageViewModel
    let callAnalytics: CallAnalyticsViewModel
    
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
                        // Always visible
                        SidebarLabel(title: "nav.dashboard".localized(), page: .dashboard)
                            .tag(NavigationPage.dashboard)

                        // 客户端账本不依赖CPA运行，监控模式也能查看本地Token用量。
                        SidebarLabel(title: "nav.usageStatistics".localized(), page: .usageStatistics)
                            .tag(NavigationPage.usageStatistics)
                        SidebarLabel(title: "nav.callAnalytics".localized(), page: .callAnalytics)
                            .tag(NavigationPage.callAnalytics)

                        SidebarLabel(title: "nav.quota".localized(), page: .quota)
                            .tag(NavigationPage.quota)

                        SidebarLabel(
                            title: modeManager.isMonitorMode ? "nav.accounts".localized() : "nav.providers".localized(),
                            page: .providers
                        )
                        .tag(NavigationPage.providers)

                        if modeManager.isLocalProxyMode {
                            SidebarLabel(title: "nav.agents".localized(), page: .agents)
                                .tag(NavigationPage.agents)

                            SidebarLabel(title: "nav.apiKeys".localized(), page: .apiKeys)
                                .tag(NavigationPage.apiKeys)

                            // 低频诊断入口集中到设置，避免与日常服务管理混排。
                        }

                        SidebarLabel(title: "nav.settings".localized(), page: .settings)
                            .tag(NavigationPage.settings)

                        SidebarLabel(title: "nav.about".localized(), page: .about)
                            .tag(NavigationPage.about)
                    }
                }
                .scrollContentBackground(.hidden)

                // Control section at bottom - current mode badge + status
                VStack(spacing: 6) {
                    CurrentModeBadge()

                    // Status row - different per mode
                    Group {
                        if modeManager.isLocalProxyMode {
                            ProxyStatusRow(viewModel: viewModel)
                        } else {
                            QuotaRefreshStatusRow(viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(
                SidebarVisualEffectView()
                    .overlay(QuotioTheme.Colors.sidebarBackground(for: colorScheme))
                    .ignoresSafeArea()
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .toolbar {
                ToolbarItem {
                    if modeManager.isLocalProxyMode {
                        // Local proxy mode: proxy controls
                        if viewModel.proxyManager.isStarting {
                            SmallProgressView()
                        } else {
                            Button {
                                Task { await viewModel.toggleProxy() }
                            } label: {
                                Image(systemName: viewModel.proxyManager.proxyStatus.running ? "stop.fill" : "play.fill")
                            }
                            .help(viewModel.proxyManager.proxyStatus.running ? "action.stopProxy".localized() : "action.startProxy".localized())
                        }
                    } else {
                        Button {
                            Task { await viewModel.manualRefresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("action.refreshQuota".localized())
                        .disabled(viewModel.isLoadingQuotas)
                    }
                }
            }
        } detail: {
            Group {
                switch viewModel.currentPage {
                case .dashboard:
                    // 仪表盘及其明细共用系统导航栈，返回、标题和过渡由 macOS 管理。
                    NavigationStack { DashboardScreen() }
                case .usageStatistics:
                    UsageStatisticsScreen(clientUsage: clientUsage)
                case .callAnalytics:
                    CallAnalyticsScreen(viewModel: callAnalytics)
                case .quota:
                    QuotaScreen()
                case .providers:
                    ProvidersScreen()
                case .agents:
                    AgentSetupScreen()
                case .apiKeys:
                    APIKeysScreen()
                case .logs:
                    // 兼容既有程序化入口，并保留完整的系统返回路径。
                    SettingsScreen(opensLogs: true)
                case .settings:
                    SettingsScreen()
                case .about:
                    AboutScreen()
                }
            }
            .quotioPage()
        }
    }
}

// MARK: - Sidebar Status Rows

/// Proxy status row for Local Proxy Mode
struct ProxyStatusRow: View {
    let viewModel: QuotaViewModel
    
    var body: some View {
        HStack {
            if viewModel.proxyManager.isStarting {
                SmallProgressView(size: 8)
            } else {
                Circle()
                    .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            
            if viewModel.proxyManager.isStarting {
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

/// Quota refresh status row for Quota-Only Mode
struct QuotaRefreshStatusRow: View {
    let viewModel: QuotaViewModel
    
    var body: some View {
        HStack {
            if viewModel.isLoadingQuotas {
                SmallProgressView(size: 8)
                Text("status.refreshing".localized())
                    .font(.caption)
            } else {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                if let lastRefresh = viewModel.lastQuotaRefreshTime {
                    Text("status.updatedAgo \(lastRefresh, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("status.notRefreshed".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
    }
}
