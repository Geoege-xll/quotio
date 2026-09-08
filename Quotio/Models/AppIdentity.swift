import Foundation

/// 展示名称来自构建后的 Bundle，而不是工程名或源文件中的品牌常量。
/// object(forInfoDictionaryKey:) 会优先考虑 InfoPlist.strings，支持本地化 Display Name。
nonisolated enum AppIdentity {
    static let productionBundleIdentifier = "com.app.george.quotioplus"
    // 最近使用的旧身份优先，设置和凭据继续复用原有迁移流程；不挪动统计数据库或代理文件目录。
    static let legacyBundleIdentifiers = ["app.bytrong.quotio", "dev.quotio.desktop", "proseek.io.vn.Quotio"]
    private static let userDefaultsMigrationKey = "migratedToGeorgeQuotioPlusIdentity"

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? productionBundleIdentifier }
    static var isProduction: Bool { bundleIdentifier == productionBundleIdentifier }
    static func keychainService(suffix: String) -> String { "\(bundleIdentifier).\(suffix)" }
    static func legacyKeychainServices(suffix: String) -> [String] {
        legacyBundleIdentifiers.map { "\($0).\(suffix)" } + ["com.quotio.\(suffix)"]
    }

    /// 应用启动前执行一次补缺迁移，新身份已设置的值始终优先；保留旧偏好域供恢复。
    /// 开发身份和单元测试不执行生产域迁移，避免测试／开发实例改动正式应用的设置。
    @discardableResult
    static func migrateLegacyUserDefaults(defaults: UserDefaults = .standard,
                                          currentBundleIdentifier: String = bundleIdentifier) -> Bool {
        guard currentBundleIdentifier == productionBundleIdentifier else { return false }
        var current = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
        guard current[userDefaultsMigrationKey] as? Bool != true else { return false }
        let legacy = legacyBundleIdentifiers.compactMap { defaults.persistentDomain(forName: $0) }
        current = mergingUserDefaults(current: current, legacyDomains: legacy)
        current[userDefaultsMigrationKey] = true
        defaults.setPersistentDomain(current, forName: currentBundleIdentifier)
        return true
    }

    static func mergingUserDefaults(current: [String: Any], legacyDomains: [[String: Any]]) -> [String: Any] {
        var merged = current
        // 自动检查开关是用户选择，与发行源无关。先补入当前域，再按新旧顺序处理旧域；
        // 仅保存 Sparkle 开关的早期版本也能迁移，但绝不覆盖应用已经保存的显式选择。
        if merged["autoCheckUpdates"] == nil, let enabled = current["SUEnableAutomaticChecks"] as? Bool {
            merged["autoCheckUpdates"] = enabled
        }
        for legacy in legacyDomains {
            // Sparkle 的跳过版本／检查时间与上游发行版绑定，旧 Atom 预检查同样不能跨源继承。
            for (key, value) in legacy where merged[key] == nil && !key.hasPrefix("SU") && key != "atomFeedCache_quotio" {
                merged[key] = value
            }
            if merged["autoCheckUpdates"] == nil, let enabled = legacy["SUEnableAutomaticChecks"] as? Bool {
                merged["autoCheckUpdates"] = enabled
            }
        }
        return merged
    }

    static var displayName: String { displayName(in: .main) }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var versionDescription: String { "\(displayName) v\(version) (\(build))" }

    static func displayName(in bundle: Bundle) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        // 极简工具／预览 Bundle 缺少应用字段时，仍提供有意义的名称。
        return bundle.bundleURL.deletingPathExtension().lastPathComponent
    }
}

/// 同一构建配置决定仓库链接、Atom 预检查和 Sparkle feed，避免入口各自保存不同地址。
/// 上游仓库只供维护页只读查询，不能用作自有应用安装源。
nonisolated enum AppReleaseConfiguration {
    static let repository = repositoryValue("QuotioReleaseRepository", fallback: "Geoege-xll/quotio")
    static let upstreamRepository = repositoryValue("QuotioUpstreamRepository", fallback: "nguyenphutrong/quotio")
    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
    static var releasesURL: URL { repositoryURL.appendingPathComponent("releases") }
    static var feedURL: URL { releasesURL.appendingPathComponent("latest/download/appcast.xml") }
    static var atomFeedURL: URL { URL(string: "https://github.com/\(repository)/releases.atom")! }
    static var upstreamURL: URL { URL(string: "https://github.com/\(upstreamRepository)")! }
    static var upstreamReleasesURL: URL { upstreamURL.appendingPathComponent("releases") }
    static var upstreamAPIURL: URL { URL(string: "https://api.github.com/repos/\(upstreamRepository)/releases/latest")! }

    static var supportsAutomaticUpdates: Bool {
        isValidPublicKey(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    static func isValidPublicKey(_ key: String?) -> Bool {
        guard let key, key != "HBpWFjUcNUuuZfdxhVlw2Mc87IT8tj1C68rufluZ0M4=",
              let data = Data(base64Encoded: key), data.count == 32 else { return false }
        return true
    }

    private static func repositoryValue(_ key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return fallback }
        return value
    }
}
