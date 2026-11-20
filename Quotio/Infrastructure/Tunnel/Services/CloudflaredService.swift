//
//  CloudflaredService.swift
//  Quotio - Cloudflared subprocess management
//

import Foundation

actor CloudflaredService {
    
    private var process: Process?
    private var stopTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    private static let binaryPaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared"
    ]
    
    private static let tunnelURLPattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#
    
    nonisolated func detectInstallation() -> CloudflaredInstallation {
        for path in Self.binaryPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                let version = getVersion(at: path)
                return CloudflaredInstallation(isInstalled: true, path: path, version: version)
            }
        }
        return .notInstalled
    }
    
    private nonisolated func getVersion(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            
            if let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                return String(output[match])
            }
            return nil
        } catch {
            return nil
        }
    }
    
    func start(port: UInt16, binaryPath: String, onURLDetected: @escaping @Sendable (String) -> Void) async throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard process == nil else {
            throw TunnelError.alreadyRunning
        }

        // 启动复用已探测的路径。再次运行同步的 --version 可能让停止一直排在启动之后。
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw TunnelError.notInstalled
        }

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: binaryPath)
        // Use --config /dev/null to ignore user's existing config file
        // This ensures Quick Tunnel works without interference from named tunnels
        newProcess.arguments = ["tunnel", "--config", "/dev/null", "--protocol", "http2", "--url", "http://localhost:" + String(port)]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        newProcess.standardOutput = outputPipe
        newProcess.standardError = errorPipe
        
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var buffer = ""
            private var urlFound = false
            private let maxBufferSize = 65536 // 64KB max buffer
            
            func append(_ text: String) -> String? {
                lock.lock()
                defer { lock.unlock() }
                
                guard !urlFound else { return nil }
                buffer += text
                
                // Trim buffer to keep only trailing maxBufferSize characters
                if buffer.count > maxBufferSize {
                    let dropCount = buffer.count - maxBufferSize
                    buffer = String(buffer.dropFirst(dropCount))
                }
                
                if let range = buffer.range(of: CloudflaredService.tunnelURLPattern, options: .regularExpression) {
                    urlFound = true
                    return String(buffer[range])
                }
                return nil
            }
            
            func checkRemaining() -> String? {
                lock.lock()
                defer { lock.unlock() }
                
                guard !urlFound else { return nil }
                
                if let range = buffer.range(of: CloudflaredService.tunnelURLPattern, options: .regularExpression) {
                    urlFound = true
                    return String(buffer[range])
                }
                return nil
            }
        }
        
        let buffer = OutputBuffer()
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            
            // EOF detected - empty data means stream closed
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Check remaining buffer for URL on EOF
                if let url = buffer.checkRemaining() {
                    onURLDetected(url)
                }
                return
            }
            
            guard let text = String(data: data, encoding: .utf8) else { return }
            
            if let url = buffer.append(text) {
                onURLDetected(url)
            }
        }
        
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            
            // EOF detected - empty data means stream closed
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Check remaining buffer for URL on EOF
                if let url = buffer.checkRemaining() {
                    onURLDetected(url)
                }
                return
            }
            
            guard let text = String(data: data, encoding: .utf8) else { return }
            
            if let url = buffer.append(text) {
                onURLDetected(url)
            }
        }
        
        do {
            try newProcess.run()
            self.process = newProcess
            NSLog("[CloudflaredService] Started tunnel on port %d, PID: %d", port, newProcess.processIdentifier)
        } catch {
            cleanup()
            throw TunnelError.startFailed(error.localizedDescription)
        }
    }
    
    func stop() async {
        if let stopTask {
            // 手动停止、启动超时和应用退出可能重叠，复用同一次 Process 清理。
            await stopTask.value
            return
        }
        guard let process, process.isRunning else {
            cleanup()
            return
        }

        let task = Task { await stopProcess(process) }
        stopTask = task
        await task.value
    }

    func shutdownForApplicationExit() async {
        // 即使退出先于待调度的启动进入此 actor，后者也不能再创建进程。
        isShuttingDown = true
        await stop()
    }

    private func stopProcess(_ process: Process) async {
        defer {
            cleanup()
            stopTask = nil
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        NSLog("[CloudflaredService] Stopping tunnel, PID: %d", pid)
        process.terminate()

        let deadline = ContinuousClock.now + .milliseconds(500)
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            // 只升级信号到当前持有的子进程；用有界轮询等待系统回收。
            kill(pid, SIGKILL)
            let killDeadline = ContinuousClock.now + .milliseconds(250)
            while process.isRunning && ContinuousClock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                NSLog("[CloudflaredService] Tunnel did not exit before deadline, PID: %d", pid)
            }
        }
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }
    
    private func cleanup() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        
        outputPipe = nil
        errorPipe = nil
        process = nil
    }
    
}

enum TunnelError: Error, Sendable {
    case notInstalled
    case alreadyRunning
    case startFailed(String)
    case unexpectedExit
    
    var localizedMessage: String {
        switch self {
        case .notInstalled:
            return "Cloudflared is not installed"
        case .alreadyRunning:
            return "Tunnel is already running"
        case .startFailed(let reason):
            return "Failed to start tunnel: \(reason)"
        case .unexpectedExit:
            return "Tunnel exited unexpectedly"
        }
    }
}
