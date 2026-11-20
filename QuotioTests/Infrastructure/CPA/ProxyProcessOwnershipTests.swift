import Darwin
import XCTest
@testable import QuotioPlus

@MainActor
final class ProxyProcessOwnershipTests: XCTestCase {
    func testStoppingOwnedProcessPreservesIndependentListener() async throws {
        let (external, port) = try launchListener(address: INADDR_LOOPBACK.bigEndian)
        defer { if external.isRunning { external.terminate() } }
        let owned = try launchSleeper()
        defer { if owned.isRunning { owned.terminate() } }

        // 子进程即使仍活着，也只有实际持有该端口的监听套接字才能通过归属检查。
        XCTAssertTrue(ProxyProcessOwnership.ownsLoopbackListener(external, port: port))
        XCTAssertFalse(ProxyProcessOwnership.ownsLoopbackListener(owned, port: port))
        XCTAssertThrowsError(try ProxyProcessOwnership.requireAvailablePort(port)) { error in
            guard case ProxyProcessOwnership.PortError.inUse(let conflictingPort) = error else {
                return XCTFail("应报告端口冲突，实际为 \(error)")
            }
            XCTAssertEqual(conflictingPort, port)
        }

        await ProxyProcessOwnership.terminate(owned)
        XCTAssertFalse(owned.isRunning)
        XCTAssertTrue(external.isRunning)
        XCTAssertTrue(ProxyProcessOwnership.ownsLoopbackListener(external, port: port))
    }

    func testLoopbackListenerTakingPortAfterPreflightIsNotAcceptedAsOwned() async throws {
        // Darwin 支持通配和回环同时监听。后启动的回环监听会接走发往 127.0.0.1 的管理流量。
        let (wildcard, port) = try launchListener(address: INADDR_ANY)
        defer { if wildcard.isRunning { wildcard.terminate() } }
        XCTAssertTrue(ProxyProcessOwnership.ownsLoopbackListener(wildcard, port: port))

        let (external, _) = try launchListener(address: INADDR_LOOPBACK.bigEndian, port: port)
        defer { if external.isRunning { external.terminate() } }
        XCTAssertFalse(ProxyProcessOwnership.ownsLoopbackListener(wildcard, port: port))

        await ProxyProcessOwnership.terminate(wildcard)
        XCTAssertFalse(wildcard.isRunning)
        XCTAssertTrue(external.isRunning)
        XCTAssertThrowsError(try ProxyProcessOwnership.requireAvailablePort(port))
    }

    #if DEBUG
    func testShutdownWaitsForPreviouslyHandedOffAuthorizationProcess() async throws {
        let testingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = CLIProxyManager(testingDirectory: testingDirectory)
        let ready = Pipe()
        let previous = Process()
        previous.executableURL = URL(fileURLWithPath: "/bin/sh")
        previous.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 20"]
        previous.standardOutput = ready
        try previous.run()
        defer { if previous.isRunning { previous.interrupt() } }
        // 等待子进程安装忽略 TERM 的设置。用 exec 使 sleep 和设置陷阱的 shell 保持同一个进程身份。
        XCTAssertEqual(String(decoding: ready.fileHandleForReading.readData(ofLength: 5), as: UTF8.self), "ready")
        let current = try launchSleeper()
        defer { if current.isRunning { current.terminate() } }

        manager.authProcess = previous
        manager.terminateAuthProcess()
        XCTAssertNil(manager.authProcess, "移交旧授权后，即可登记新的授权进程")
        manager.authProcess = current

        // 移交后立刻退出，确保退出同时等到已经取消的旧授权以及仍登记的新授权。
        await manager.shutdownForApplicationExit()

        XCTAssertTrue(manager.isShuttingDown)
        XCTAssertFalse(previous.isRunning)
        XCTAssertFalse(current.isRunning)
        if !previous.isRunning {
            XCTAssertEqual(previous.terminationReason, .uncaughtSignal)
            XCTAssertEqual(previous.terminationStatus, SIGKILL)
        }
    }
    #endif

    private func launchListener(address: UInt32, port: UInt16 = 0) throws -> (Process, UInt16) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        var reuseAddress: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw posixError()
        }

        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = port.bigEndian
        endpoint.sin_addr.s_addr = address
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &endpoint) { endpointPointer in
            endpointPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, size)
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { throw posixError() }
        let addressRead = withUnsafeMutablePointer(to: &endpoint) { endpointPointer in
            endpointPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        guard addressRead == 0 else { throw posixError() }

        // 只把监听描述符交给测试子进程。父进程随即关闭原描述符，无需网络服务、凭据或已安装的 CPA。
        let process = try launchSleeper(input: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false))
        return (process, UInt16(bigEndian: endpoint.sin_port))
    }

    private func launchSleeper(input: FileHandle = .nullDevice) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["20"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
