//
//  MonitorAccountSource.swift
//  Quotio
//

import Foundation

/// 原监控账号来源枚举；保留原始值、来源优先级与本地化键，已有账号编码及发现取舍规则不变。
nonisolated enum MonitorAccountSource: String, Codable, Sendable, CaseIterable {
    case quotioKeychain
    case nativeCredential
    case legacyCLIProxy
    case localIDE
    case apiKey

    var priority: Int {
        switch self {
        case .quotioKeychain: 300
        case .nativeCredential, .localIDE, .apiKey: 200
        case .legacyCLIProxy: 100
        }
    }

    var displayName: String {
        localizationKey.localizedStatic()
    }

    var localizationKey: String {
        switch self {
        case .quotioKeychain: "monitor.source.quotio"
        case .nativeCredential: "monitor.source.localLogin"
        case .legacyCLIProxy: "monitor.source.cliProxyFile"
        case .localIDE: "monitor.source.localIDE"
        case .apiKey: "monitor.source.apiKey"
        }
    }
}

