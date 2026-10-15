import AppKit
import XCTest
@testable import QuotioPlus

@MainActor
final class UpstreamRegressionTests: XCTestCase {
    /// 筛选后菜单项的对象身份和次序不变，标题/分隔线只在全部提供商时出现。
    func testProviderSelectionHidesItemsWithoutRebuildingMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "header", action: nil, keyEquivalent: "")
        let claude = NSMenuItem(title: "claude", action: nil, keyEquivalent: "")
        let codex = NSMenuItem(title: "codex", action: nil, keyEquivalent: "")
        let action = NSMenuItem(title: "action", action: nil, keyEquivalent: "")
        var selections: [AIProvider?] = []
        let filter = StatusBarProviderFilterController(selectedProvider: nil) { selections.append($0) }
        filter.register(header, scope: .allProvidersOnly)
        filter.register(claude, scope: .provider(.claude))
        filter.register(codex, scope: .provider(.codex))
        [header, claude, codex, action].forEach(menu.addItem)
        filter.activate(in: menu)
        let identities = menu.items.map(ObjectIdentifier.init)
        filter.select(.codex)
        XCTAssertTrue(header.isHidden)
        XCTAssertTrue(claude.isHidden)
        XCTAssertFalse(codex.isHidden)
        XCTAssertFalse(action.isHidden)
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), identities)
        filter.select(nil)
        XCTAssertTrue(menu.items.allSatisfy { !$0.isHidden })
        XCTAssertEqual(selections.count, 2)
        filter.select(nil)
        XCTAssertEqual(selections.count, 2)
    }

    /// 状态栏管理器会转移菜单项，控制器必须操作转移后的容器。
    func testProviderFilterCanRebindAfterMenuItemsMove() {
        let temporary = NSMenu()
        let final = NSMenu()
        let item = NSMenuItem()
        let filter = StatusBarProviderFilterController(selectedProvider: .claude) { _ in }
        filter.register(item, scope: .provider(.codex))
        temporary.addItem(item)
        filter.activate(in: temporary)
        temporary.removeItem(item)
        final.addItem(item)
        filter.activate(in: final)
        filter.select(.codex)
        XCTAssertFalse(item.isHidden)
        XCTAssertTrue(final.items.first === item)
    }

    func testKiroRegionRejectsHostAndPathInjection() {
        for region in ["us-east-1", "ap-southeast-2", "us-gov-west-1", "cn-north-1"] {
            XCTAssertEqual(KiroQuotaFetcher.validatedRegion(region), region)
        }
        for region in ["us-east-1.evil.test/", "us-east-1@evil.test", "us--1", "us-east-x", "US-east-1", "us-east-1/path", "us-east-1?x"] {
            XCTAssertNil(KiroQuotaFetcher.validatedRegion(region))
        }
    }

    func testAntigravityExpiryPreservesFractionalTimestampAndUnknownState() throws {
        let decoder = JSONDecoder()
        let file = try decoder.decode(AntigravityAuthFile.self, from: Data(#"{"access_token":"fixture","email":"fixture@example.com","expired":"2030-01-01T00:00:00.123Z"}"#.utf8))
        XCTAssertEqual(try XCTUnwrap(file.expiryDate).timeIntervalSince1970, 1_893_456_000.123, accuracy: 0.001)
        let unknown = try decoder.decode(AntigravityAuthFile.self, from: Data(#"{"access_token":"fixture","email":"fixture@example.com","expired":"invalid"}"#.utf8))
        XCTAssertNil(unknown.expiryDate)
        XCTAssertTrue(unknown.isExpired)
    }
}
