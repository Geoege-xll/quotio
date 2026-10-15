import Foundation
import XCTest
@testable import QuotioPlus

/// 在网络 await 中更换日志连接，验证旧读写不能占用／释放新世代的操作槽位或发布错误。
/// 临时 HTTP 夹具截获所有请求；不启动真实代理、不读取实际日志文件。
@MainActor
final class LogsV8LifecycleTests: XCTestCase {
    private func fixture(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response)
        -> (ManagementAPIClient, LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState(response: response)
        LifecycleHTTPProtocol.register(state, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
            authKey: "fixture-only", configuration: config)
        addTeardownBlock { await client.invalidate(); LifecycleHTTPProtocol.remove(host: host) }
        return (client, state)
    }
    func testReconfigurationImmediatelyAllowsNewRefreshAndOldFinishKeepsNewLock() async {
        let oldStarted = expectation(description: "旧日志读取挂起")
        let newStarted = expectation(description: "新日志读取已发出")
        let (old, _) = fixture { _, _ in oldStarted.fulfill(); return .hold }
        let (fresh, freshState) = fixture { _, _ in newStarted.fulfill(); return .hold }
        let vm = LogsViewModel()
        vm.configure(baseURL: "old-fixture", authKey: "fixture", client: old)
        let first = Task { await vm.refreshLogs() }
        await fulfillment(of: [oldStarted], timeout: 3)
        vm.configure(baseURL: "fresh-fixture", authKey: "fixture", client: fresh)
        XCTAssertFalse(vm.isRefreshing)
        let second = Task { await vm.refreshLogs() }
        await fulfillment(of: [newStarted], timeout: 3)
        await first.value
        XCTAssertTrue(vm.isRefreshing, "旧请求结束不能把新刷新标记为空闲，放入第二个并发读取")
        XCTAssertEqual(freshState.requestCount, 1)
        XCTAssertNil(vm.errorMessage)
        vm.reset(); await second.value
        XCTAssertFalse(vm.isRefreshing)
    }

    func testReconfigurationDuringClearDoesNotBlockOrUnlockNewClear() async {
        let oldClear = expectation(description: "旧清理挂起")
        let newClear = expectation(description: "新清理挂起")
        let (old, _) = fixture { request, _ in
            if request.httpMethod == "DELETE" { oldClear.fulfill(); return .hold }
            return request.url?.path.hasPrefix("/v8/management/config/") == true
                ? .reply("true") : .reply(#"{"lines":[]}"#)
        }
        let (fresh, freshState) = fixture { request, _ in
            if request.httpMethod == "DELETE" { newClear.fulfill(); return .hold }
            return request.url?.path.hasPrefix("/v8/management/config/") == true
                ? .reply("true") : .reply(#"{"lines":[]}"#)
        }
        let vm = LogsViewModel()
        vm.configure(baseURL: "old-fixture", authKey: "fixture", client: old)
        await vm.refreshLogs()
        let first = Task { await vm.clearLogs() }
        await fulfillment(of: [oldClear], timeout: 3)
        vm.configure(baseURL: "fresh-fixture", authKey: "fixture", client: fresh)
        XCTAssertFalse(vm.isClearing)
        await vm.refreshLogs()
        let second = Task { await vm.clearLogs() }
        await fulfillment(of: [newClear], timeout: 3)
        await first.value
        XCTAssertTrue(vm.isClearing)
        XCTAssertEqual(freshState.requests.filter { $0.method == "DELETE" }.count, 1)
        vm.reset(); await second.value
    }

    func testLate400RecheckCannotOverwriteNewConnectionFeedback() async {
        let rechecking = expectation(description: "400 后复查日志开关挂起")
        let (old, _) = fixture { request, count in
            if count == 1 { return .reply("true") }
            if request.url?.path == "/v8/management/observability/logs" { return .replyStatus("{}", 400) }
            rechecking.fulfill(); return .hold
        }
        let (fresh, _) = fixture { _, _ in .reply("false") }
        let vm = LogsViewModel()
        vm.configure(baseURL: "old-fixture", authKey: "fixture", client: old)
        let first = Task { await vm.refreshLogs() }
        await fulfillment(of: [rechecking], timeout: 3)
        vm.configure(baseURL: "fresh-fixture", authKey: "fixture", client: fresh)
        vm.errorMessage = "新连接自己的提示"
        await first.value
        XCTAssertEqual(vm.errorMessage, "新连接自己的提示")
        XCTAssertNil(vm.isFileLoggingEnabled)
        vm.reset()
    }

    func testSameURLAndKeyWithNewRuntimeDiscardsOldLogsAndCursor() async {
        let (client, _) = fixture { request, _ in
            request.url?.path.hasPrefix("/v8/management/config/") == true ? .reply("true")
                : .reply(#"{"lines":["[2026-10-15 09:00:00] [INFO] old process"],"next-cursor":"old-process"}"#)
        }
        let vm = LogsViewModel(), session = UUID()
        vm.configure(baseURL: "fixture", authKey: "fixture", client: client, runtimeSessionID: session)
        await vm.refreshLogs()
        XCTAssertEqual(vm.logs.count, 1)
        // 此次不传新的测试 client，唯一变化是运行世代；只检查同步重配，不发出真实请求。
        vm.configure(baseURL: "fixture", authKey: "fixture", runtimeSessionID: UUID())
        XCTAssertTrue(vm.logs.isEmpty)
        XCTAssertNil(vm.lastUpdated)
        XCTAssertNil(vm.isFileLoggingEnabled)
        XCTAssertFalse(vm.isRefreshing)
        vm.reset()
    }
}
