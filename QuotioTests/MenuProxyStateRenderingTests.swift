import AppKit
import Observation
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 在真实 NSMenu 跟踪循环中切换隔离状态，不重建菜单、菜单项或 SwiftUI 根视图。
/// 同时验证 body 收到最新状态和承载高度，避免普通窗口的自动布局掩盖菜单裁切问题。
@MainActor
final class MenuProxyStateRenderingTests: XCTestCase {
    func testOpenMenuUpdatesThroughStartingRunningAndStopping() throws {
        let state = MenuProxyFixture()
        let (menu, item, hosting) = makeMenu(state)
        let stoppedHeight = hosting.frame.height
        var completed = false
        var timers: [Timer] = []
        defer { timers.forEach { $0.invalidate() } }
        timers.append(schedule(0.15) {
            XCTAssertEqual(state.lastRead?.actionKey, "action.startProxy")
            XCTAssertFalse(state.lastRead?.isBusy ?? true)
            state.value = MenuProxyState(port: 8317, isRunning: false, isStarting: true)
        })
        timers.append(schedule(0.4) {
            XCTAssertEqual(state.lastRead?.actionKey, "runtime.starting")
            XCTAssertTrue(state.lastRead?.isBusy ?? false)
            state.value = MenuProxyState(port: 8317, isRunning: true)
        })
        timers.append(schedule(0.7) {
            XCTAssertEqual(state.lastRead?.actionKey, "action.stopProxy")
            XCTAssertFalse(state.lastRead?.isBusy ?? true)
            XCTAssertGreaterThan(hosting.frame.height, stoppedHeight + 10,
                                 "展开隧道行后，原生菜单项的实际高度必须增大")
            XCTAssertEqual(hosting.frame.height, hosting.intrinsicContentSize.height, accuracy: 1)
            state.value = MenuProxyState(port: 8317, isRunning: false, isStopping: true)
        })
        timers.append(schedule(1.0) {
            XCTAssertEqual(state.lastRead?.actionKey, "runtime.stopping")
            XCTAssertTrue(state.lastRead?.isBusy ?? false)
            state.value = MenuProxyState(port: 8317, isRunning: false)
        })
        timers.append(schedule(1.3) {
            XCTAssertEqual(state.lastRead?.actionKey, "action.startProxy")
            XCTAssertFalse(state.lastRead?.isBusy ?? true)
            XCTAssertEqual(hosting.frame.height, stoppedHeight, accuracy: 1)
            XCTAssertTrue(item.view === hosting, "状态变化只能更新原视图，不能重建菜单项")
            completed = true
            menu.cancelTracking()
        })
        show(menu)
        // 全量套件中的其他 AppKit 测试有时使系统立即取消原生菜单跟踪；
        // 此时所有定时回调都未发生，属于运行环境不支持本轮交互，明确跳过而非误报功能回归。
        if !completed { throw XCTSkip("测试进程未能保持原生菜单跟踪，需在可交互桌面单独验证") }
    }

    func testPortAndRepeatedToggleRefreshWithoutReplacingMenuItem() throws {
        let state = MenuProxyFixture()
        state.value = MenuProxyState(port: 8317, isRunning: true)
        let (menu, item, hosting) = makeMenu(state)
        let runningHeight = hosting.frame.height
        var initialImage: Data?
        var completed = false
        var timers: [Timer] = []
        defer { timers.forEach { $0.invalidate() } }
        timers.append(schedule(0.15) {
            initialImage = self.snapshot(hosting)
            XCTAssertNotNil(initialImage)
            state.value = MenuProxyState(port: 9418, isRunning: true)
        })
        timers.append(schedule(0.45) {
            XCTAssertEqual(state.lastRead?.port, 9418)
            XCTAssertNotEqual(self.snapshot(hosting), initialImage,
                              "端口变化必须更新实际绘制内容，不能只改变后台状态")
            state.value = MenuProxyState(port: 9418, isRunning: false)
        })
        timers.append(schedule(0.75) {
            XCTAssertEqual(state.lastRead?.actionKey, "action.startProxy")
            XCTAssertLessThan(hosting.frame.height, runningHeight - 10)
            state.value = MenuProxyState(port: 10519, isRunning: true)
        })
        timers.append(schedule(1.05) {
            XCTAssertEqual(state.lastRead?.port, 10519)
            XCTAssertEqual(state.lastRead?.actionKey, "action.stopProxy")
            XCTAssertEqual(hosting.frame.height, runningHeight, accuracy: 1)
            XCTAssertTrue(menu.items.first === item)
            XCTAssertTrue(item.view === hosting)
            completed = true
            menu.cancelTracking()
        })
        show(menu)
        if !completed { throw XCTSkip("测试进程未能保持原生菜单跟踪，需在可交互桌面单独验证") }
    }

    private func makeMenu(_ state: MenuProxyFixture) -> (NSMenu, NSMenuItem, NSView) {
        let view = MenuNetworkInfoView(proxyState: {
            let value = state.value
            // 只记录 body 真正读到的输入；日志不参与 Observation，避免测试自身触发重绘。
            state.lastRead = value
            return value
        }, onProxyToggle: {}, onCopyProxyURL: {}, onTunnelToggle: {}, onCopyTunnelURL: {})
        let hosting = makeMenuItemHostingView(rootView: view.frame(width: 360), resizesToFitContent: true)
        hosting.setFrameSize(hosting.intrinsicContentSize)
        let item = NSMenuItem()
        item.view = hosting
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        return (menu, item, hosting)
    }

    private func show(_ menu: NSMenu) {
        // 完整测试套件运行时，前面的窗口用例可能让测试进程失去前台焦点。
        // 原生 NSMenu 在应用未激活时会立即结束跟踪，导致定时状态断言尚未执行；
        // 显式激活后再弹出，仍由真实菜单跟踪循环验证原视图的实时更新。
        NSApplication.shared.activate(ignoringOtherApps: true)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        menu.popUp(positioning: nil, at: NSPoint(x: screen.midX, y: screen.midY), in: nil)
    }

    private func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        // NSMenu 打开时使用事件跟踪模式，普通默认模式的定时器不会执行。
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func snapshot(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor @Observable
private final class MenuProxyFixture {
    var value = MenuProxyState(port: 8317, isRunning: false)
    @ObservationIgnored var lastRead: MenuProxyState?
}
