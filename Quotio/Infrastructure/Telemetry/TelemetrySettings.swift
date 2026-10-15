//
//  TelemetrySettings.swift
//  Quotio
//
//  Stores the user's anonymous usage sharing preference.
//

import Foundation

@MainActor
@Observable
final class TelemetrySettings {
    static let shared = TelemetrySettings()

    private enum Keys {
        static let shareAnonymousUsage = "shareAnonymousUsage"
        static let anonymousInstallID = "anonymousInstallID"
        static let hasSentFirstOptInLaunch = "telemetry.hasSentFirstOptInLaunch"
    }

    var shareAnonymousUsage: Bool {
        didSet {
            UserDefaults.standard.set(shareAnonymousUsage, forKey: Keys.shareAnonymousUsage)
            TelemetryService.shared.applySharingPreference()
        }
    }

    private init() {
        shareAnonymousUsage = UserDefaults.standard.bool(forKey: Keys.shareAnonymousUsage)
    }

    var anonymousInstallID: String? {
        UserDefaults.standard.string(forKey: Keys.anonymousInstallID)
    }

    var hasSentFirstOptInLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasSentFirstOptInLaunch) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasSentFirstOptInLaunch) }
    }

    func ensureAnonymousInstallID() -> String {
        if let existing = anonymousInstallID, !existing.isEmpty {
            return existing
        }

        let newID = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newID, forKey: Keys.anonymousInstallID)
        return newID
    }

    func resetAnonymousInstallID() {
        UserDefaults.standard.removeObject(forKey: Keys.anonymousInstallID)
        UserDefaults.standard.removeObject(forKey: Keys.hasSentFirstOptInLaunch)
    }
}
