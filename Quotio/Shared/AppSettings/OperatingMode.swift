//
//  OperatingMode.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Unified operating mode: Monitor (Quota-Only) or Local Proxy
//  Replaces the deprecated AppMode system
//

import Foundation
import SwiftUI

// 共享运行偏好与原 manager 成组维护，供账号、设置、菜单栏和启动流程使用。
// 保留原枚举、单例、全部 private(set)、模式 revision、偏好键和历史迁移顺序；不复制状态或任务。
// 页面可见性由 App 导航扩展读取同一个模式，不在此持有页面枚举或导航状态。

// MARK: - Operating Mode

/// Unified operating mode for Quotio
/// Replaces AppMode with a single, user-friendly enum
enum OperatingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case monitor = "monitor"        // Quota tracking only (no proxy)
    case localProxy = "local"       // Run local proxy server
    
    var id: String { rawValue }
    
    // MARK: - Display Properties
    
    var displayName: String {
        switch self {
        case .monitor: return "onboarding.mode.monitor.title".localizedStatic()
        case .localProxy: return "onboarding.mode.localProxy.title".localizedStatic()
        }
    }
    
    var description: String {
        switch self {
        case .monitor: return "onboarding.mode.monitor.description".localizedStatic()
        case .localProxy: return "onboarding.mode.localProxy.description".localizedStatic()
        }
    }
    
    var icon: String {
        switch self {
        case .monitor: return "chart.bar.fill"
        case .localProxy: return "server.rack"
        }
    }
    
    var color: Color {
        switch self {
        case .monitor: return .green
        case .localProxy: return .blue
        }
    }
    
    var badge: String? {
        switch self {
        case .monitor: return "onboarding.mode.badge.default".localizedStatic()
        case .localProxy: return nil
        }
    }
    
    // MARK: - Feature Lists
    
    var features: [String] {
        switch self {
        case .monitor:
            return [
                "onboarding.mode.monitor.feature1".localizedStatic(),
                "onboarding.mode.monitor.feature2".localizedStatic(),
                "onboarding.mode.monitor.feature3".localizedStatic()
            ]
        case .localProxy:
            return [
                "onboarding.mode.localProxy.feature1".localizedStatic(),
                "onboarding.mode.localProxy.feature2".localizedStatic(),
                "onboarding.mode.localProxy.feature3".localizedStatic()
            ]
        }
    }
    
    
    // MARK: - Migration Helpers
    
    /// Create from legacy AppMode + connection mode values.
    static func fromLegacy(appModeRaw: String?, connectionModeRaw: String?) -> OperatingMode {
        guard let appModeRaw = appModeRaw else { return .monitor }
        
        switch appModeRaw {
        case "quotaOnly":
            return .monitor
        case "full":
            // Do not start a local proxy automatically for users of the removed remote mode.
            return connectionModeRaw == "remote" ? .monitor : .localProxy
        default:
            return .monitor
        }
    }
}

// MARK: - Operating Mode Manager

/// Singleton manager for operating mode state
@MainActor
@Observable
final class OperatingModeManager {
    static let shared = OperatingModeManager()
    
    private let defaults: UserDefaults

    // MARK: - Observable State
    
    /// Current operating mode
    private(set) var currentMode: OperatingMode
    /// 即使先离开再回到同一模式，旧请求也必须失效，不能只比较模式枚举值。
    private(set) var revision: UInt64 = 0
    
    /// Whether onboarding has been completed
    private(set) var hasCompletedOnboarding: Bool
    
    // MARK: - Computed Properties
    
    var isMonitorMode: Bool { currentMode == .monitor }
    var isLocalProxyMode: Bool { currentMode == .localProxy }
    
    
    // MARK: - Initialization
    
    /// 正常使用 standard；离线同步验证注入独立偏好域，避免改动用户运行模式。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Check for migration from legacy modes first
        let needsMigration = Self.checkNeedsMigration(defaults: defaults)
        
        if needsMigration {
            let migratedMode = Self.performMigration(defaults: defaults)
            self.currentMode = migratedMode
            self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        } else if let stored = defaults.string(forKey: "operatingMode") {
            let mode = OperatingMode(rawValue: stored) ?? .monitor
            self.currentMode = mode
            self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
            if mode.rawValue != stored {
                defaults.set(mode.rawValue, forKey: "operatingMode")
            }
        } else {
            // New installation - default to monitor mode
            self.currentMode = .monitor
            self.hasCompletedOnboarding = false
        }
    }
    
    // MARK: - Mode Management
    
    /// Set current mode and persist
    func setMode(_ mode: OperatingMode) {
        if currentMode != mode { revision += 1 }
        currentMode = mode
        defaults.set(mode.rawValue, forKey: "operatingMode")
    }
    
    /// Complete onboarding with selected mode
    func completeOnboarding(mode: OperatingMode) {
        setMode(mode)
        hasCompletedOnboarding = true
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }
    
    /// Switch mode with cleanup actions
    func switchMode(to mode: OperatingMode, stopProxyIfNeeded: @escaping () -> Void) {
        if currentMode == .localProxy && mode != .localProxy {
            stopProxyIfNeeded()
        }
        setMode(mode)
    }
    
    /// Reset onboarding (for debugging/testing)
    func resetOnboarding() {
        hasCompletedOnboarding = false
        defaults.set(false, forKey: "hasCompletedOnboarding")
    }
    
    // MARK: - Migration from Legacy
    
    private static func checkNeedsMigration(defaults: UserDefaults) -> Bool {
        // Check if old keys exist but new key doesn't
        let hasOldAppMode = defaults.string(forKey: "appMode") != nil
        let hasNewOperatingMode = defaults.string(forKey: "operatingMode") != nil
        return hasOldAppMode && !hasNewOperatingMode
    }
    
    private static func performMigration(defaults: UserDefaults) -> OperatingMode {
        // Read legacy values
        let legacyAppModeRaw = defaults.string(forKey: "appMode")
        
        let legacyConnectionModeRaw = defaults.string(forKey: "connectionMode")
        
        // Convert to new mode
        let newMode = OperatingMode.fromLegacy(
            appModeRaw: legacyAppModeRaw,
            connectionModeRaw: legacyConnectionModeRaw
        )
        
        // Persist new mode
        defaults.set(newMode.rawValue, forKey: "operatingMode")
        
        // Mark migration complete (keep old keys for safety)
        defaults.set(true, forKey: "migratedToOperatingMode")
        
        Log.debug("Migrated from AppMode.\(legacyAppModeRaw ?? "nil") + ConnectionMode.\(legacyConnectionModeRaw ?? "nil") -> OperatingMode.\(newMode.rawValue)")
        
        return newMode
    }
}
