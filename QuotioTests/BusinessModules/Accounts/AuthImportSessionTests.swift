import Foundation
import XCTest
@testable import QuotioPlus

/// 只操作临时目录、独立偏好和 URLProtocol 夹具，验证真正的 ViewModel 导入路径。
/// 挂起第二次文件读取，确定性复现用户启停 CPA／切模式时的主线程重入，不触碰真实凭据。
@MainActor
final class AuthImportSessionTests: XCTestCase {
    private let content = Data(#"{"type":"claude","email":"fixture@example.invalid","token":"fixture-only"}"#.utf8)

    private final class Gate {
        let reached: XCTestExpectation
        var continuation: CheckedContinuation<Void, Never>?
        init(_ reached: XCTestExpectation) { self.reached = reached }
        func wait() async { await withCheckedContinuation { continuation = $0; reached.fulfill() } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private struct Fixture {
        let vm: QuotaViewModel
        let mode: OperatingModeManager
        let directory: URL
        let service: DirectAuthFileService
    }
    private func fixture() throws -> Fixture {
        let suite = "quotio-auth-import-session-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let mode = OperatingModeManager(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = DirectAuthFileService(authDirectory: directory)
        let vm = QuotaViewModel(directAuthService: service, startsBackgroundServices: false,
            modeManager: mode, menuBarSettings: MenuBarSettingsManager(defaults: defaults),
            refreshSettings: RefreshSettingsManager(defaults: defaults))
        vm.customProvidersForTesting = []
        addTeardownBlock { @MainActor in
            vm.stopQuotaAutoRefresh()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(vm: vm, mode: mode, directory: directory, service: service)
    }
    private func client(hold: XCTestExpectation? = nil) -> (ManagementAPIClient, LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { _, _ in
            if let hold { hold.fulfill(); return .hold }
            return .reply(#"{"status":"ok"}"#)
        }
        LifecycleHTTPProtocol.register(state, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
            authKey: "fixture", configuration: config)
        addTeardownBlock { await client.invalidate(); LifecycleHTTPProtocol.remove(host: host) }
        return (client, state)
    }
    private var urls: [URL] { ["a.json", "b.json", "c.json"].map { URL(fileURLWithPath: "/fixture/" + $0) } }

    func testBatchDoesNotFallBackToDiskOrUseNewCPAClientAfterSecondRead() async throws {
        // 同时验证“停服变 nil”和“重启换 client”；两种都不能改变本批写入目标。
        for replaceClient in [false, true] {
            let f = try fixture()
            let (old, state) = client(), (fresh, freshState) = client()
            f.vm.setAuthImportClientForTesting(old)
            let gate = Gate(expectation(description: "第二个文件正在读取"))
            var reads: [String] = [], refreshes = 0
            f.vm.authImportReadHookForTesting = { url in
                reads.append(url.lastPathComponent)
                if reads.count == 2 { await gate.wait() }
                return self.content
            }
            f.vm.authImportRefreshHookForTesting = { _ in refreshes += 1 }
            let running = Task { await f.vm.importAuthFiles(from: urls) }
            await fulfillment(of: [gate.reached], timeout: 3)
            f.vm.setAuthImportClientForTesting(replaceClient ? fresh : nil)
            f.vm.errorMessage = "新会话提示"
            gate.release(); await running.value
            XCTAssertEqual(state.requests.count, 1)
            XCTAssertEqual(state.requests.first?.method, "POST")
            XCTAssertEqual(freshState.requestCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
            XCTAssertEqual(reads, ["a.json", "b.json"])
            XCTAssertEqual(refreshes, 0)
            XCTAssertEqual(f.vm.errorMessage, "新会话提示")
        }
    }

    func testLocalBatchDoesNotSwitchToCPAAfterSecondRead() async throws {
        let f = try fixture(), (fresh, state) = client()
        let gate = Gate(expectation(description: "本地批次第二次读取"))
        var reads = 0, refreshes = 0
        f.vm.authImportReadHookForTesting = { _ in
            reads += 1
            if reads == 2 { await gate.wait() }
            return self.content
        }
        f.vm.authImportRefreshHookForTesting = { _ in refreshes += 1 }
        let running = Task { await f.vm.importAuthFiles(from: urls) }
        await fulfillment(of: [gate.reached], timeout: 3)
        f.vm.setAuthImportClientForTesting(fresh)
        gate.release(); await running.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["a.json"])
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("a.json")), content)
        XCTAssertEqual(state.requestCount, 0)
        XCTAssertEqual(refreshes, 0)
    }

    func testLeavingAndReturningToSameModeStillInvalidatesBatch() async throws {
        let f = try fixture(), (client, state) = client()
        f.vm.setAuthImportClientForTesting(client)
        let gate = Gate(expectation(description: "模式切换前读取"))
        f.vm.authImportReadHookForTesting = { _ in await gate.wait(); return self.content }
        var refreshes = 0
        f.vm.authImportRefreshHookForTesting = { _ in refreshes += 1 }
        let running = Task { await f.vm.importAuthFiles(from: urls) }
        await fulfillment(of: [gate.reached], timeout: 3)
        f.mode.setMode(.monitor); f.mode.setMode(.localProxy)
        gate.release(); await running.value
        XCTAssertEqual(state.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
        XCTAssertEqual(refreshes, 0)
    }

    func testBatchContinuesAfterInvalidFileAndRefreshesLocalDirectoryOnce() async throws {
        let f = try fixture()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bad = source.appendingPathComponent("invalid.json"), good = source.appendingPathComponent("valid.json")
        try Data("[]".utf8).write(to: bad)
        try content.write(to: good)
        try await f.service.uploadAuthFile(name: "existing.json", content: content)
        var refreshTargets: [Bool] = []
        f.vm.authImportRefreshHookForTesting = { refreshTargets.append($0) }
        await f.vm.importAuthFiles(from: [bad, good])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: f.directory.path)), ["existing.json", "valid.json"])
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("valid.json")), content)
        XCTAssertEqual(refreshTargets, [false])
        XCTAssertTrue(f.vm.errorMessage?.contains("invalid.json") == true)
    }

    func testStableCPABatchUploadsAllFilesAndRefreshesOnce() async throws {
        let f = try fixture(), (client, state) = client()
        f.vm.setAuthImportClientForTesting(client)
        f.vm.authImportReadHookForTesting = { _ in self.content }
        var refreshTargets: [Bool] = []
        f.vm.authImportRefreshHookForTesting = { refreshTargets.append($0) }
        await f.vm.importAuthFiles(from: urls)
        XCTAssertEqual(state.requests.count, 3)
        XCTAssertEqual(state.requests.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }, ["a.json", "b.json", "c.json"])
        XCTAssertTrue(state.requests.allSatisfy { $0.method == "POST" && $0.body == content })
        XCTAssertEqual(refreshTargets, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    }

    func testStopDuringInFlightUploadCannotStartRemainingFilesOrPublishError() async throws {
        let f = try fixture()
        let started = expectation(description: "第一项上传已发出")
        let (client, state) = client(hold: started)
        f.vm.setAuthImportClientForTesting(client)
        var reads = 0, refreshes = 0
        f.vm.authImportReadHookForTesting = { _ in reads += 1; return self.content }
        f.vm.authImportRefreshHookForTesting = { _ in refreshes += 1 }
        let running = Task { await f.vm.importAuthFiles(from: urls) }
        await fulfillment(of: [started], timeout: 3)
        f.vm.setAuthImportClientForTesting(nil)
        f.vm.errorMessage = "新页面提示"
        await client.invalidate()
        await running.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(state.requestCount, 1)
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(f.vm.errorMessage, "新页面提示")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    }

    func testCancelledBatchDoesNotWriteFileReadBeforeCancellation() async throws {
        let f = try fixture()
        let gate = Gate(expectation(description: "取消前读取挂起"))
        f.vm.authImportReadHookForTesting = { _ in await gate.wait(); return self.content }
        let running = Task { await f.vm.importAuthFiles(from: urls) }
        await fulfillment(of: [gate.reached], timeout: 3)
        running.cancel(); gate.release(); await running.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    }

    func testSingleImportAlsoPinsTargetBeforeReading() async throws {
        let f = try fixture(), (client, state) = client()
        let gate = Gate(expectation(description: "单文件读取挂起"))
        f.vm.authImportReadHookForTesting = { _ in await gate.wait(); return self.content }
        let running = Task { try await f.vm.importAuthFile(from: urls[0]) }
        await fulfillment(of: [gate.reached], timeout: 3)
        f.vm.setAuthImportClientForTesting(client)
        gate.release()
        do { try await running.value; XCTFail("单文件也不能更换目标") }
        catch is CancellationError { }
        XCTAssertEqual(state.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    }
}
