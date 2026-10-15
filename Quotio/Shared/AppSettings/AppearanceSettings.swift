//
//  AppearanceSettings.swift
//  Quotio
//

import Foundation
import SwiftUI

// 外观枚举与其唯一管理器放在同一文件，明确它们共同维护应用外观这一项共享偏好。
// AppearanceManager.shared、私有初始化和 @MainActor / @Observable 归属保持不变；
// appearanceMode 的持久化键、didSet 写入顺序及 NSApp 外观应用时机均沿用原实现。

// MARK: - Appearance Mode

/// Appearance mode for the app (light/dark/system)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Appearance Settings Manager

/// Manager for appearance settings with persistence
@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager()
    
    private let defaults = UserDefaults.standard
    private let appearanceModeKey = "appearanceMode"
    
    /// Current appearance mode
    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: appearanceModeKey)
            applyAppearance()
        }
    }
    
    private init() {
        let saved = defaults.string(forKey: appearanceModeKey) ?? AppearanceMode.system.rawValue
        self.appearanceMode = AppearanceMode(rawValue: saved) ?? .system
    }
    
    /// Apply the current appearance mode to the app
    func applyAppearance() {
        NSApp.appearance = appearanceMode.appKitAppearance
    }
}

