//
//  NotificationManager.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import UserNotifications

/// Notification types for tracking which notifications have been sent
enum NotificationType: String {
    case quotaLow = "quotaLow"
    case accountCooling = "accountCooling"
    case proxyCrashed = "proxyCrashed"
    case proxyStarted = "proxyStarted"
    case proxyStopped = "proxyStopped"
    case upgradeAvailable = "upgradeAvailable"
    case upgradeSuccess = "upgradeSuccess"
    case upgradeFailed = "upgradeFailed"
    case rollback = "rollback"
}

/// Manages macOS notifications for quota alerts, cooling status, and proxy crashes
@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    
    private(set) var isAuthorized = false
    private var sentNotifications: Set<String> = []
    /// 正常实例仍使用标准偏好与系统通知；测试实例只注入独立偏好和内存接收器，不改变共享实例。
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notificationSink: ((UNNotificationRequest) -> Void)?
    
    // Settings stored in UserDefaults
    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: "notificationsEnabled") }
        set { defaults.set(newValue, forKey: "notificationsEnabled") }
    }
    
    var quotaAlertThreshold: Double {
        get { 
            let value = defaults.double(forKey: "quotaAlertThreshold")
            return value > 0 ? value : 20.0 // Default 20%
        }
        set { defaults.set(newValue, forKey: "quotaAlertThreshold") }
    }
    
    var notifyOnQuotaLow: Bool {
        get { defaults.object(forKey: "notifyOnQuotaLow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifyOnQuotaLow") }
    }
    
    var notifyOnCooling: Bool {
        get { defaults.object(forKey: "notifyOnCooling") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifyOnCooling") }
    }
    
    var notifyOnProxyCrash: Bool {
        get { defaults.object(forKey: "notifyOnProxyCrash") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifyOnProxyCrash") }
    }
    
    var notifyOnUpgradeAvailable: Bool {
        get { defaults.object(forKey: "notifyOnUpgradeAvailable") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifyOnUpgradeAvailable") }
    }

    private init(defaults: UserDefaults = .standard, requestAuthorizationOnInit: Bool = true,
                 notificationSink: ((UNNotificationRequest) -> Void)? = nil) {
        self.defaults = defaults
        self.notificationSink = notificationSink
        // Enable notifications by default on first launch
        if defaults.object(forKey: "notificationsEnabled") == nil {
            defaults.set(true, forKey: "notificationsEnabled")
        }
        
        if requestAuthorizationOnInit {
            Task { await requestAuthorization() }
        }
    }

    #if DEBUG
    /// 仅 Debug 构造离线通知夹具：原管理器仍持有去重集合，旧标记样本可验证恢复兼容清理。
    /// 不请求系统授权、不向系统投递，偏好键与正常实例完全一致，isAuthorized 的 setter 仍保持私有。
    convenience init(testDefaults: UserDefaults, previousNotifications: Set<String> = [],
                     notificationSink: @escaping (UNNotificationRequest) -> Void) {
        self.init(defaults: testDefaults, requestAuthorizationOnInit: false, notificationSink: notificationSink)
        isAuthorized = true
        sentNotifications = previousNotifications
    }
    #endif

    /// 测试替换最终投递，不替换阈值、去重或恢复规则；正常共享实例仍调用同一个系统通知中心。
    private func deliver(_ request: UNNotificationRequest) {
        if let notificationSink { notificationSink(request) }
        else { UNUserNotificationCenter.current().add(request) }
    }
    
    // MARK: - Authorization
    
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
        } catch {
            isAuthorized = false
        }
    }
    
    nonisolated func checkAuthorizationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
        await MainActor.run {
            self.isAuthorized = authorized
        }
    }
    
    // MARK: - Notification Sending
    
    /// Send notification for low quota warning
    /// - Parameters:
    ///   - provider: The AI provider name
    ///   - account: The account email/identifier
    ///   - remainingPercent: Remaining quota percentage (0-100)
    func notifyQuotaLow(provider: String, account: String, remainingPercent: Double, providerID: String? = nil) {
        guard notificationsEnabled && notifyOnQuotaLow && isAuthorized else { return }
        guard remainingPercent <= quotaAlertThreshold else { return }
        
        // 原平台名称继续展示在文案中；去重使用稳定身份，并兼容本进程已有的旧显示名标记。
        let keys = accountNotificationKeys(kind: "quota", provider: provider, account: account, providerID: providerID)
        guard sentNotifications.isDisjoint(with: keys.compatible) else { return }
        let notificationId = keys.canonical
        sentNotifications.insert(notificationId)
        
        let title = LanguageManager.shared.localized("notification.quotaLow.title")
        let bodyFormat = LanguageManager.shared.localized("notification.quotaLow.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, provider, account, Int(remainingPercent))
        content.sound = .default
        content.categoryIdentifier = NotificationType.quotaLow.rawValue
        
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        deliver(request)
    }
    
    /// Send notification when an account enters cooling status
    /// - Parameters:
    ///   - provider: The AI provider name
    ///   - account: The account email/identifier
    func notifyAccountCooling(provider: String, account: String, providerID: String? = nil) {
        guard notificationsEnabled && notifyOnCooling && isAuthorized else { return }
        
        // 冷却与额度提醒共用同一身份规则，但保留各自的通知类别和独立去重空间。
        let keys = accountNotificationKeys(kind: "cooling", provider: provider, account: account, providerID: providerID)
        guard sentNotifications.isDisjoint(with: keys.compatible) else { return }
        let notificationId = keys.canonical
        sentNotifications.insert(notificationId)
        
        let title = LanguageManager.shared.localized("notification.cooling.title")
        let bodyFormat = LanguageManager.shared.localized("notification.cooling.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, provider, account)
        content.sound = .default
        content.categoryIdentifier = NotificationType.accountCooling.rawValue
        
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil
        )
        
        deliver(request)
    }
    
    /// Send notification when proxy process crashes
    /// - Parameter exitCode: The exit code of the crashed process
    func notifyProxyCrashed(exitCode: Int32) {
        guard notificationsEnabled && notifyOnProxyCrash && isAuthorized else { return }
        
        let title = LanguageManager.shared.localized("notification.proxyCrash.title")
        let bodyFormat = LanguageManager.shared.localized("notification.proxyCrash.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, exitCode)
        content.sound = .defaultCritical
        content.categoryIdentifier = NotificationType.proxyCrashed.rawValue
        
        let request = UNNotificationRequest(
            identifier: "proxy_crash_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        deliver(request)
    }
    
    /// Send notification when proxy starts successfully
    func notifyProxyStarted() {
        guard notificationsEnabled && isAuthorized else { return }
        
        let title = LanguageManager.shared.localized("notification.proxyStarted.title")
        let body = LanguageManager.shared.localized("notification.proxyStarted.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "proxy_started",
            content: content,
            trigger: nil
        )
        
        deliver(request)
    }
    
    /// 仅已知提供商按 rawValue 归一；兼容旧调用传来的显示名称，未知提供商仍保留原文避免误合并。
    /// 账号部分不裁剪、不改大小写，继续遵守原账号去重语义。恢复时同时删除当前键与原显示名键。
    private func accountNotificationKeys(kind: String, provider: String, account: String,
                                         providerID: String? = nil) -> (canonical: String, compatible: Set<String>) {
        let identity = providerID ?? provider
        let known = AIProvider.allCases.first {
            $0.rawValue.caseInsensitiveCompare(identity) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(identity) == .orderedSame
        }
        let canonicalProvider = known?.rawValue ?? identity
        let aliases = Set([canonicalProvider, provider, known?.rawValue, known?.displayName].compactMap { $0 })
        let compatible = Set(aliases.map { "\(kind)_\($0)_\(account)" })
        return ("\(kind)_\(canonicalProvider)_\(account)", compatible)
    }

    // MARK: - State Management
    
    /// Clear notification tracking for an account (call when quota is restored)
    func clearQuotaNotification(provider: String, account: String) {
        sentNotifications.subtract(accountNotificationKeys(kind: "quota", provider: provider, account: account).compatible)
    }
    
    /// Clear cooling notification tracking for an account (call when account is ready again)
    func clearCoolingNotification(provider: String, account: String) {
        sentNotifications.subtract(accountNotificationKeys(kind: "cooling", provider: provider, account: account).compatible)
    }
    
    /// Clear all notification tracking (call on app restart or when appropriate)
    func clearAllNotificationTracking() {
        sentNotifications.removeAll()
    }
    
    /// Remove all pending notifications
    func removeAllPendingNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    /// Remove all delivered notifications
    func removeAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    // MARK: - Upgrade Notifications
    
    /// Send notification when a new proxy version is available
    /// - Parameter version: The new version available for upgrade
    func notifyUpgradeAvailable(version: String) {
        guard notificationsEnabled && notifyOnUpgradeAvailable && isAuthorized else { return }
        
        // Prevent duplicate notifications for same version
        let notificationId = "upgrade_available_\(version)"
        guard !sentNotifications.contains(notificationId) else { return }
        sentNotifications.insert(notificationId)
        
        let title = LanguageManager.shared.localized("notification.upgradeAvailable.title")
        let bodyFormat = LanguageManager.shared.localized("notification.upgradeAvailable.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, version)
        content.sound = .default
        content.categoryIdentifier = NotificationType.upgradeAvailable.rawValue
        
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil
        )
        
        deliver(request)
    }
    
    /// Clear upgrade available notification tracking (call when user upgrades or dismisses)
    func clearUpgradeAvailableNotification(version: String) {
        sentNotifications.remove("upgrade_available_\(version)")
    }
    
    /// Suppress upgrade notification for a version (call after successful upgrade to prevent duplicate notifications)
    func suppressUpgradeNotification(version: String) {
        sentNotifications.insert("upgrade_available_\(version)")
    }
    
    /// Send notification when proxy upgrade succeeds
    /// - Parameter version: The new version that was installed
    func notifyUpgradeSuccess(version: String) {
        guard notificationsEnabled && isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "notification.upgrade.success.title".localized()
        content.body = String(format: "notification.upgrade.success.body".localized(), version)
        content.sound = .default
        content.categoryIdentifier = NotificationType.upgradeSuccess.rawValue
        
        let request = UNNotificationRequest(
            identifier: "upgrade_success_\(version)",
            content: content,
            trigger: nil
        )
        
        deliver(request)
    }
    
    /// Send notification when proxy upgrade fails
    /// - Parameters:
    ///   - version: The version that failed to install
    ///   - reason: The reason for failure
    func notifyUpgradeFailed(version: String, reason: String) {
        guard notificationsEnabled && isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "notification.upgrade.failed.title".localized()
        content.body = String(format: "notification.upgrade.failed.body".localized(), version, reason)
        content.sound = .defaultCritical
        content.categoryIdentifier = NotificationType.upgradeFailed.rawValue
        
        let request = UNNotificationRequest(
            identifier: "upgrade_failed_\(version)",
            content: content,
            trigger: nil
        )
        
        deliver(request)
    }
    
    /// Send notification when rollback occurs
    /// - Parameter toVersion: The version that was restored
    func notifyRollback(toVersion: String) {
        guard notificationsEnabled && isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "notification.rollback.title".localized()
        content.body = String(format: "notification.rollback.body".localized(), toVersion)
        content.sound = .default
        content.categoryIdentifier = NotificationType.rollback.rawValue
        
        let request = UNNotificationRequest(
            identifier: "rollback_\(toVersion)",
            content: content,
            trigger: nil
        )
        
        deliver(request)
    }
}
