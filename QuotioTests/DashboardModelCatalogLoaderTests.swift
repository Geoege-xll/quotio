import XCTest
@testable import Quotio

/// 全部依赖为内存闭包；显式悬挂凭据返回，复现“running 已发布而 key 稍后才就绪”的真实次序。
final class DashboardModelCatalogLoaderTests: XCTestCase {
    private enum TestError: Error { case unavailable }

    private actor KeyGate {
        private var continuation: CheckedContinuation<[String], Never>?
        let started: XCTestExpectation
        init(started: XCTestExpectation) { self.started = started }

        func fetch() async -> [String] {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func release(_ keys: [String]) {
            continuation?.resume(returning: keys)
            continuation = nil
        }
    }

    private actor Requests {
        var keys: [String] = []
        func record(_ key: String) { keys.append(key) }
    }

    func testFirstLoadWaitsForCurrentKeyAndReturnsModelsWithoutManualRefresh() async throws {
        let started = expectation(description: "管理凭据请求已开始")
        let gate = KeyGate(started: started)
        let requests = Requests()
        let expected = [ModelCatalogEntry(id: "existing-provider-model", owner: "provider")]
        let loader = DashboardModelCatalogLoader(
            fetchAPIKeys: { await gate.fetch() },
            fetchModels: { key in
                await requests.record(key)
                return expected
            }
        )
        let initialLoad = Task { try await loader.load() }
        await fulfillment(of: [started], timeout: 2)
        let beforeKeysReady = await requests.keys
        XCTAssertTrue(beforeKeysReady.isEmpty, "API key 尚未就绪时不能抢发模型请求")
        await gate.release(["current-client-key"])
        let entries = try await initialLoad.value
        XCTAssertEqual(entries, expected)
        let sentKeys = await requests.keys
        XCTAssertEqual(sentKeys, ["current-client-key"], "同一次加载直接继续，不需用户第二次刷新")
    }

    func testCancellationWhileKeysArePendingDoesNotSendOldModelRequest() async {
        let started = expectation(description: "旧会话等待凭据")
        let gate = KeyGate(started: started)
        let requests = Requests()
        let loader = DashboardModelCatalogLoader(
            fetchAPIKeys: { await gate.fetch() },
            fetchModels: { key in await requests.record(key); return [] }
        )
        let oldLoad = Task { try await loader.load() }
        await fulfillment(of: [started], timeout: 2)
        oldLoad.cancel()
        await gate.release(["old-key"])
        do {
            _ = try await oldLoad.value
            XCTFail("已停止的目录任务应保持取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let sentKeys = await requests.keys
        XCTAssertTrue(sentKeys.isEmpty)
    }

    func testLateOldSessionCannotReplaceNewCatalogAfterKeysBecomeReady() async throws {
        let started = expectation(description: "旧会话等待凭据")
        let gate = KeyGate(started: started)
        var state = ModelCatalogState()
        let oldRequest = state.beginLoading()
        let oldLoader = DashboardModelCatalogLoader(
            fetchAPIKeys: { await gate.fetch() },
            fetchModels: { _ in [ModelCatalogEntry(id: "old-model", owner: nil)] }
        )
        let oldLoad = Task { try await oldLoader.load() }
        await fulfillment(of: [started], timeout: 2)
        // 模拟代理重启后的状态重置及新会话先完成；不依靠网络取消来保护显示结果。
        state.reset()
        let newRequest = state.beginLoading()
        let newLoader = DashboardModelCatalogLoader(
            fetchAPIKeys: { ["new-key"] },
            fetchModels: { _ in [ModelCatalogEntry(id: "new-model", owner: nil)] }
        )
        let newEntries = try await newLoader.load()
        state.complete(entries: newEntries, fetchedAt: Date(), requestID: newRequest)
        await gate.release(["old-key"])
        let oldEntries = try await oldLoad.value
        state.complete(entries: oldEntries, fetchedAt: Date(), requestID: oldRequest)
        XCTAssertEqual(state.entries.map(\.id), ["new-model"])
    }

    func testEmptyKeyListDoesNotInventManagementKeyAndEmptyCatalogStaysEmpty() async throws {
        let requests = Requests()
        let loader = DashboardModelCatalogLoader(
            fetchAPIKeys: { [] },
            fetchModels: { key in await requests.record(key); return [] }
        )
        let entries = try await loader.load()
        XCTAssertTrue(entries.isEmpty)
        let sentKeys = await requests.keys
        XCTAssertEqual(sentKeys, [""])
    }

    func testCredentialFailureIsReportedWithoutSendingModelsOrSubstitutingDefaults() async {
        let requests = Requests()
        let loader = DashboardModelCatalogLoader(
            fetchAPIKeys: { throw TestError.unavailable },
            fetchModels: { key in await requests.record(key); return [] }
        )
        do {
            _ = try await loader.load()
            XCTFail("管理凭据失败必须如实上抛")
        } catch {
            XCTAssertTrue(error is TestError)
        }
        let sentKeys = await requests.keys
        XCTAssertTrue(sentKeys.isEmpty)
    }

    func testModelFailureIsReportedWithoutAutomaticRetry() async {
        let requests = Requests()
        let loader = DashboardModelCatalogLoader(
            fetchAPIKeys: { ["valid-key"] },
            fetchModels: { key in await requests.record(key); throw TestError.unavailable }
        )
        do {
            _ = try await loader.load()
            XCTFail("真实目录失败不能伪造模型或无限重试")
        } catch {
            XCTAssertTrue(error is TestError)
        }
        let sentKeys = await requests.keys
        XCTAssertEqual(sentKeys, ["valid-key"])
    }
}
