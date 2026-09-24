import XCTest
@testable import QuotioPlus

/// 用确定性的挂起点代替真实网络，验证停止能立即让出启动入口，且旧流程不会清掉新流程。
@MainActor
final class ProxyStartFlowTests: XCTestCase {
    func testStopAllowsRestartWhileOldInitializationIsStillSuspended() async {
        let flow = ProxyStartFlow()
        let oldGate = StartupGate(), newGate = StartupGate()
        let oldStarted = expectation(description: "旧初始化挂起")
        let newStarted = expectation(description: "新初始化开始")
        var oldSideEffect = false
        var newFinished = false
        let old = Task {
            await flow.run {
                oldStarted.fulfill()
                await oldGate.wait()
                guard !Task.isCancelled else { return }
                oldSideEffect = true
            }
        }
        await fulfillment(of: [oldStarted], timeout: 5)
        flow.cancel()
        XCTAssertFalse(flow.isRunning)
        let fresh = Task {
            await flow.run {
                newStarted.fulfill()
                await newGate.wait()
                newFinished = true
            }
        }
        await fulfillment(of: [newStarted], timeout: 5)
        await oldGate.open()
        await old.value
        XCTAssertFalse(oldSideEffect, "旧流程取消后不能继续启动隧道等副作用")
        XCTAssertTrue(flow.isRunning, "旧流程完成不能清掉新启动的状态")
        XCTAssertFalse(newFinished)
        await newGate.open()
        await fresh.value
        XCTAssertTrue(newFinished)
        XCTAssertFalse(flow.isRunning)
    }

    func testRepeatedStartDoesNotDuplicateCurrentInitialization() async {
        let flow = ProxyStartFlow(), gate = StartupGate()
        let started = expectation(description: "启动初始化开始")
        var calls = 0
        let first = Task {
            await flow.run { calls += 1; started.fulfill(); await gate.wait() }
        }
        await fulfillment(of: [started], timeout: 5)
        await flow.run { calls += 1 }
        XCTAssertEqual(calls, 1)
        await gate.open()
        await first.value
        await flow.run { calls += 1 }
        XCTAssertEqual(calls, 2, "正常完成后可发起下一轮启动")
    }

    func testCallerCancellationReachesInitialization() async {
        let flow = ProxyStartFlow(), gate = StartupGate()
        let started = expectation(description: "初始化开始")
        var cancelled = false
        let caller = Task {
            await flow.run {
                started.fulfill()
                await gate.wait()
                cancelled = Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 5)
        caller.cancel()
        await gate.open()
        await caller.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(flow.isRunning)
    }
}

/// 故意不自动响应取消，模拟已经交给外部系统、只能等回调返回的旧操作。
private actor StartupGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
