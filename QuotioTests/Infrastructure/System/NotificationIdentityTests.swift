import XCTest
import UserNotifications
@testable import QuotioPlus

/// 接收真实管理器生成的通知对象，隔离最终系统投递；覆盖不足／冷却恢复后再次提醒与旧去重键清理。
@MainActor
final class NotificationIdentityTests: XCTestCase {
    private final class Deliveries { var requests: [UNNotificationRequest] = [] }

    private func fixture(previous: Set<String> = []) throws -> (QuotaViewModel, NotificationManager, Deliveries, UserDefaults) {
        let suite = "quotio-notification-identity-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let deliveries = Deliveries()
        let notifications = NotificationManager(testDefaults: defaults, previousNotifications: previous) {
            deliveries.requests.append($0)
        }
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults), refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults), notificationManager: notifications
        )
        addTeardownBlock { @MainActor in defaults.removePersistentDomain(forName: suite) }
        return (model, notifications, deliveries, defaults)
    }

    func testQuotaRecoveryAllowsSecondAlertWithStableIDAndOriginalDisplayName() throws {
        for provider in [AIProvider.claude, .copilot, .glm, .openRouter] {
            let (model, _, deliveries, _) = try fixture()
            for percentage in [10.0, 10.0, 80.0, 10.0] {
                model.providerQuotas = [provider: ["work": ProviderQuotaData(models: [
                    ModelQuota(name: "fixture", percentage: percentage, resetTime: "")
                ])]]
                model.checkQuotaNotifications()
            }
            XCTAssertEqual(deliveries.requests.count, 2)
            XCTAssertEqual(deliveries.requests.map(\.identifier), Array(repeating: "quota_\(provider.rawValue)_work", count: 2))
            XCTAssertTrue(deliveries.requests.allSatisfy { $0.content.body.contains(provider.displayName) })
        }
    }

    func testCoolingRecoveryThroughActiveAndLegacyReadyAllowsSecondAlert() throws {
        for ready in ["active", "ready"] {
            let (model, _, deliveries, _) = try fixture()
            for status in ["cooling", "cooling", ready, "cooling"] {
                let json = ["name": "fixture.json", "provider": "claude", "email": "work@example.com", "status": status]
                model.authFiles = [try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: json))]
                model.checkAccountStatusChanges()
            }
            XCTAssertEqual(deliveries.requests.map(\.identifier), ["cooling_claude_work@example.com", "cooling_claude_work@example.com"])
            XCTAssertTrue(deliveries.requests.allSatisfy { $0.content.body.contains(AIProvider.claude.displayName) })
        }
    }

    func testRecoveryClearsLegacyDisplayKeysOnlyForMatchingAccountAndKind() throws {
        let (_, notifications, deliveries, _) = try fixture(previous: [
            "quota_Claude Code_work", "cooling_Claude Code_work", "quota_Claude Code_other"
        ])
        notifications.notifyQuotaLow(provider: "Claude Code", account: "work", remainingPercent: 10, providerID: "claude")
        notifications.notifyAccountCooling(provider: "Claude Code", account: "work", providerID: "claude")
        XCTAssertTrue(deliveries.requests.isEmpty, "已有显示名标记仍能抑制同一轮重复提醒")
        notifications.clearQuotaNotification(provider: "claude", account: "work")
        notifications.notifyQuotaLow(provider: "Claude Code", account: "work", remainingPercent: 10, providerID: "claude")
        notifications.notifyQuotaLow(provider: "Claude Code", account: "other", remainingPercent: 10, providerID: "claude")
        notifications.notifyAccountCooling(provider: "Claude Code", account: "work", providerID: "claude")
        XCTAssertEqual(deliveries.requests.map(\.identifier), ["quota_claude_work"])
        notifications.clearCoolingNotification(provider: "claude", account: "work")
        notifications.notifyAccountCooling(provider: "Claude Code", account: "work", providerID: "claude")
        XCTAssertEqual(deliveries.requests.map(\.identifier), ["quota_claude_work", "cooling_claude_work"])
    }

    func testThresholdUnknownQuotaPreferencesAndUnknownProvidersKeepExistingRules() throws {
        let (model, notifications, deliveries, defaults) = try fixture()
        model.providerQuotas = [.claude: ["unknown": ProviderQuotaData(models: [ModelQuota(name: "unknown", percentage: -1, resetTime: "")])]]
        model.checkQuotaNotifications()
        notifications.notifyQuotaLow(provider: "Claude Code", account: "work", remainingPercent: 80, providerID: "claude")
        XCTAssertTrue(deliveries.requests.isEmpty)
        defaults.set(false, forKey: "notificationsEnabled")
        notifications.notifyAccountCooling(provider: "Claude Code", account: "work", providerID: "claude")
        XCTAssertTrue(deliveries.requests.isEmpty)
        defaults.set(true, forKey: "notificationsEnabled")
        notifications.notifyAccountCooling(provider: "Fixture", account: "work")
        notifications.notifyAccountCooling(provider: "fixture", account: "work")
        XCTAssertEqual(deliveries.requests.map(\.identifier), ["cooling_Fixture_work", "cooling_fixture_work"], "未知提供商不擅自合并命名空间")
    }
}
