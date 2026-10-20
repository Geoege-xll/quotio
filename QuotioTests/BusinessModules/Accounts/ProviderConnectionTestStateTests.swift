import XCTest
@testable import QuotioPlus

/// 使用生产弹窗实际持有的纯值规则模拟网络完成顺序，不依赖真实密钥或网络延迟。
@MainActor
final class ProviderConnectionTestStateTests: XCTestCase {
    func testOldSuccessCannotMarkEditedKeyAsVerifiedEvenBeforeOnChangeRuns() {
        var state = ProviderConnectionTestState()
        let old = state.begin(baseURL: "https://fixture.invalid/v1", apiKey: "key-a")
        state.complete(old, baseURL: old.baseURL, apiKey: "key-b",
                       result: .init(success: true, latencyMs: 1, message: "OK"))
        XCTAssertNil(state.result)
        XCTAssertFalse(state.isTesting)
    }

    func testOldFailureCannotReleaseOrOverwriteNewEndpointTest() {
        var state = ProviderConnectionTestState()
        let old = state.begin(baseURL: "https://old.invalid/v1", apiKey: "fixture")
        state.invalidate()
        let new = state.begin(baseURL: "https://new.invalid/v1", apiKey: "fixture")
        state.complete(old, baseURL: new.baseURL, apiKey: new.apiKey,
                       result: .init(success: false, latencyMs: nil, message: "old failure"))
        XCTAssertTrue(state.isTesting)
        XCTAssertNil(state.result)
        state.complete(new, baseURL: new.baseURL, apiKey: new.apiKey,
                       result: .init(success: true, latencyMs: 5, message: "OK"))
        XCTAssertFalse(state.isTesting)
        XCTAssertEqual(state.result?.success, true)
        XCTAssertEqual(state.result?.latencyMs, 5)
    }

    func testCloseAndReopenWithSameInputStillRejectsOldResult() {
        var state = ProviderConnectionTestState()
        let old = state.begin(baseURL: "https://fixture.invalid", apiKey: "fixture")
        state.invalidate()
        let new = state.begin(baseURL: old.baseURL, apiKey: old.apiKey)
        state.complete(old, baseURL: new.baseURL, apiKey: new.apiKey,
                       result: .init(success: true, latencyMs: 1, message: "old"))
        XCTAssertTrue(state.isTesting)
        XCTAssertNil(state.result)
    }
}
