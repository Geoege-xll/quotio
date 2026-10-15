//
//  CLIProxyManager.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import AppKit
import Yams

@MainActor
@Observable
final class CLIProxyManager {
    static let shared = CLIProxyManager()
    // 版本管理已拆到独立文件，仓库与版本键在同一模块内由升级流程读取。
    static let upstreamRepository = "router-for-me/CLIProxyAPI"
    static let installedVersionDefaultsKey = "installedProxyVersion_upstream"
    
    /// Whether to allow network access to the proxy (bind to 0.0.0.0)
    var allowNetworkAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "allowNetworkAccess") }
        set {
            guard newValue != UserDefaults.standard.bool(forKey: "allowNetworkAccess") else { return }
            ensureConfigExists()
            configWriteFailed = false
            // 先确认客户端密钥及监听地址都已落盘，再更新偏好与界面；失败时不能让开关显示
            // “仅本机”而旧进程仍监听所有网卡，也不能在缺少密钥时开放局域网监听。
            if newValue && !ensureApiKeyExistsInConfig() {
                lastError = "无法确认 CPA 客户端密钥，已取消局域网访问变更"
                return
            }
            guard updateConfigHost(newValue ? "0.0.0.0" : "127.0.0.1") else {
                lastError = "CPA 监听地址写入失败，已保留原访问模式"
                return
            }
            UserDefaults.standard.set(newValue, forKey: "allowNetworkAccess")

            // Restart proxy if running to apply changes
            restartProxyIfRunning()
        }
    }
    
    nonisolated static func terminateProxyOnShutdown() {
        let savedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        let port = (savedPort > 0 && savedPort < 65536) ? UInt16(savedPort) : 8080
        killProcessOnPort(port)
    }
    
    nonisolated private static func killProcessOnPort(_ port: UInt16) {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        let ownPid = ProcessInfo.processInfo.processIdentifier

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    if pid == ownPid {
                        NSLog("[CLIProxyManager] Skipping kill of own PID \(pid) on port \(port) during shutdown")
                        continue
                    }
                    kill(pid, SIGKILL)
                }
            }
        } catch {
        }
    }
    
    private var process: Process?
    // 试运行与认证流程在独立扩展中管理各自的进程句柄。
    var testProcess: Process?
    var authProcess: Process?
    private(set) var proxyStatus = ProxyStatus()
    /// 只暴露当前由 Quotio 持有且仍存活的进程标识；不从端口或旧记录猜测 PID。
    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// 每次启停都会更换会话，供目录请求识别快速重启前的过期响应。
    private(set) var runtimeSessionID = UUID()
    #if DEBUG
    /// 仅供离线会话回归在测试宿主内设置状态样本；不创建／停止进程，不改磁盘配置或真实网络连接。
    /// 两个私有 setter 仍由原类型维护；用例必须保存并恢复原值，正常应用流程不调用此入口。
    func setRuntimeStateForTesting(running: Bool, sessionID: UUID) {
        proxyStatus.running = running
        runtimeSessionID = sessionID
    }
    #endif
    private(set) var isStopping = false
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    private(set) var isStarting = false
    /// 停止可能发生在旧启动的端口清理期间；下一次启动要等旧流程真正退出。
    @ObservationIgnored private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    /// 界面可能连续保存或切换服务商；串行执行局部 PATCH，防止后发请求用旧文件覆盖先发结果。
    @ObservationIgnored private var providerSyncInProgress = false
    @ObservationIgnored private var providerSyncWaiters: [CheckedContinuation<Void, Never>] = []
    /// 局部配置编辑若失败，启动流程须在拉起进程前明确中止，不能继续用旧端口或旧密钥探测。
    @ObservationIgnored private var configWriteFailed = false
    // 初次安装与版本升级共用下载进度，两个文件都必须能更新同一状态。
    var isDownloading = false
    private(set) var isRegeneratingKey = false
    var downloadProgress: Double = 0
    private(set) var lastError: String?
    
    // MARK: - Managed Upgrade State
    
    /// Current state of the proxy manager.
    var managerState: ProxyManagerState = .idle
    
    /// Version currently being tested (during dry-run).
    var testingVersion: String?
    
    /// Port used for dry-run testing.
    var testPort: UInt16?
    
    /// Path to the test config file (for cleanup).
    var testConfigPath: String?

    /// Raw management key for the current dry-run proxy.
    var testManagementKey: String?
    
    /// The active proxy version (if using versioned storage).
    var activeVersion: String?
    
    /// Last upgrade error message.
    var upgradeError: String?
    
    /// Whether an upgrade is available.
    var upgradeAvailable: Bool = false
    
    /// Available upgrade version info.
    var availableUpgrade: ProxyVersionInfo?
    
    /// Last time a proxy update check was performed.
    var lastProxyUpdateCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastProxyUpdateCheckDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastProxyUpdateCheckDate") }
    }
    
    /// Health monitor task for auto-recovery
    private var healthMonitorTask: Task<Void, Never>?

    /// PIDs that Quotio intentionally terminates during stop/restart/upgrade flows.
    private var expectedTerminationPIDs = Set<Int32>()

    /// Pending restart after an unexpected proxy process exit.
    private var crashRestartTask: Task<Void, Never>?

    /// Consecutive restart attempts after unexpected process exits.
    private var crashRestartAttempts: Int = 0
    
    /// Consecutive health check failures
    private var healthCheckFailures: Int = 0
    
    /// Max failures before auto-restart
    private let maxHealthCheckFailures = 3

    /// Max crash restarts before giving up and leaving the proxy stopped.
    private let maxCrashRestartAttempts = 3
    
    /// Health check interval in seconds
    private let healthCheckIntervalSeconds: UInt64 = 30

    /// Initial delay before restarting after an unexpected process exit.
    private let crashRestartBaseDelaySeconds: UInt64 = 2

    /// Maximum restart delay after repeated unexpected process exits.
    private let maxCrashRestartDelaySeconds: UInt64 = 30
    
    /// Compatibility checker instance.
    let compatibilityChecker = CompatibilityChecker()
    
    /// Storage manager for versioned binaries.
    var storageManager: ProxyStorageManager { ProxyStorageManager.shared }
    
    let binaryPath: String
    let configPath: String
    let authDir: String
    private(set) var managementKey: String
    
    var port: UInt16 {
        get { proxyStatus.port }
        set {
            guard newValue != proxyStatus.port else { return }
            proxyStatus.port = newValue
            UserDefaults.standard.set(Int(newValue), forKey: "proxyPort")
            updateConfigPort(newValue)
            restartProxyIfRunning()
        }
    }
    
    private static let binaryName = "CLIProxyAPI"
    
    var baseURL: String {
        "http://127.0.0.1:\(proxyStatus.port)"
    }
    
    var managementURL: String {
        // 主界面、账号、设置和日志共享同一个 v8 管理根，不再保留 v0 运行时兼容分支。
        ManagementAPIClient.managementURL(for: baseURL)
    }

    /// CPA 8 的配置已经把客户端密钥移到 access.api-keys；顶层 api-keys 是上游凭据分组。
    /// 这里根据实际文件结构判断，兼容尚未由官方管理接口迁移的旧配置。
    private var usesV8Config: Bool {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any] else { return false }
        return CPAConfigLayout.isMigratedV8(root)
    }

    /// 混合布局中 v8 字段优先于旧字段；启动前同步端口和管理密钥时必须先识别该节点。
    private func hasV8Section(_ key: String) -> Bool {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any] else { return false }
        return root[key] is [String: Any]
    }

    /// 只修改指定的 v8 字段，保留其余节点、注释和顺序；解析失败时拒绝写入。
    /// 旧配置先由官方迁移器处理，避免在混合布局上按错误路径修改密钥。
    @discardableResult
    private func updateV8Config(path: [String], value: Any) -> Bool {
        do {
            // 文件不可读与解析失败一样属于写入失败；启动流程必须立即停止，而不是等待健康检查超时。
            let text = try String(contentsOfFile: configPath, encoding: .utf8)
            let updated = try CPAConfigLayout.updating(text, path: path, value: value)
            if updated != text { try updated.write(toFile: configPath, atomically: true, encoding: .utf8) }
            return true
        } catch {
            configWriteFailed = true
            lastError = "CPA 8 配置更新失败，请检查 config.yaml 的字段结构"
            NSLog("[CLIProxyManager] Failed to update CPA 8 config path: \(path.joined(separator: "."))")
            return false
        }
    }
    
    init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found")
        }
        let quotioDir = appSupport.appendingPathComponent("Quotio")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        
        try? FileManager.default.createDirectory(at: quotioDir, withIntermediateDirectories: true)
        
        self.binaryPath = quotioDir.appendingPathComponent("CLIProxyAPI").path
        self.configPath = quotioDir.appendingPathComponent("config.yaml").path
        self.authDir = homeDir.appendingPathComponent(".cli-proxy-api").path
        
        // Always use key from Keychain, generate new if not exists
        // Never read from config because CLIProxyAPI hashes the key on startup
        if let savedKey = KeychainHelper.getLocalManagementKey(), !savedKey.hasPrefix("$2a$") {
            self.managementKey = savedKey
        } else {
            let newKey = UUID().uuidString
            self.managementKey = newKey
            if !KeychainHelper.saveLocalManagementKey(newKey) {
                Log.keychain("Failed to persist local management key, using in-memory value")
            }
        }
        
        let savedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        if savedPort > 0 && savedPort < 65536 {
            self.proxyStatus.port = UInt16(savedPort)
        }

        try? FileManager.default.createDirectory(atPath: authDir, withIntermediateDirectories: true)

        ensureConfigExists()
    }

    /// Restart the proxy if it is currently running.
    /// This is used to apply configuration changes that require a restart.
    private func restartProxyIfRunning() {
        guard proxyStatus.running else { return }

        Task {
            NSLog("[CLIProxyManager] Restarting proxy to apply configuration changes...")
            stop()
            // Wait 0.5s for ports to clear
            try? await Task.sleep(nanoseconds: 500_000_000)

            do {
                try await start()
                NSLog("[CLIProxyManager] Proxy restarted successfully")
            } catch {
                NSLog("[CLIProxyManager] Failed to restart proxy: \(error)")
                lastError = "Failed to restart: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func updateConfigValue(pattern: String, replacement: String) -> Bool {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            NSLog("[CLIProxyManager] ERROR: Failed to read config file at \(configPath)")
            configWriteFailed = true
            return false
        }
        
        guard let range = content.range(of: pattern, options: .regularExpression) else {
            NSLog("[CLIProxyManager] ERROR: Pattern '\(pattern)' not found in config")
            configWriteFailed = true
            return false
        }
        
        do {
            content.replaceSubrange(range, with: replacement)
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[CLIProxyManager] ERROR: Failed to write config file: \(error)")
            configWriteFailed = true
            return false
        }
    }

    private func updateConfigPort(_ newPort: UInt16) {
        if hasV8Section("server") {
            updateV8Config(path: ["server", "port"], value: Int(newPort))
            return
        }
        // 旧布局也只修改根级端口，避免碰到服务商 URL 或扩展字段中的同名文本。
        updateConfigValue(pattern: #"(?m)^port:[ \t]*\d+"#, replacement: "port: \(newPort)")
    }

    @discardableResult
    private func updateConfigHost(_ host: String) -> Bool {
        if hasV8Section("server") {
            return updateV8Config(path: ["server", "host"], value: host)
        }
        return updateConfigValue(pattern: #"(?m)^host:[^\n]*$"#, replacement: "host: \"\(host)\"")
    }

    @discardableResult
    private func ensureApiKeyExistsInConfig() -> Bool {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8),
              let root = try? Yams.load(yaml: content) as? [String: Any] else { return false }
        if root["access"] != nil || root["api-keys"] is [String: Any] || CPAConfigLayout.isMigratedV8(root) {
            // v8 的顶层 api-keys 保存上游密钥，绝不能向其中插入客户端密钥字符串。
            // 混合布局中即使 server/management 尚未齐全，只要顶层 api-keys 已是分组映射，
            // 也必须按 v8 处理；access 本身结构错误则拒绝猜测写入位置。
            guard root["access"] == nil || root["access"] is [String: Any] else { return false }
            let access = root["access"] as? [String: Any] ?? [:]
            if access["api-keys"] != nil && !(access["api-keys"] is [String]) {
                NSLog("[CLIProxyManager] CPA 8 access.api-keys is not a list; refusing to overwrite")
                return false
            }
            let keys = access["api-keys"] as? [String] ?? []
            if keys.isEmpty {
                return updateV8Config(path: ["access", "api-keys"], value: ["quotio-local-\(UUID().uuidString)"])
            }
            return true
        }
        var lines = content.components(separatedBy: "\n")
        if let apiKeysIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "api-keys:" }) {
            var hasKey = false
            var scanIndex = apiKeysIndex + 1

            while scanIndex < lines.count {
                let line = lines[scanIndex]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    break
                }

                if trimmed.hasPrefix("-") {
                    let value = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { hasKey = true }
                    scanIndex += 1
                    continue
                }

                if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    break
                }

                scanIndex += 1
            }

            if !hasKey {
                let newKey = "quotio-local-\(UUID().uuidString)"
                lines.insert("  - \"\(newKey)\"", at: apiKeysIndex + 1)
                do { try lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8) }
                catch { return false }
            }
            return true
        }

        let newKey = "quotio-local-\(UUID().uuidString)"
        lines.append("")
        lines.append("api-keys:")
        lines.append("  - \"\(newKey)\"")
        lines.append("")
        do { try lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8) }
        catch { return false }
        return true
    }
    
    func updateConfigAllowRemote(_ enabled: Bool) {
        if hasV8Section("management") {
            updateV8Config(path: ["management", "allow-remote"], value: enabled)
            return
        }
        updateConfigValue(pattern: #"allow-remote:\s*(true|false)"#, replacement: "allow-remote: \(enabled)")
    }

    func updateConfigProxyURL(_ url: String?) {
        if hasV8Section("requests") {
            updateV8Config(path: ["requests", "proxy-url"], value: url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            restartProxyIfRunning()
            return
        }
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let proxyValue = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let range = content.range(of: #"(?m)^proxy-url:[^\n]*$"#, options: .regularExpression) {
            // 旧布局只允许更改根级全局代理；密钥条目里的同名字段属于单密钥代理。
            content.replaceSubrange(range, with: "proxy-url: \"\(proxyValue)\"")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        } else {
            if let portRange = content.range(of: #"(?m)^port:[^\n]*\n"#, options: .regularExpression) {
                content.insert(contentsOf: "proxy-url: \"\(proxyValue)\"\n", at: portRange.upperBound)
                try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
            }
        }

        restartProxyIfRunning()
    }

    // MARK: - Workarounds

    /// Applies a workaround to force the primary Google API URL in all auth files.
    /// This prevents fallback to the slow "sandbox" environment.
    /// Backs up original files before modification.
    func applyBaseURLWorkaround() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDir) else { return }

        for file in files where file.hasSuffix(".json") && file.starts(with: "antigravity-") {
            let path = (authDir as NSString).appendingPathComponent(file)
            let backupPath = path + ".bak"

            // Create backup if it doesn't exist
            if !fileManager.fileExists(atPath: backupPath) {
                try? fileManager.copyItem(atPath: path, toPath: backupPath)
            }

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { continue }

            var metadata = json["metadata"] as? [String: Any] ?? [:]
            metadata["base_url"] = "https://daily-cloudcode-pa.googleapis.com"
            json["metadata"] = metadata

            if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? newData.write(to: URL(fileURLWithPath: path))
            }
        }

        restartProxyIfRunning()
    }

    /// Restores the original auth files from backup, effectively reverting the URL workaround.
    func removeBaseURLWorkaround() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDir) else { return }

        var restoredCount = 0

        for file in files where file.hasSuffix(".json.bak") {
            let backupPath = (authDir as NSString).appendingPathComponent(file)
            let originalPath = backupPath.replacingOccurrences(of: ".bak", with: "")

            // Restore from backup
            do {
                if fileManager.fileExists(atPath: originalPath) {
                    try fileManager.removeItem(atPath: originalPath)
                }
                try fileManager.moveItem(atPath: backupPath, toPath: originalPath)
                restoredCount += 1
            } catch {
                NSLog("[CLIProxyManager] Failed to restore backup for \(file): \(error)")
            }
        }

        // Fallback: If no backups found, try to just remove the key from current files
        if restoredCount == 0 {
            for file in files where file.hasSuffix(".json") && file.starts(with: "antigravity-") {
                let path = (authDir as NSString).appendingPathComponent(file)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { continue }

                if var metadata = json["metadata"] as? [String: Any] {
                    metadata.removeValue(forKey: "base_url")
                    json["metadata"] = metadata

                    if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                        try? newData.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }

        restartProxyIfRunning()
    }

    private func ensureConfigExists() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let defaultConfig = """
        config-version: 8
        server:
          host: "\(allowNetworkAccess ? "0.0.0.0" : "127.0.0.1")"
          port: \(proxyStatus.port)
        management:
          allow-remote: false
          secret-key: "\(managementKey)"
        access:
          api-keys:
            - "quotio-local-\(UUID().uuidString)"
        oauth:
          auth-dir: "\(authDir)"
        requests:
          proxy-url: ""
        observability:
          logs:
            debug: false
            logging-to-file: false
          usage:
            usage-statistics-enabled: true
        routing:
          strategy: "round-robin"
          retry:
            request-retry: 3
            max-retry-interval: 30
        """

        try? defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
    
    private func syncSecretKeyInConfig() {
        if hasV8Section("management") {
            updateV8Config(path: ["management", "secret-key"], value: managementKey)
            return
        }
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        
        if let range = content.range(of: #"secret-key:\s*\".*\""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(managementKey)\"")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        } else if let range = content.range(of: #"secret-key:\s*[^\n]+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(managementKey)\"")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }
    
    /// Regenerates the management key with staged persistence and rollback on failure.
    /// - Throws: `ProxyError` if proxy restart fails
    func regenerateManagementKey() async throws {
        guard !isRegeneratingKey else {
            throw ProxyError.operationInProgress
        }
        
        isRegeneratingKey = true
        defer { isRegeneratingKey = false }
        
        let previousKey = managementKey
        let newKey = UUID().uuidString
        managementKey = newKey
        configWriteFailed = false
        syncSecretKeyInConfig()
        if configWriteFailed {
            managementKey = previousKey
            throw ProxyError.networkError("CPA 8 管理密钥写入配置失败，已保留原密钥")
        }
        
        guard proxyStatus.running else {
            if !KeychainHelper.saveLocalManagementKey(newKey) {
                Log.keychain("Failed to persist regenerated management key while stopped")
            }
            return
        }
        
        do {
            stop()
            try await Task.sleep(for: .milliseconds(500))
            try await start()
            if !KeychainHelper.saveLocalManagementKey(newKey) {
                Log.keychain("Failed to persist regenerated management key after restart")
            }
        } catch {
            managementKey = previousKey
            syncSecretKeyInConfig()
            try? await Task.sleep(for: .milliseconds(300))
            try? await start()
            throw error
        }
    }
    
    /// Synchronizes the proxy URL from UserDefaults into the config.yaml file.
    ///
    /// If no local preference has been set (i.e., the user has never saved a proxy URL from the UI),
    /// this method returns early to preserve any value configured via the management web UI or
    /// direct config.yaml editing. Once the user sets a value through the app, UserDefaults becomes
    /// the source of truth and its value is written to config.yaml on each proxy start.
    private func syncProxyURLInConfig() {
        // If no local preference exists, keep config.yaml as-is (it may be set via management UI).
        guard UserDefaults.standard.object(forKey: "proxyURL") != nil else {
            return
        }

        let savedURL = UserDefaults.standard.string(forKey: "proxyURL") ?? ""
        
        guard !savedURL.isEmpty else {
            updateConfigProxyURL(nil)
            return
        }
        
        let sanitized = ProxyURLValidator.sanitize(savedURL)
        let isValid = ProxyURLValidator.validate(sanitized) == .valid
        updateConfigProxyURL(isValid ? sanitized : nil)
    }
    
    /// 保存中的服务商在代理运行时立即通过 v8 接口重载；停止状态等下次启动再同步。
    func syncCustomProvidersToConfig() async throws {
        guard proxyStatus.running else { return }
        if providerSyncInProgress {
            await withCheckedContinuation { providerSyncWaiters.append($0) }
        } else {
            providerSyncInProgress = true
        }
        defer {
            if providerSyncWaiters.isEmpty {
                providerSyncInProgress = false
            } else {
                providerSyncWaiters.removeFirst().resume()
            }
        }
        // 等待轮到本次同步后再次检查运行状态；服务可能已被用户关闭。
        guard proxyStatus.running else { return }
        let client = ManagementAPIClient(baseURL: "\(baseURL)/v8/management", authKey: managementKey)
        defer { Task { await client.invalidate() } }
        try await applyV8ProviderPatch(using: client)
    }

    private func applyV8ProviderPatch(
        using client: ManagementAPIClient,
        legacyOwnedProviderIDs: Set<UUID> = [],
        legacyOwnedKeys: [String: Set<String>] = [:]
    ) async throws {
        // 在网络 await 前固定本轮界面状态；若用户同时继续编辑，快照不能错记成尚未提交的新值。
        let providersSnapshot = CustomProviderService.shared.providers
        var stablePatch: Data?
        var foundStableSnapshot = false
        for _ in 0..<3 {
            let source = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let patch = try CustomProviderService.shared.makeV8ProviderPatch(
                configPath: configPath, legacyOwnedProviderIDs: legacyOwnedProviderIDs,
                legacyOwnedKeys: legacyOwnedKeys,
                managedProviders: providersSnapshot
            )
            // v8 的凭据族是整体数组；构造期间若别的客户端改了文件，立即重算以免覆盖新组。
            guard source == (try Data(contentsOf: URL(fileURLWithPath: configPath))) else { continue }
            stablePatch = patch
            foundStableSnapshot = true
            break
        }
        guard foundStableSnapshot else {
            throw ProxyError.networkError("CPA 配置同时被其他客户端修改，请重试服务商同步")
        }
        if let stablePatch { try await client.patchV8Config(stablePatch) }
        // CPA 确认接收（或配置已经一致）后才记录受管理的模型与请求头。
        // 网络失败时保留旧快照，下次同步仍能识别应删除的字段。
        try CustomProviderService.shared.markV8ProvidersSynced(providersSnapshot)
    }
    
    var isBinaryInstalled: Bool {
        storageManager.hasInstalledVersion
    }
    
    func downloadAndInstallBinary() async throws {
        lastError = nil

        do {
            let releaseInfo = try await fetchLatestRelease()
            let latestTag = releaseInfo.tagName.hasPrefix("v")
                ? String(releaseInfo.tagName.dropFirst())
                : releaseInfo.tagName
            let release = try await fetchGitHubRelease(tag: "v\(latestTag)")
            guard let asset = findCompatibleAsset(from: release),
                  let versionInfo = ProxyVersionInfo(from: release, asset: asset) else {
                throw ProxyError.noCompatibleBinary
            }

            try await performManagedUpgrade(to: versionInfo)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    private struct ReleaseInfo: Codable {
        let tagName: String
        let prerelease: Bool
        
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case prerelease
        }
    }
    
    private func fetchLatestRelease() async throws -> ReleaseInfo {
        // /releases/latest 的标记可能落在仍并行发布的 7.x；从发布列表挑选最新 8.x。
        let urlString = "https://api.github.com/repos/\(Self.upstreamRepository)/releases?per_page=50"
        guard let url = URL(string: urlString) else {
            throw ProxyError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.networkError("Failed to fetch release info")
        }
        if ProxyReleasePageParser.isRateLimited(httpResponse) {
            // GitHub API 限流时只从官方发行页选择稳定的 v8；不能照搬上游 /latest，
            // 因为 CPA 的 7.x 与 8.x 仍可能并行发布。
            let releases = try await fetchListedReleasesFromWeb(requiredCount: 1, stableOnly: true)
            guard let release = releases.first else {
                throw ProxyUpgradeError.noVersionAvailable
            }
            // 此处仅选择标签；下载前仍由 fetchGitHubRelease 读取资产与摘要。
            return ReleaseInfo(tagName: release.tag, prerelease: false)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch release info (HTTP \(httpResponse.statusCode))")
        }

        let releases = try JSONDecoder().decode([ReleaseInfo].self, from: data)
        guard let release = releases.first(where: {
            !$0.prerelease && ProxyVersionInfo(version: $0.tagName, sha256: "").isSupportedMajorVersion
        }) else { throw ProxyUpgradeError.noVersionAvailable }
        return release
    }
    
    func downloadAsset(url: String) async throws -> Data {
        guard let downloadURL = URL(string: url) else {
            throw ProxyError.networkError("Invalid download URL")
        }

        var request = URLRequest(url: downloadURL)
        request.addValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")

        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 300) // 5 minutes timeout for large downloads
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to download binary")
        }

        return data
    }
    
    private func extractAndInstall(data: Data, assetName: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let downloadedFile = tempDir.appendingPathComponent(assetName)
        try data.write(to: downloadedFile)
        
        let binaryURL = URL(fileURLWithPath: binaryPath)
        
        if assetName.hasSuffix(".tar.gz") || assetName.hasSuffix(".tgz") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", downloadedFile.path, "-C", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            if let binary = try findBinaryInDirectory(tempDir) {
                if FileManager.default.fileExists(atPath: binaryPath) {
                    try FileManager.default.removeItem(atPath: binaryPath)
                }
                try FileManager.default.copyItem(at: binary, to: binaryURL)
            } else {
                throw ProxyError.extractionFailed
            }
            
        } else if assetName.hasSuffix(".zip") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", downloadedFile.path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            if let binary = try findBinaryInDirectory(tempDir) {
                if FileManager.default.fileExists(atPath: binaryPath) {
                    try FileManager.default.removeItem(atPath: binaryPath)
                }
                try FileManager.default.copyItem(at: binary, to: binaryURL)
            } else {
                throw ProxyError.extractionFailed
            }
            
        } else {
            if FileManager.default.fileExists(atPath: binaryPath) {
                try FileManager.default.removeItem(atPath: binaryPath)
            }
            try FileManager.default.copyItem(at: downloadedFile, to: binaryURL)
        }
        
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        
        // Ad-hoc sign the binary to allow execution on macOS
        let signProcess = Process()
        signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProcess.arguments = ["-f", "-s", "-", binaryPath]
        try? signProcess.run()
        signProcess.waitUntilExit()
    }
    
    private func findBinaryInDirectory(_ directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey])
        
        let binaryNames = ["CLIProxyAPI", "cli-proxy-api", "claude-code-proxy", "proxy"]
        
        for name in binaryNames {
            if let found = contents.first(where: { $0.lastPathComponent.lowercased() == name.lowercased() }) {
                return found
            }
        }
        
        for item in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    if let found = try findBinaryInDirectory(item) {
                        return found
                    }
                } else {
                    let resourceValues = try item.resourceValues(forKeys: [.isExecutableKey])
                    if resourceValues.isExecutable == true {
                        let name = item.lastPathComponent.lowercased()
                        if !name.hasSuffix(".sh") && !name.hasSuffix(".txt") && !name.hasSuffix(".md") {
                            return item
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    func start(resetCrashRecoveryState: Bool = true) async throws {
        let requestedSession = runtimeSessionID
        // 等待真实端口清理结束，防止旧停止任务误杀新启动的进程。
        if let stopTask { await stopTask.value }
        while isStarting {
            await withCheckedContinuation { startupWaiters.append($0) }
        }
        try Task.checkCancellation()
        guard requestedSession == runtimeSessionID else { throw CancellationError() }
        guard isBinaryInstalled else {
            throw ProxyError.binaryNotFound
        }
        // 配置迁移到 v8 后不能再使用 v7 二进制启动；先校验版本，避免旧内核误读新配置。
        guard let currentVersion, ProxyVersionInfo(version: currentVersion, sha256: "").isSupportedMajorVersion else {
            throw ProxyError.networkError("QuotioPlus 现在仅支持 CLIProxyAPI 8.x，请先安装并激活 8.x 版本")
        }
        
        guard !proxyStatus.running else { return }

        if resetCrashRecoveryState {
            cancelCrashRestart()
            crashRestartAttempts = 0
        }
        
        isStarting = true
        runtimeSessionID = UUID()
        let startingSession = runtimeSessionID
        lastError = nil
        
        defer {
            isStarting = false
            let waiters = startupWaiters
            startupWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        
        // Clean up any orphan processes from previous runs
        await cleanupOrphanProcesses()
        try Task.checkCancellation()
        guard runtimeSessionID == startingSession else { throw CancellationError() }
        
        // 旧配置在同步管理密钥和端口之前先留内存快照；迁移开始时再写入备份文件。
        // 这样备份保留的是本轮启动前的原件，而不是已经被启动前步骤改写的版本。
        let originalLegacyConfig: Data?
        if usesV8Config { originalLegacyConfig = nil }
        else { originalLegacyConfig = try Data(contentsOf: URL(fileURLWithPath: configPath)) }
        configWriteFailed = false
        syncSecretKeyInConfig()
        // 服务商变更等 v8 管理接口就绪后再提交，避免离线重写整份配置及用户注释。
        
        updateConfigPort(proxyStatus.port)
        guard !configWriteFailed else {
            throw ProxyError.networkError("CPA 8 配置更新失败，请检查 config.yaml 的字段结构")
        }
        
        // Use effectiveBinaryPath to support versioned storage
        let activeBinaryPath = effectiveBinaryPath
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: activeBinaryPath)
        process.arguments = ["-config", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: activeBinaryPath).deletingLastPathComponent()
        
        // CRITICAL FIX: Drain stdout/stderr to prevent pipe buffer deadlock
        // macOS pipe buffer is ~64KB. If CLIProxyAPI writes more without being read,
        // the process blocks on write and becomes unresponsive (port open but no response).
        // Solution: Use readabilityHandler to continuously drain the buffers.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Drain stdout buffer to prevent blocking
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Discard data to prevent memory accumulation
            // If debug logging needed: NSLog("[CLIProxyAPI] \(String(data: data, encoding: .utf8) ?? "")")
            _ = data.count
        }
        
        // Drain stderr buffer to prevent blocking
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Discard data - errors are typically reported via exit code
            _ = data.count
        }
        
        // Important: Don't inherit environment that might cause issues
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        
        // Process 会持有终止回调；外层也弱引用管理器，避免进程存活期间通过回调形成保留环。
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            let pid = terminatedProcess.processIdentifier
            
            // Clear readability handlers to release closures and prevent resource leaks
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            // Close file handles to release resources
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let wasExpected = self.expectedTerminationPIDs.remove(pid) != nil

                guard self.process?.processIdentifier == pid else {
                    return
                }

                self.proxyStatus.running = false
                self.process = nil
                
                if !wasExpected && !self.isStarting {
                    self.lastError = "Process exited with code: \(status)"
                    if status != 0 {
                        NotificationManager.shared.notifyProxyCrashed(exitCode: status)
                    }
                    self.scheduleCrashRestart(exitCode: status)
                }
            }
        }
        
        do {
            try process.run()
            self.process = process
            
            try await Task.sleep(nanoseconds: 1_500_000_000)
            // 停止会立即更换会话；旧启动恢复时不能把已停止的服务重新标为运行中。
            try Task.checkCancellation()
            guard runtimeSessionID == startingSession, self.process === process else {
                throw CancellationError()
            }
            
            guard process.isRunning else {
                throw ProxyError.startupFailed
            }

            // 旧配置可在 CPA 8 上启动，但必须由上游 v8 管理接口负责迁移字段。
            // 迁移只运行一次，且先留原始副本；手写字段映射容易丢失未建模的凭据。
            let outcome = try await ProxyStartupHealthPoller().waitUntilReady(
                isProcessRunning: { process.isRunning },
                checkHealth: {
                    await self.compatibilityChecker.isHealthy(
                        port: self.proxyStatus.port,
                        managementKey: self.managementKey,
                        requestTimeout: 1
                    )
                }
            )
            guard case .ready = outcome else { throw ProxyError.startupFailed }
            // 健康检查期间用户可能已经点了停止；不能让旧启动继续迁移或写入配置。
            try Task.checkCancellation()
            guard runtimeSessionID == startingSession, self.process === process, process.isRunning else {
                throw CancellationError()
            }
            if !usesV8Config {
                guard let originalLegacyConfig else {
                    throw ProxyError.networkError("CPA 配置在启动期间被修改，请重试迁移")
                }
                try await migrateLegacyConfigToV8(
                    startingSession: startingSession, process: process,
                    originalLegacyConfig: originalLegacyConfig
                )
            } else {
                let client = ManagementAPIClient(baseURL: "\(baseURL)/v8/management", authKey: managementKey)
                defer { Task { await client.invalidate() } }
                // CPA 已通过健康检查，服务商同步属于后续配置操作。
                // 同步失败时保留旧配置和待同步快照，并向界面报告原因；不能把已健康
                // 启动的进程杀掉，否则用户连现有账号也无法继续使用。
                do {
                    try await applyV8ProviderPatch(using: client)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = "CPA 已启动，但服务商同步失败：\(error.localizedDescription)"
                }
            }
            // 迁移与服务商同步都有网络等待；停止操作会更换会话并清空进程。
            // 重新确认本轮仍有效，避免旧任务把已停止的服务重新标为运行中。
            try Task.checkCancellation()
            guard runtimeSessionID == startingSession, self.process === process, process.isRunning else {
                throw CancellationError()
            }
            // 全局代理偏好在官方迁移之后才写入 requests.proxy-url。
            // 旧配置里的单密钥 proxy-url 不能在备份之前被无锚点文本替换。
            syncProxyURLInConfig()
            guard !configWriteFailed else {
                throw ProxyError.networkError("CPA 8 全局代理配置更新失败，请检查 config.yaml 的字段结构")
            }
            
            NSLog("[CLIProxyManager] Proxy started on port \(proxyStatus.port)")
            
            proxyStatus.running = true
            
            startHealthMonitor()
            
        } catch {
            // 迁移或健康检查失败也必须清理本轮进程，避免界面显示已停止但端口仍被占用。
            if self.process === process {
                markExpectedTermination(process)
                if process.isRunning { process.terminate() }
                self.process = nil
                proxyStatus.running = false
            }
            if !(error is CancellationError) && runtimeSessionID == startingSession {
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    /// 只借助 CPA 官方迁移器改写配置。保留原文件副本直到新布局及 v8 管理接口都通过检查。
    private func migrateLegacyConfigToV8(
        startingSession: UUID, process: Process, originalLegacyConfig: Data
    ) async throws {
        let configURL = URL(fileURLWithPath: configPath)
        guard let legacyYAML = String(data: originalLegacyConfig, encoding: .utf8) else {
            throw ProxyError.networkError("旧 CPA 配置不是 UTF-8，无法安全备份和迁移")
        }
        let legacyOwnedProviderIDs = CustomProviderService.shared.legacyOwnedProviderIDs(in: legacyYAML)
        let legacyOwnedKeys = CustomProviderService.shared.legacyOwnedKeys(in: legacyYAML)
        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.pre-v8-\(UUID().uuidString).yaml")
        // 备份含客户端与上游密钥，创建时即限定为当前用户可读写；写完核对字节，
        // 不让部分写入的文件冒充可恢复的原始配置。
        guard FileManager.default.createFile(
            atPath: backupURL.path, contents: originalLegacyConfig,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ), (try? Data(contentsOf: backupURL)) == originalLegacyConfig else {
            throw ProxyError.networkError("旧 CPA 配置备份未完整写入，已取消迁移")
        }
        let client = ManagementAPIClient(baseURL: "\(baseURL)/v8/management", authKey: managementKey)
        defer { Task { await client.invalidate() } }
        var migratedSnapshot: Data?
        var providerPatchStarted = false
        do {
            try await client.migrateLegacyConfigToV8()
            // 记录官方迁移刚完成的文件；健康检查失败时仅在主文件仍逐字一致的情况下
            // 才允许自动恢复旧配置，避免覆盖等待期间其他管理客户端的修改。
            migratedSnapshot = try Data(contentsOf: configURL)
            guard usesV8Config,
                  await compatibilityChecker.isHealthy(port: proxyStatus.port, managementKey: managementKey) else {
                throw ProxyError.networkError("CPA 8 配置迁移后校验失败")
            }
            // 停止可能发生在官方迁移的网络请求期间；不得再提交服务商补丁。
            try Task.checkCancellation()
            guard runtimeSessionID == startingSession, self.process === process, process.isRunning else {
                throw CancellationError()
            }
            // 完成结构转换后仅 PATCH 受管理的凭据族，CPA 会校验并保留其余注释。
            providerPatchStarted = true
            try await applyV8ProviderPatch(
                using: client, legacyOwnedProviderIDs: legacyOwnedProviderIDs,
                legacyOwnedKeys: legacyOwnedKeys
            )
            // 首次迁移成功后仍保留原文件；只有实机运行和凭据行为都验证过才适合清理。
            // 备份仅在旧布局迁移时创建一次，后续 v8 启动不会重复生成。
            NSLog("[CLIProxyManager] CPA 8 migration backup retained at \(backupURL.path)")
        } catch {
            if error is CancellationError || providerPatchStarted {
                // 停止或服务商 PATCH 开始后，当前文件可能已经包含官方或外部写入；
                // 保留主文件和备份，下次启动按实际布局继续同步，不用旧副本覆盖它们。
                throw error
            }
            guard let migratedSnapshot,
                  let current = try? Data(contentsOf: configURL), current == migratedSnapshot else {
                throw ProxyError.networkError(
                    "CPA 8 迁移未完成，当前配置可能已被其他客户端修改；已保留主文件和备份 \(backupURL.path)：\(error.localizedDescription)"
                )
            }
            // 先复制备份到同目录临时文件，确认副本完整后才原子替换；恢复失败绝不能先删除主配置。
            let migrationError = error
            let restoreURL = configURL.deletingLastPathComponent()
                .appendingPathComponent(".config-restore-\(UUID().uuidString).yaml")
            do {
                try FileManager.default.copyItem(at: backupURL, to: restoreURL)
                let backupData = try Data(contentsOf: backupURL)
                guard try Data(contentsOf: restoreURL) == backupData else {
                    throw ProxyError.networkError("CPA 配置备份副本校验失败")
                }
                guard Darwin.rename(restoreURL.path, configURL.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } catch {
                try? FileManager.default.removeItem(at: restoreURL)
                throw ProxyError.networkError("CPA 8 迁移失败，且原配置自动恢复失败；备份仍在 \(backupURL.path)：\(error.localizedDescription)")
            }
            throw migrationError
        }
    }
    
    func stop() {
        // 即便实际清理尚未结束，每次新的停止意图都必须取消自动恢复，并否决
        // 正在等待 stopTask 的启动请求；仅底层进程清理需要去重。
        cancelCrashRestart()
        runtimeSessionID = UUID()
        guard !isStopping else { return }
        terminateAuthProcess()
        stopHealthMonitor()

        let currentProcess = process
        let port = proxyStatus.port
        markExpectedTermination(currentProcess)
        isStopping = true
        process = nil
        proxyStatus.running = false

        // 停止状态覆盖实际后台清理周期；所有启动入口会等待此任务，不能用延时模拟完成。
        stopTask = Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                if let proc = currentProcess, proc.isRunning {
                    let pid = proc.processIdentifier
                    proc.terminate()
                    let deadline = Date().addingTimeInterval(2.0)
                    while proc.isRunning && Date() < deadline {
                        usleep(100_000)
                    }
                    if proc.isRunning { kill(pid, SIGKILL) }
                }
                Self.killProcessOnPortSync(port)
            }.value
            self?.isStopping = false
            self?.stopTask = nil
        }
    }

    
    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Health Monitoring
    // ════════════════════════════════════════════════════════════════════════
    
    private func startHealthMonitor() {
        stopHealthMonitor()
        healthCheckFailures = 0
        
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: (self?.healthCheckIntervalSeconds ?? 30) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                
                await self?.performHealthCheck()
            }
        }
    }
    
    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func markExpectedTermination(_ process: Process?) {
        guard let process else { return }
        expectedTerminationPIDs.insert(process.processIdentifier)
    }

    private func cancelCrashRestart() {
        crashRestartTask?.cancel()
        crashRestartTask = nil
    }

    private func scheduleCrashRestart(exitCode: Int32) {
        guard crashRestartTask == nil else { return }

        switch managerState {
        case .testing, .promoting, .rollingBack:
            return
        case .idle, .active:
            break
        }

        guard crashRestartAttempts < maxCrashRestartAttempts else {
            NSLog("[CLIProxyManager] Max crash restart attempts reached after exit code \(exitCode)")
            return
        }

        crashRestartAttempts += 1
        let attempt = crashRestartAttempts
        let multiplier = UInt64(1 << max(0, attempt - 1))
        let delay = min(crashRestartBaseDelaySeconds * multiplier, maxCrashRestartDelaySeconds)

        NSLog("[CLIProxyManager] Scheduling proxy restart in \(delay)s after unexpected exit code \(exitCode) (attempt \(attempt)/\(maxCrashRestartAttempts))")

        crashRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }

            self.crashRestartTask = nil

            guard !self.proxyStatus.running else { return }

            switch self.managerState {
            case .testing, .promoting, .rollingBack:
                return
            case .idle, .active:
                break
            }

            do {
                try await self.start(resetCrashRecoveryState: false)
                NSLog("[CLIProxyManager] Crash auto-restart successful")
            } catch is CancellationError {
                // 用户停止优先于自动恢复，取消不应生成新的重试任务。
            } catch {
                self.lastError = "Auto-restart failed: \(error.localizedDescription)"
                NSLog("[CLIProxyManager] Crash auto-restart failed: \(error)")
                self.scheduleCrashRestart(exitCode: -1)
            }
        }
    }
    
    private func performHealthCheck() async {
        // Bail out if proxy is not running or manager is in upgrade flow
        guard proxyStatus.running else {
            healthCheckFailures = 0
            return
        }
        
        // Skip health check during managed upgrades to avoid racing with upgrade flow
        switch managerState {
        case .testing, .promoting, .rollingBack:
            NSLog("[CLIProxyManager] Skipping health check during \(managerState) state")
            return
        case .idle, .active:
            break
        }
        
        let session = runtimeSessionID
        let isHealthy = await compatibilityChecker.isHealthy(
            port: proxyStatus.port,
            managementKey: managementKey
        )
        
        // Re-check state after await - proxy may have been stopped or upgrade may have started
        guard !Task.isCancelled, runtimeSessionID == session, proxyStatus.running else { return }
        
        switch managerState {
        case .testing, .promoting, .rollingBack:
            NSLog("[CLIProxyManager] Aborting health check action - manager entered \(managerState) state")
            return
        case .idle, .active:
            break
        }
        
        if isHealthy {
            healthCheckFailures = 0
            crashRestartAttempts = 0
        } else {
            healthCheckFailures += 1
            NSLog("[CLIProxyManager] Health check failed (\(healthCheckFailures)/\(maxHealthCheckFailures))")
            
            if healthCheckFailures >= maxHealthCheckFailures {
                NSLog("[CLIProxyManager] Max failures reached, auto-restarting proxy...")
                healthCheckFailures = 0
                
                stop()
                // stop 会取消正在执行的健康检查。交给独立、可被后续 stop 取消的
                // 恢复任务处理，不能从已经取消的轮询任务直接重新启动。
                scheduleCrashRestart(exitCode: -1)
            }
        }
    }
    
    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Process Cleanup
    // ════════════════════════════════════════════════════════════════════════
    
    /// Clean up any orphan proxy processes from previous runs.
    /// Executes blocking operations on background thread to avoid blocking MainActor.
    private func cleanupOrphanProcesses() async {
        let port = proxyStatus.port
        
        // Execute blocking operations on background thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .userInitiated) {
                Self.killProcessOnPortSync(port)
                NSLog("[CLIProxyManager] Cleaned up orphan process on port \(port)")
                
                // Small delay to ensure ports are released
                usleep(200_000)  // 200ms, avoid Thread.sleep in async context
                continuation.resume()
            }
        }
    }
    
    /// Synchronous port cleanup for use in detached tasks.
    /// This method is `nonisolated` to allow calling from background threads.
    nonisolated static func killProcessOnPortSync(_ port: UInt16) {
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-ti", "tcp:\(port)"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        let ownPid = ProcessInfo.processInfo.processIdentifier

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }

            for pidString in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidString.trimmingCharacters(in: .whitespaces)) {
                    if pid == ownPid {
                        NSLog("[CLIProxyManager] Skipping kill of own PID \(pid) on port \(port)")
                        continue
                    }
                    kill(pid, SIGKILL)
                }
            }
        } catch {
            // Silent failure - process may not exist
        }
    }
    
    func terminateAuthProcess() {
        guard let authProcess = authProcess, authProcess.isRunning else { return }
        authProcess.terminate()
        self.authProcess = nil
    }
    
    func toggle() async throws {
        if proxyStatus.running {
            stop()
        } else {
            try await start()
        }
    }
    
    
    func revealInFinder() {
        let path = effectiveBinaryPath
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }
}

/// 仅解析 GitHub 官方发行页中下载链接与同一资产行的摘要；页面结构变化时返回失败，
/// 绝不使用缺少 SHA-256 的资产继续安装，以维持原有下载校验边界。
