import Foundation
import XCTest
@testable import QuotioPlus

/// 通过 URLProtocol 制造停机、重试和挂起请求；所有凭据均为样本，不访问真实 CPA。
final class ManagementAPIClientLifecycleTests: XCTestCase {
    private func fixture(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response)
        -> (ManagementAPIClient, LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState(response: response)
        LifecycleHTTPProtocol.register(state, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host, authKey: "fixture", configuration: config)
        addTeardownBlock {
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
        }
        return (client, state)
    }

    private func assertCancelled<T>(_ operation: () async throws -> T,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("已停止或取消的请求必须返回取消错误", file: file, line: line)
        } catch is CancellationError {
            // 正常控制流，不能重试，也不能让系统抛出无法捕获的会话失效异常。
        } catch {
            XCTFail("错误类型不符：\(error)", file: file, line: line)
        }
    }

    func testInvalidationRejectsNormalQueueAndCatalogRequestsWithoutHTTP() async {
        let (client, state) = fixture { _, _ in .reply("{}") }
        await client.invalidate()
        await client.invalidate()
        await assertCancelled { try await client.getDebug() }
        await assertCancelled { try await client.fetchUsageQueue() }
        await assertCancelled { try await client.fetchModelAliasCatalog() }
        XCTAssertEqual(state.requestCount, 0)
    }

    func testStoppingCancelsPendingRequestAndNewClientCanStart() async throws {
        let started = expectation(description: "旧客户端请求已挂起")
        let (old, _) = fixture { _, _ in started.fulfill(); return .hold }
        let pending = Task { try await old.getDebug() }
        await fulfillment(of: [started], timeout: 5)
        await old.invalidate()
        await assertCancelled { try await pending.value }

        let (fresh, state) = fixture { _, _ in .reply(#"{"debug":true}"#) }
        let enabled = try await fresh.getDebug()
        XCTAssertTrue(enabled, "重新启动必须使用独立的新会话")
        XCTAssertEqual(state.requestCount, 1)
    }

    func testTaskCancellationAbortsRequestWithoutInvalidatingClient() async throws {
        let started = expectation(description: "可取消请求已开始")
        let (client, state) = fixture { _, count in
            if count == 1 { started.fulfill(); return .hold }
            return .reply(#"{"debug":false}"#)
        }
        let pending = Task { try await client.getDebug() }
        await fulfillment(of: [started], timeout: 5)
        pending.cancel()
        await assertCancelled { try await pending.value }
        let enabled = try await client.getDebug()
        XCTAssertFalse(enabled)
        XCTAssertEqual(state.requestCount, 2)
    }

    func testInvalidationDuringRetryCannotCreateAnotherTask() async throws {
        let failed = expectation(description: "首次请求触发连接错误")
        let (client, state) = fixture { _, count in
            if count == 1 { failed.fulfill() }
            return .fail(.cannotConnectToHost)
        }
        let pending = Task { try await client.getDebug() }
        await fulfillment(of: [failed], timeout: 5)
        // 让错误回调进入既有的 500ms 退避窗口，然后模拟用户关闭服务。
        try await Task.sleep(for: .milliseconds(50))
        await client.invalidate()
        await assertCancelled { try await pending.value }
        XCTAssertEqual(state.requestCount, 1, "退避结束后不能重试失效会话")
    }

    func testCancellingRetryDoesNotWaitForFurtherRequests() async throws {
        let failed = expectation(description: "首次请求失败")
        let (client, state) = fixture { _, count in
            if count == 1 { failed.fulfill() }
            return .fail(.networkConnectionLost)
        }
        let pending = Task { try await client.getDebug() }
        await fulfillment(of: [failed], timeout: 5)
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        await assertCancelled { try await pending.value }
        XCTAssertEqual(state.requestCount, 1)
    }

    func testLiveClientStillRetriesConnectionFailure() async throws {
        let (client, state) = fixture { _, count in
            count == 1 ? .fail(.networkConnectionLost) : .reply(#"{"debug":true}"#)
        }
        let enabled = try await client.getDebug()
        XCTAssertTrue(enabled)
        XCTAssertEqual(state.requestCount, 2)
    }

    func testV8ConfigPatchReportsValidationReasonWithoutDiscardingStatus() async {
        let (client, state) = fixture { _, _ in
            // 仅用人工字段名模拟 CPA 的错误正文，验证启动失败时能显示可操作的原因。
            .replyStatus(#"{"error":"invalid_config","message":"api-keys.claude[1].keys: invalid entry"}"#, 400)
        }
        do {
            try await client.patchV8Config(Data(#"{"api-keys":{}}"#.utf8))
            XCTFail("CPA 拒绝配置时不能误报同步成功")
        } catch APIError.configRejected(let status, let reason) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(reason, "api-keys.claude[1].keys: invalid entry")
        } catch {
            XCTFail("应保留 CPA 的配置校验原因：\(error)")
        }
        XCTAssertEqual(state.requestCount, 1)
    }

    func testUsageQueueIsNeverRetriedAfterTransportFailure() async {
        let (client, state) = fixture { _, _ in .fail(.networkConnectionLost) }
        do {
            _ = try await client.fetchUsageQueue()
            XCTFail("连接错误必须返回调用方")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(state.requestCount, 1, "读取即移除的队列不能被通用重试消费两次")
    }

    func testCatalogSecondRequestAlsoCancelsWhenServiceStops() async {
        let started = expectation(description: "目录第二阶段已发出")
        let (client, state) = fixture { request, _ in
            if request.url?.path == "/api-keys" { return .reply(#"{"api-keys":["fixture"]}"#) }
            started.fulfill()
            return .hold
        }
        let pending = Task { try await client.fetchModelAliasCatalog() }
        await fulfillment(of: [started], timeout: 5)
        await client.invalidate()
        await assertCancelled { try await pending.value }
        XCTAssertEqual(state.requestCount, 2)
    }

    func testConcurrentTaskCreationAndInvalidationCannotCrash() async {
        let (client, _) = fixture { _, _ in .hold }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    do { _ = try await client.getDebug(); XCTFail("已失效会话不能成功") }
                    catch is CancellationError { }
                    catch { XCTFail("错误类型不符：\(error)") }
                }
            }
            await client.invalidate()
        }
    }

    @MainActor
    func testLogsRespectLiveFileLoggingStateAndRecoverWithoutHTTP400() async {
        let (client, state) = fixture { request, count in
            switch request.url?.path {
            case "/logging-to-file":
                // 首次和第三次轮询均为关闭状态；第二次开启后才允许读取日志。
                return .reply(count == 1 || count == 4
                    ? #"{"logging-to-file":false}"#
                    : #"{"logging-to-file":true}"#)
            case "/logs":
                return .reply(#"{"lines":["[2026-09-24 11:35:47] [INFO] fixture"],"line-count":1}"#)
            default:
                return .reply("{}")
            }
        }
        let viewModel = LogsViewModel()
        viewModel.configure(baseURL: "fixture", authKey: "fixture", client: client)

        await viewModel.refreshLogs()
        XCTAssertEqual(viewModel.isFileLoggingEnabled, false)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(state.requestCount, 1, "文件日志关闭时不得请求会返回 400 的 /logs")

        await viewModel.refreshLogs()
        XCTAssertEqual(viewModel.isFileLoggingEnabled, true)
        XCTAssertEqual(viewModel.logs.count, 1)
        XCTAssertEqual(state.requestCount, 3)

        await viewModel.refreshLogs()
        XCTAssertEqual(viewModel.isFileLoggingEnabled, false)
        XCTAssertTrue(viewModel.logs.isEmpty, "再次关闭后不能继续显示旧文件的日志")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(state.requestCount, 4)
    }
}

/// 每个测试使用独立主机名和状态，锁只保护 URLProtocol 的跨线程回调记录。
private final class LifecycleHTTPState: @unchecked Sendable {
    enum Response { case reply(String), replyStatus(String, Int), fail(URLError.Code), hold }
    private let lock = NSLock()
    private var count = 0
    private let response: @Sendable (URLRequest, Int) -> Response
    init(response: @escaping @Sendable (URLRequest, Int) -> Response) { self.response = response }
    var requestCount: Int { lock.withLock { count } }
    func next(_ request: URLRequest) -> Response {
        let count = lock.withLock { self.count += 1; return self.count }
        return response(request, count)
    }
}

private final class LifecycleHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: LifecycleHTTPState] = [:]
    static func register(_ state: LifecycleHTTPState, host: String) { lock.withLock { states[host] = state } }
    static func remove(host: String) { lock.withLock { _ = states.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = Self.lock.withLock({ Self.states[request.url!.host!] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch state.next(request) {
        case .reply(let body), .replyStatus(let body, 200):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .replyStatus(let body, let status):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hold:
            break
        }
    }
    override func stopLoading() { }
}
