//
//  TunnelManager.swift
//  Quotio - Cloudflare Tunnel UI State Manager
//

import Foundation
import AppKit

@MainActor
@Observable
final class TunnelManager {
    static let shared = TunnelManager()
    
    // MARK: - State
    
    private(set) var tunnelState = CloudflareTunnelState()
    private(set) var installation: CloudflaredInstallation = .notInstalled
    
    // MARK: - Private Properties
    
    private let service = CloudflaredService()
    private var monitorTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var tunnelRequestId: UInt64 = 0
    private var startTimeoutTask: Task<Void, Never>?
    private let startTimeoutSeconds: TimeInterval = 30
    private var lastPort: UInt16 = 0
    private var autoRestartTask: Task<Void, Never>?
    private let autoRestartDelaySeconds: TimeInterval = 5
    private var autoRestartAttempts: Int = 0
    private let maxAutoRestartAttempts: Int = 3
    
    // MARK: - Init
    
    private init() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task {
            await refreshInstallation()
        }
    }
    
    // MARK: - Public API
    
    func refreshInstallation() async {
        // 安装检查会等待 cloudflared --version，离开 MainActor 以便 AppKit 仍能处理退出。
        let service = service
        installation = await Task.detached(priority: .utility) {
            service.detectInstallation()
        }.value
    }
    
    func startTunnel(port: UInt16) async {
        guard !isShuttingDown else { return }
        guard tunnelState.status == .idle || tunnelState.status == .error else {
            NSLog("[TunnelManager] Cannot start tunnel: status is %@", tunnelState.status.rawValue)
            return
        }
        
        guard installation.isInstalled, let binaryPath = installation.path else {
            tunnelState.status = .error
            tunnelState.errorMessage = "tunnel.error.notInstalled".localized()
            return
        }
        
        tunnelRequestId &+= 1
        let currentRequestId = tunnelRequestId
        
        tunnelState.status = .starting
        tunnelState.errorMessage = nil
        tunnelState.publicURL = nil
        cancelStartTimeout()
        
        do {
            CLIProxyManager.shared.updateConfigAllowRemote(true)

            try await service.start(port: port, binaryPath: binaryPath) { [weak self] url in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.tunnelRequestId == currentRequestId else {
                        NSLog("[TunnelManager] Ignoring stale callback for request %llu (current: %llu)", currentRequestId, self.tunnelRequestId)
                        return
                    }
                    self.tunnelState.publicURL = url
                    self.tunnelState.status = .active
                    self.tunnelState.startTime = Date()
                    self.lastPort = port
                    self.cancelStartTimeout()
                    self.cancelAutoRestart()
                    self.resetAutoRestartAttempts()
                    NSLog("[TunnelManager] Tunnel active: %@", url)
                }
            }

            // 启动挂起期间可能已收到停止或退出请求，旧任务不重新注册监测或计时器。
            guard tunnelRequestId == currentRequestId else { return }
            scheduleStartTimeout(requestId: currentRequestId)
            startMonitoring()
            
        } catch let error as TunnelError {
            guard tunnelRequestId == currentRequestId else { return }
            tunnelState.status = .error
            tunnelState.errorMessage = error.localizedMessage
            cancelStartTimeout()
            CLIProxyManager.shared.updateConfigAllowRemote(false)
            NSLog("[TunnelManager] Failed to start tunnel: %@", error.localizedMessage)
        } catch {
            guard tunnelRequestId == currentRequestId else { return }
            tunnelState.status = .error
            tunnelState.errorMessage = error.localizedDescription
            cancelStartTimeout()
            CLIProxyManager.shared.updateConfigAllowRemote(false)
            NSLog("[TunnelManager] Failed to start tunnel: %@", error.localizedDescription)
        }
    }
    
    func stopTunnel() async {
        guard !isShuttingDown, tunnelState.status == .active || tunnelState.status == .starting else { return }

        tunnelRequestId &+= 1
        let currentRequestId = tunnelRequestId
        cancelStartTimeout()
        cancelAutoRestart()
        
        tunnelState.status = .stopping
        stopMonitoring()
        
        await service.stop()
        guard tunnelRequestId == currentRequestId else { return }
        CLIProxyManager.shared.updateConfigAllowRemote(false)

        tunnelState.reset()
        NSLog("[TunnelManager] Tunnel stopped")
    }
    
    func toggle(port: UInt16) async {
        if tunnelState.isActive || tunnelState.status == .starting {
            await stopTunnel()
        } else {
            await startTunnel(port: port)
        }
    }
    
    func copyURLToClipboard() {
        guard let url = tunnelState.publicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    
    /// 退出同时关闭两层启动入口，主动取消排期，仅等待本实例的 Cloudflared Process。
    func shutdownForApplicationExit() async {
        isShuttingDown = true
        tunnelRequestId &+= 1
        cancelStartTimeout()
        cancelAutoRestart()
        stopMonitoring()

        let wasUsingRemoteAccess = tunnelState.status == .active || tunnelState.status == .starting
            || tunnelState.status == .stopping
        await service.shutdownForApplicationExit()
        if wasUsingRemoteAccess {
            CLIProxyManager.shared.updateConfigAllowRemote(false)
        }
        tunnelState.reset()
    }

    // MARK: - Process Monitoring
    
    private func startMonitoring() {
        stopMonitoring()
        
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
                
                guard let self = self else { break }
                
                let isRunning = await self.service.isRunning
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                let currentStatus = self.tunnelState.status
                
                if !isRunning && (currentStatus == .active || currentStatus == .starting) {
                    self.tunnelState.status = .error
                    self.tunnelState.errorMessage = "tunnel.error.unexpectedExit".localized()
                    CLIProxyManager.shared.updateConfigAllowRemote(false)
                    NSLog("[TunnelManager] Tunnel process exited unexpectedly")
                    await self.service.stop()
                    self.scheduleAutoRestart()
                    break
                }
            }
        }
    }
    
    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func scheduleStartTimeout(requestId: UInt64) {
        cancelStartTimeout()
        startTimeoutTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.startTimeoutSeconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self.tunnelRequestId == requestId else { return }
            guard self.tunnelState.status == .starting else { return }
            self.tunnelState.status = .error
            self.tunnelState.errorMessage = "tunnel.error.startTimeout".localized()
            CLIProxyManager.shared.updateConfigAllowRemote(false)
            NSLog("[TunnelManager] Tunnel start timed out after %.0f seconds", self.startTimeoutSeconds)
            await self.service.stop()
        }
    }

    private func cancelStartTimeout() {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
    }
    
    private func scheduleAutoRestart() {
        cancelAutoRestart()
        guard !isShuttingDown else { return }
        
        let autoRestartEnabled = UserDefaults.standard.bool(forKey: "autoRestartTunnel")
        guard autoRestartEnabled, lastPort > 0 else { return }
        
        guard autoRestartAttempts < maxAutoRestartAttempts else {
            NSLog("[TunnelManager] Max auto-restart attempts reached (%d), stopping", autoRestartAttempts)
            return
        }
        
        let delay = autoRestartDelaySeconds
        let port = lastPort
        
        NSLog("[TunnelManager] Scheduling auto-restart in %.0f seconds (attempt %d/%d)", delay, autoRestartAttempts + 1, maxAutoRestartAttempts)
        
        autoRestartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            
            guard self.tunnelState.status == .error || self.tunnelState.status == .idle else {
                NSLog("[TunnelManager] Skipping auto-restart: status is %@", self.tunnelState.status.rawValue)
                return
            }
            
            self.autoRestartAttempts += 1
            NSLog("[TunnelManager] Auto-restarting tunnel on port %d (attempt %d)", port, self.autoRestartAttempts)
            await self.startTunnel(port: port)
        }
    }
    
    private func cancelAutoRestart() {
        autoRestartTask?.cancel()
        autoRestartTask = nil
    }
    
    private func resetAutoRestartAttempts() {
        autoRestartAttempts = 0
    }
}
