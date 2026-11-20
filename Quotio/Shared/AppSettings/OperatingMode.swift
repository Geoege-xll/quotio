//
//  OperatingMode.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  本地代理运行偏好与旧额度历史的模式标记。
//

import Foundation
import Observation

/// 历史记录仍会解码 monitor 和 local；应用启动统一使用 local。
enum OperatingMode: String, Codable, Sendable {
    case monitor = "monitor"
    case localProxy = "local"
}

/// 维护当前运行方式和首次引导完成标志；迁移只处理偏好值。
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
    
    /// 缺省、新值、旧监控和旧远程偏好统一归到本地代理。引导标志独立读取，
    /// 避免旧用户被重新要求引导；旧偏好键与凭据、历史文件均保留原值。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        currentMode = .localProxy
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        let storedMode = defaults.string(forKey: "operatingMode")
        if storedMode != OperatingMode.localProxy.rawValue {
            defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        }
        if storedMode == nil, defaults.string(forKey: "appMode") != nil {
            defaults.set(true, forKey: "migratedToOperatingMode")
        }
    }

    #if DEBUG
    /// 隔离回归可模拟一个新的模式世代，用于验证迟到响应的保护。
    /// 正式共享实例和标准偏好域都不能由测试入口切换。
    func setMode(_ mode: OperatingMode) {
        guard defaults !== UserDefaults.standard else { return }
        if currentMode != mode { revision += 1 }
        currentMode = mode
    }
    #endif

    /// 保持现有引导调用签名兼容，完成标志独立于旧模式参数持久化。
    func completeOnboarding(mode _: OperatingMode = .localProxy) {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }
}
