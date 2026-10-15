import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 用原共享弹窗及私有状态视图执行原生渲染和生命周期回归，不模拟按钮内部实现。
/// 仅发布内存 OAuthState，关闭后台服务并注入临时偏好；不开始授权、不打开浏览器、不提交回调。
@MainActor
final class OAuthSheetBoundaryTests: XCTestCase {
    private func model() throws -> QuotaViewModel {
        let suite = "quotio-oauth-sheet-boundary-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            startsBackgroundServices: false,
            modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults),
            refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in })
        )
    }

    private func open(provider: AIProvider, model: QuotaViewModel,
                      onDismiss: @escaping () -> Void) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(OAuthSheet(provider: provider, onDismiss: onDismiss).environment(model)))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    func testDeviceSheetRendersAndDisappearanceKeepsAnotherProvidersNewSession() async throws {
        let model = try model()
        model.oauthState = OAuthState(provider: .grok, status: .polling, userCode: "FIXTURE-DEVICE",
            authURL: "https://example.invalid/device", isDeviceFlow: true)
        var dismissals = 0
        let (host, window) = open(provider: .grok, model: model, onDismiss: { dismissals += 1 })
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).count, 5_000)

        // 另一提供商已经建立新会话，再移除旧弹窗；旧 onDisappear 不能清空新状态。
        let replacement = OAuthState(provider: .claude, status: .polling, state: "replacement-fixture")
        model.oauthState = replacement
        host.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.oauthState?.sessionID, replacement.sessionID)
        XCTAssertEqual(model.oauthState?.state, "replacement-fixture")
        XCTAssertEqual(dismissals, 0)
    }

    func testSuccessDismissTaskCannotCloseReplacementProvidersSession() async throws {
        let model = try model()
        model.oauthState = OAuthState(provider: .claude, status: .success)
        let dismissed = expectation(description: "旧成功弹窗不能关闭新授权")
        dismissed.isInverted = true
        let (host, window) = open(provider: .claude, model: model, onDismiss: { dismissed.fulfill() })
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))

        // 覆盖原 1.5 秒自动关闭等待：切换业务会话后 task(id:) 必须取消或在完成前拒绝旧结果。
        let replacement = OAuthState(provider: .grok, status: .polling, userCode: "NEW-DEVICE", isDeviceFlow: true)
        model.oauthState = replacement
        await fulfillment(of: [dismissed], timeout: 1.7)
        XCTAssertEqual(model.oauthState?.sessionID, replacement.sessionID)
        host.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.oauthState?.sessionID, replacement.sessionID)
    }
}
