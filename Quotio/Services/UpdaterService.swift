//
//  UpdaterService.swift
//  Quotio
//
//  Auto-update service using Sparkle framework
//

import AppKit
import Foundation
import Sparkle

// MARK: - Update Channel

enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case beta
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .stable: return "settings.updateChannel.stable".localizedStatic()
        case .beta: return "settings.updateChannel.beta".localizedStatic()
        }
    }
    
    var icon: String {
        switch self {
        case .stable: return "checkmark.shield"
        case .beta: return "flask.fill"
        }
    }
}

// MARK: - UpdaterService

/// Manages application updates using Sparkle framework
@MainActor
@Observable
final class UpdaterService: NSObject {
    
    // MARK: - Properties
    
    private var updaterController: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { updaterController?.updater }
    
    private(set) var isInitialized = false
    
    /// 应用偏好是自动检查的统一来源，未初始化 Sparkle 时也能读取和保存用户选择。
    var automaticallyChecksForUpdates: Bool {
        get { Self.automaticCheckPreference() }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates")
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    /// 用 object 区分“从未设置”和显式 false，只有首次使用才采用默认开启。
    nonisolated static func automaticCheckPreference(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }
    
    /// Last time updates were checked
    // 只在检查完成时发布一次；不依赖每秒变化的相对时间迫使视图重新读取 Sparkle 属性。
    private(set) var lastUpdateCheckDate: Date?

    var supportsAutomaticUpdates: Bool { AppReleaseConfiguration.supportsAutomaticUpdates }
    var checkButtonTitleKey: String { supportsAutomaticUpdates ? "settings.checkNow" : "updates.own.viewReleases" }
    
    /// Whether an update check is currently in progress
    private(set) var isCheckingForUpdates = false
    
    /// Whether the updater can check for updates
    var canCheckForUpdates: Bool {
        if !supportsAutomaticUpdates { return true }
        guard isInitialized else { return false }
        return updater?.canCheckForUpdates ?? false
    }
    
    /// Current app icon (observable for SwiftUI views)
    private(set) var currentAppIcon: NSImage?
    
    var updateChannel: UpdateChannel {
        get {
            let rawValue = UserDefaults.standard.string(forKey: "updateChannel") ?? "stable"
            return UpdateChannel(rawValue: rawValue) ?? .stable
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "updateChannel")
            updater?.resetUpdateCycle()
            updateAppIcon()
        }
    }
    
    // MARK: - Singleton
    
    static let shared = UpdaterService()
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        updateAppIcon()
    }
    
    /// Initialize Sparkle updater on-demand (memory optimization)
    func initializeIfNeeded() {
        // 尚未配置自有公钥的开发构建只提供发布页，不使用上游公钥初始化 Sparkle。
        guard !isInitialized, supportsAutomaticUpdates else { return }
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // 必须先同步迁移后的开关再启动调度，避免新 Bundle 的默认值覆盖用户关闭自动检查的选择。
        updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        updaterController?.startUpdater()
        isInitialized = true
        lastUpdateCheckDate = updater?.lastUpdateCheckDate
    }
    
    // MARK: - Public Methods
    
    /// Manually check for updates
    func checkForUpdates() {
        guard supportsAutomaticUpdates else {
            NSWorkspace.shared.open(AppReleaseConfiguration.releasesURL)
            return
        }
        initializeIfNeeded()
        guard canCheckForUpdates else { return }
        isCheckingForUpdates = true
        updater?.checkForUpdates()
    }
    
    /// Check for updates in background (no UI if no update)
    func checkForUpdatesInBackground() {
        // 显式后台检查会绕过 Sparkle 的自动调度开关，因此启动入口也必须遵守应用偏好。
        guard automaticallyChecksForUpdates else { return }
        initializeIfNeeded()
        updater?.checkForUpdatesInBackground()
    }
    
    // MARK: - Icon Management
    
    func updateAppIcon() {
        let channel = updateChannel
        let iconName = channel == .beta ? "AppIconBetaImage" : "AppIconImage"
        
        guard let iconImage = NSImage(named: iconName) else {
            NSApplication.shared.applicationIconImage = nil
            currentAppIcon = NSApplication.shared.applicationIconImage
                ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            return
        }
        
        let displaySize = NSSize(width: 256, height: 256)
        let roundedIcon = NSImage(size: displaySize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)
            path.addClip()
            iconImage.draw(in: rect)
            return true
        }
        
        self.currentAppIcon = roundedIcon

        if channel == .beta {
            NSApplication.shared.applicationIconImage = roundedIcon
        } else {
            // Restore the bundle icon so macOS can apply the system icon appearance.
            NSApplication.shared.applicationIconImage = nil
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterService: SPUUpdaterDelegate {
    
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        AppReleaseConfiguration.feedURL.absoluteString
    }
    
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channel = UserDefaults.standard.string(forKey: "updateChannel") ?? "stable"
        return channel == "beta" ? Set(["beta"]) : Set()
    }
    
    // 实现 Sparkle 的三参数可选委托方法；检查成功、关闭或跳过更新时都会结束检查状态。
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Task { @MainActor in
            self.isCheckingForUpdates = false
            self.lastUpdateCheckDate = self.updater?.lastUpdateCheckDate
        }
    }
    
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            self.isCheckingForUpdates = false
            self.lastUpdateCheckDate = self.updater?.lastUpdateCheckDate
            Log.update("Update check aborted: \\(error.localizedDescription)")
        }
    }
}
