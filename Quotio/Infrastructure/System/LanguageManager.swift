//
//  LanguageManager.swift
//  Quotio
//
//  Modern SwiftUI localization using String Catalogs (.xcstrings)
//

import SwiftUI

// MARK: - Supported Languages

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case vietnamese = "vi"
    case chinese = "zh-Hans"
    case french = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chinese: return "简体中文"
        case .french: return "Français"
        }
    }

    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .vietnamese: return "🇻🇳"
        case .chinese: return "🇨🇳"
        case .french: return "🇫🇷"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var bundle: Bundle {
        let host = LanguageManager.resourceBundle
        if let path = host.path(forResource: rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        #if DEBUG
        Log.debug("LanguageManager: Bundle not found for \\(rawValue), falling back to main bundle")
        #endif
        return host
    }
}

// MARK: - Language Manager

@MainActor
@Observable
final class LanguageManager {

    static let shared = LanguageManager()

    nonisolated static var resourceBundle: Bundle {
        if let bundle = Bundle(identifier: AppIdentity.bundleIdentifier) {
            return bundle
        }
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".app") }) {
            return bundle
        }
        return .main
    }

    nonisolated static var staticLocale: Locale {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        let migrated = (saved == "zh") ? "zh-Hans" : saved
        return Locale(identifier: migrated)
    }

    private(set) var currentLanguage: AppLanguage {
        didSet {
            guard oldValue != currentLanguage else { return }
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }

    var locale: Locale { currentLanguage.locale }
    var bundle: Bundle { currentLanguage.bundle }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        
        // Migration: "zh" was used before String Catalogs migration, now use "zh-Hans"
        let migrated = (saved == "zh") ? "zh-Hans" : saved
        
        self.currentLanguage = AppLanguage(rawValue: migrated) ?? .english
        
        // Persist migrated value if it changed
        if saved == "zh" {
            UserDefaults.standard.set("zh-Hans", forKey: "appLanguage")
        }
    }

    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
    }

    func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: currentLanguage.bundle, comment: "")
    }
}

// MARK: - String Extension

extension String {
    @MainActor
    func localized() -> String {
        LanguageManager.shared.localized(self)
    }
    
    /// Nonisolated localization for use in computed properties on enums/structs.
    /// Reads stored preference directly without MainActor isolation.
    nonisolated func localizedStatic() -> String {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        let migrated = (saved == "zh") ? "zh-Hans" : saved
        let host = LanguageManager.resourceBundle

        if let path = host.path(forResource: migrated, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return NSLocalizedString(self, bundle: bundle, comment: "")
        }
        return NSLocalizedString(self, bundle: host, comment: "")
    }
}
