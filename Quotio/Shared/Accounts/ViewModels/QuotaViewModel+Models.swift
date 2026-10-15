//
//  QuotaViewModel+Models.swift
//  Quotio
//

import Foundation

/// QuotaViewModel 原有的授权选项与预热展示模型。
/// 这些声明继续嵌套在原类型下，完整名称保持为 QuotaViewModel.OAuthLaunchMode、
/// QuotaViewModel.WarmupStatus 与 QuotaViewModel.WarmupModelState；仅调整维护位置。
/// 模型不持有任务或 manager；预热缓存、调度状态及任务句柄仍由主类持有。
extension QuotaViewModel {
    /// OAuth launch mode for controlling browser behavior
    enum OAuthLaunchMode {
        /// User manually opens the link (shows "Open Link" button)
        case manual
        /// Automatically open browser when URL is available
        case autoOpen
    }

    struct WarmupStatus: Sendable {
        var isRunning: Bool = false
        var lastRun: Date?
        var nextRun: Date?
        var lastError: String?
        var progressCompleted: Int = 0
        var progressTotal: Int = 0
        var currentModel: String?
        var modelStates: [String: WarmupModelState] = [:]
    }

    enum WarmupModelState: String, Sendable {
        case pending
        case running
        case succeeded
        case failed
    }
}
