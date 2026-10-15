import Foundation
import XCTest
@testable import QuotioPlus

/// 健康探测也必须实际经过 v8 路径、版本校验和 URLSession 重定向代理；所有请求由夹具截获。
final class CompatibilityCheckerV8Tests: XCTestCase {
    private func fixture(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response)
        -> (CompatibilityChecker, LifecycleHTTPState, String) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState(response: response)
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        addTeardownBlock { LifecycleHTTPProtocol.remove(host: host) }
        return (CompatibilityChecker(configuration: configuration), state, host)
    }

    func testProbeUsesV8ConfigAndManagementCredential() async {
        let (checker, state, host) = fixture { _, _ in .reply(#"{"config-version":8}"#) }
        let healthy = await checker.isHealthy(port: 8317, host: host, managementKey: "fixture-only")
        let compatible = await checker.checkCompatibility(port: 8317, host: host, managementKey: "fixture-only")
        XCTAssertTrue(healthy)
        XCTAssertTrue(compatible.isCompatible)
        XCTAssertEqual(state.requests.count, 2)
        XCTAssertTrue(state.requests.allSatisfy { $0.url.path == "/v8/management/config" && $0.authorization == "Bearer fixture-only" })
    }

    func testProbeRejectsWrongVersionHTMLAndAuthenticationFailureWithoutFallback() async {
        for response in [LifecycleHTTPState.Response.reply(#"{"config-version":7}"#), .reply("<html>other service</html>"), .replyStatus("{}", 401)] {
            let (checker, state, host) = fixture { _, _ in response }
            let healthy = await checker.isHealthy(port: 8317, host: host, managementKey: "fixture-only")
            XCTAssertFalse(healthy)
            XCTAssertEqual(state.requestCount, 1, "失败不回退旧接口或重复鉴权，以免触发 CPA 临时封禁")
        }
    }

    func testProbeRejectsCrossHostRedirectWithoutSendingCredentialToDestination() async {
        let destination = UUID().uuidString.lowercased() + ".invalid"
        let targetState = LifecycleHTTPState { _, _ in .reply(#"{"config-version":8}"#) }
        LifecycleHTTPProtocol.register(targetState, host: destination)
        defer { LifecycleHTTPProtocol.remove(host: destination) }
        let (checker, sourceState, host) = fixture { _, _ in .redirect("http://" + destination + ":8317/v8/management/config") }
        let healthy = await checker.isHealthy(port: 8317, host: host, managementKey: "fixture-only")
        XCTAssertFalse(healthy)
        XCTAssertEqual(sourceState.requestCount, 1)
        XCTAssertEqual(targetState.requestCount, 0, "即使目的地返回合法 v8 配置也不能追随跨源跳转")
    }

    func testProbeRejectsSameHostDifferentPortRedirect() async {
        let (checker, state, host) = fixture { request, _ in
            guard request.url?.port == 8317 else { return .reply(#"{"config-version":8}"#) }
            var target = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            target.port = 8318
            return .redirect(target.string!)
        }
        let healthy = await checker.isHealthy(port: 8317, host: host, managementKey: "fixture-only")
        XCTAssertFalse(healthy)
        XCTAssertEqual(state.requestCount, 1)
    }

    func testProbeStillAllowsSameOriginRedirectAndValidatesDestinationVersion() async {
        let (checker, state, host) = fixture { request, _ in
            if request.url?.path == "/v8/management/config" {
                var target = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                target.path = "/ready"
                return .redirect(target.string!)
            }
            return .reply(#"{"config-version":8}"#)
        }
        let healthy = await checker.isHealthy(port: 8317, host: host, managementKey: "fixture-only")
        XCTAssertTrue(healthy)
        XCTAssertEqual(state.requests.map { $0.url.path }, ["/v8/management/config", "/ready"])
        XCTAssertTrue(state.requests.allSatisfy { $0.authorization == "Bearer fixture-only" })
    }
}
