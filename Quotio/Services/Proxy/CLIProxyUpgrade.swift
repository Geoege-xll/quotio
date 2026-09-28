//
//  CLIProxyUpgrade.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation

/// 版本发现、下载、试运行与回滚集中在此；共享运行状态仍由主管理器持有。
// MARK: - Managed Proxy Upgrade

extension CLIProxyManager {
    var upstreamCompatibilityWarning: String {
        "Copilot and Kiro auth flows may not work with the upstream CLIProxyAPI binary."
    }

    func isLegacyAuthWarningNeeded(for provider: AIProvider) -> Bool {
        return provider == .copilot || provider == .kiro
    }

    /// The effective binary path in upstream versioned storage.
    var effectiveBinaryPath: String {
        storageManager.currentBinaryPath ?? storageManager.expectedBinaryPath
    }

    /// Check if versioned storage is being used.
    var isUsingVersionedStorage: Bool {
        storageManager.hasInstalledVersion
    }

    /// Get the currently installed version.
    var currentVersion: String? {
        storageManager.currentVersion
    }

    /// List all installed versions.
    var installedVersions: [InstalledProxyVersion] {
        storageManager.listInstalledVersions().filter {
            ProxyVersionInfo(version: $0.version, sha256: "").isSupportedMajorVersion
        }
    }

    // MARK: - Upgrade Flow

    /// Check if an upgrade is available.
    /// Uses Atom feed with ETag caching for efficient polling.
    /// Falls back to GitHub API only when needed for download URLs.
    func checkForUpgrade() async {
        // Record when this check was performed
        lastProxyUpdateCheckDate = Date()

        // Use AtomFeedUpdateService for efficient version checking
        let currentVer = currentVersion ?? installedProxyVersion
        let (latestVersion, isNewer) = await AtomFeedUpdateService.shared.checkForCLIProxyUpdate(currentVersion: currentVer)

        guard isNewer, let latestTag = latestVersion else {
            upgradeAvailable = false
            availableUpgrade = nil
            return
        }

        guard ProxyVersionInfo(version: latestTag, sha256: "").isSupportedMajorVersion else {
            upgradeAvailable = false
            availableUpgrade = nil
            return
        }

        // New version available - fetch release details from GitHub API for download URL
        do {
            let release = try await fetchGitHubRelease(tag: latestTag.hasPrefix("v") ? latestTag : "v\(latestTag)")

            guard let asset = findCompatibleAsset(from: release) else {
                upgradeAvailable = false
                availableUpgrade = nil
                return
            }

            let versionInfo = ProxyVersionInfo(from: release, asset: asset)
            guard let info = versionInfo else {
                upgradeAvailable = false
                availableUpgrade = nil
                return
            }

            upgradeAvailable = true
            availableUpgrade = info

            // Note: Notification is handled by AtomFeedUpdateService polling
            let version = latestTag.hasPrefix("v") ? String(latestTag.dropFirst()) : latestTag
            NSLog("[CLIProxyManager] Upgrade available: \(version)")
        } catch {
            NSLog("[CLIProxyManager] Failed to fetch release details: \(error.localizedDescription)")
            upgradeAvailable = false
            availableUpgrade = nil
        }
    }

    /// Stored version from UserDefaults (for legacy single-binary installs).
    /// Public accessor for the settings screen.
    var installedProxyVersion: String? {
        UserDefaults.standard.string(forKey: Self.installedVersionDefaultsKey)
    }

    /// Save installed version to UserDefaults.
    private func saveInstalledVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.installedVersionDefaultsKey)
    }

    // MARK: - Fetch All Releases (for Advanced Mode)

    func fetchAvailableVersions(limit: Int = 10) async throws -> [ProxyVersionInfo] {
        try await fetchAvailableUpstreamVersions(limit: limit)
    }

    /// Fetch all available releases from GitHub.
    /// Used by Advanced Mode to allow users to select a specific version.
    private func fetchAvailableUpstreamVersions(limit: Int) async throws -> [ProxyVersionInfo] {
        guard limit > 0 else { return [] }
        // v7 与 v8 同时发布，需要在过滤后再限制数量，否则列表可能只剩几条甚至为空。
        let pageSize = min(max(limit * 3, 30), 100)
        let urlString = "https://api.github.com/repos/\(Self.upstreamRepository)/releases?per_page=\(pageSize)"
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
            throw ProxyError.networkError("Failed to fetch releases")
        }
        if ProxyReleasePageParser.isRateLimited(httpResponse) {
            // 仅在明确限流时使用 HTML 回退；每个候选仍须通过 v8 和 SHA-256 校验。
            let candidates = try await fetchListedReleasesFromWeb(requiredCount: max(limit * 3, 20))
            return try await ProxyReleasePageParser.collectAvailableVersions(from: candidates, limit: limit) { candidate in
                let release = try await self.fetchReleaseFromWeb(
                    tag: candidate.tag, prerelease: candidate.prerelease
                )
                return self.versionInfo(from: release)
            }
        }
        guard httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch releases (HTTP \(httpResponse.statusCode))")
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return Array(releases.compactMap { versionInfo(from: $0) }.prefix(limit))
    }

    /// Convert a GitHubRelease to ProxyVersionInfo for a compatible asset.
    func versionInfo(from release: GitHubRelease) -> ProxyVersionInfo? {
        // 官方仍发布 7.x，但应用的安装列表只能提供 8.x，避免用户重新激活旧内核。
        guard ProxyVersionInfo(version: release.versionString, sha256: "").isSupportedMajorVersion else { return nil }
        guard let asset = findCompatibleAsset(from: release) else { return nil }
        return ProxyVersionInfo(from: release, asset: asset)
    }

    /// Fetch GitHub release info for a specific tag.
    // 初次安装与升级共用发行详情，保留模块内调用入口以复用同一资产校验逻辑。
    func fetchGitHubRelease(tag: String) async throws -> GitHubRelease {
        let urlString = "https://api.github.com/repos/\(Self.upstreamRepository)/releases/tags/\(tag)"
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
            // 指定标签也必须从发行列表读取 GitHub 的预发布标记；资产页只提供下载项，
            // 若直接解析它并使用默认 false，会把数字标签的预发布误报为稳定版。
            let listed = try await fetchListedReleasesFromWeb(requiredCount: 1, matchingTag: tag)
            guard let release = listed.first else { throw ProxyUpgradeError.noVersionAvailable }
            return try await fetchReleaseFromWeb(tag: tag, prerelease: release.prerelease)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch release info (HTTP \(httpResponse.statusCode))")
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// GitHub API 配额耗尽时读取公开发行页；沿用代理设置，不绕过用户配置的网络路径。
    private func fetchReleasePage(path: String) async throws -> String {
        guard let url = URL(string: "https://github.com/\(Self.upstreamRepository)/\(path)") else {
            throw ProxyError.networkError("Invalid GitHub release URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Quotio/1.0", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ProxyError.networkError("Failed to fetch GitHub release page")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // GitHub API 限流时，初次安装也需借用升级模块的 v8 发行页回退。
    func fetchListedReleasesFromWeb(
        requiredCount: Int,
        stableOnly: Bool = false,
        matchingTag: String? = nil
    ) async throws -> [ProxyReleasePageParser.ListedRelease] {
        var releases: [ProxyReleasePageParser.ListedRelease] = []
        var seen = Set<String>()
        var page = 1
        // 官方列表每页仅约十条，且 v7/v8 并行发布；限流回退最多查看十页，
        // 一旦找到足够的 v8 候选就停止，避免无限翻页或无谓的网络请求。
        while page <= 10 && releases.count < requiredCount {
            try Task.checkCancellation()
            let path = page == 1 ? "releases" : "releases?page=\(page)"
            let html = try await fetchReleasePage(path: path)
            for release in ProxyReleasePageParser.listedReleases(in: html, repository: Self.upstreamRepository) {
                guard (!stableOnly || !release.prerelease),
                      seen.insert(release.tag).inserted else { continue }
                // 指定标签只取精确匹配项；当前页有其他新版本时仍继续翻页。
                if let matchingTag, release.tag != matchingTag { continue }
                releases.append(release)
            }
            guard let next = ProxyReleasePageParser.nextPage(in: html, repository: Self.upstreamRepository),
                  next == page + 1 else { break }
            page = next
        }
        guard !releases.isEmpty else { throw ProxyUpgradeError.noVersionAvailable }
        return releases
    }

    private func fetchReleaseFromWeb(tag: String, prerelease: Bool = false) async throws -> GitHubRelease {
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let html = try await fetchReleasePage(path: "releases/expanded_assets/\(encoded)")
        guard let release = ProxyReleasePageParser.release(
            tag: tag, html: html, repository: Self.upstreamRepository, prerelease: prerelease
        ) else {
            throw ProxyError.networkError("GitHub release assets or checksums are unavailable")
        }
        return release
    }

    /// Find compatible asset from GitHub release.
    func findCompatibleAsset(from release: GitHubRelease) -> GitHubAsset? {
        #if arch(arm64)
        let targetPatterns = ["darwin_arm64", "darwin_aarch64"]
        #else
        let targetPatterns = ["darwin_amd64"]
        #endif
        let skipPatterns = ["windows", "linux", "checksum"]

        for asset in release.assets {
            let lowercaseName = asset.name.lowercased()

            let shouldSkip = skipPatterns.contains { lowercaseName.contains($0) }
            if shouldSkip { continue }

            if targetPatterns.contains(where: { lowercaseName.contains($0) }) {
                return asset
            }
        }

        return nil
    }

    /// Perform a managed upgrade with dry-run validation.
    /// This is the main entry point for upgrades.
    ///
    /// Flow:
    /// 1. Download and verify new version
    /// 2. Start dry-run on test port
    /// 3. Validate compatibility via /meta
    /// 4. If valid: promote to active; if not: rollback
    func performManagedUpgrade(to version: ProxyVersionInfo) async throws {
        guard version.isSupportedMajorVersion else {
            throw ProxyUpgradeError.dryRunFailed("QuotioPlus 现在仅支持 CLIProxyAPI 8.x")
        }
        guard managerState == .active || managerState == .idle else {
            throw ProxyUpgradeError.dryRunFailed("Cannot upgrade while in \(managerState) state")
        }

        upgradeError = nil

        // Step 1: Download and install to versioned storage
        let installed = try await downloadAndInstallVersion(version)

        // Step 2: Perform dry-run
        do {
            try await startDryRun(version: installed.version)
        } catch {
            // Dry-run failed, cleanup
            try? storageManager.deleteVersion(installed.version)
            throw error
        }

        // Step 3: Validate compatibility
        guard let testPort = testPort, let testManagementKey = testManagementKey else {
            await stopTestProxy()
            try? storageManager.deleteVersion(installed.version)
            throw ProxyUpgradeError.dryRunFailed("Test port not available")
        }

        let compatResult = await compatibilityChecker.fullCheck(port: testPort, managementKey: testManagementKey)

        if !compatResult.isCompatible {
            // Compatibility failed, rollback
            await stopTestProxy()
            try? storageManager.deleteVersion(installed.version)
            upgradeError = compatResult.description
            NotificationManager.shared.notifyUpgradeFailed(version: installed.version, reason: compatResult.description)
            throw ProxyUpgradeError.compatibilityCheckFailed(compatResult)
        }

        // Step 4: Promote the new version
        try await promote(version: installed.version)

        // Cleanup old versions
        storageManager.cleanupOldVersions(keepLast: AppConstants.maxInstalledVersions)

        // Reset upgrade state - no longer available since we just installed it
        upgradeAvailable = false
        availableUpgrade = nil

        // Save the installed version
        saveInstalledVersion(installed.version)

        // Suppress any future upgrade notifications for this version
        // This prevents the bug where a notification is shown immediately after upgrading
        NotificationManager.shared.suppressUpgradeNotification(version: installed.version)

        NotificationManager.shared.notifyUpgradeSuccess(version: installed.version)
    }

    /// Download and install a specific version.
    private func downloadAndInstallVersion(_ versionInfo: ProxyVersionInfo) async throws -> InstalledProxyVersion {
        isDownloading = true
        downloadProgress = 0

        defer { isDownloading = false }

        // Determine download URL
        let binaryData: Data
        let assetName: String
        if let localFilePath = versionInfo.localFilePath {
            let fileURL = URL(fileURLWithPath: localFilePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ProxyUpgradeError.downloadFailed("Local binary not found at \(localFilePath)")
            }
            binaryData = try Data(contentsOf: fileURL)
            assetName = fileURL.lastPathComponent
        } else {
            let downloadURL: String
            if let url = versionInfo.downloadURL {
                downloadURL = url
            } else {
                // 已指定版本缺少下载地址时必须查询同一标签；取“最新版”会把另一个版本
                // 的二进制与当前摘要组合，既浪费下载，也可能误导后续升级状态。
                let tag = versionInfo.version.hasPrefix("v") ? versionInfo.version : "v\(versionInfo.version)"
                let release = try await fetchGitHubRelease(tag: tag)
                guard let asset = findCompatibleAsset(from: release) else {
                    throw ProxyUpgradeError.downloadFailed("No compatible binary found")
                }
                downloadURL = asset.browserDownloadUrl
            }

            downloadProgress = 0.1
            binaryData = try await downloadAsset(url: downloadURL)
            assetName = URL(string: downloadURL)?.lastPathComponent ?? "CLIProxyAPI"
        }

        downloadProgress = 0.6

        // Verify checksum - fail if no valid checksum is provided
        guard !versionInfo.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProxyUpgradeError.downloadFailed("No valid SHA256 checksum provided for downloaded binary")
        }
        try ChecksumVerifier.verifyOrThrow(data: binaryData, expected: versionInfo.sha256)
        downloadProgress = 0.7

        // Install to versioned storage
        let installed = try await storageManager.installVersion(
            version: versionInfo.version,
            binaryData: binaryData,
            assetName: assetName
        )
        downloadProgress = 1.0

        return installed
    }

    /// Start a dry-run of a specific version on a test port.
    private func startDryRun(version: String) async throws {
        guard let binaryPath = storageManager.getBinaryPath(for: version) else {
            throw ProxyUpgradeError.dryRunFailed("Version \(version) not installed")
        }

        managerState = .testing
        testingVersion = version

        // Find an unused port for testing
        let port = try findUnusedPort()
        testPort = port

        // Create a temporary config for the test
        let managementKey = UUID().uuidString
        let configPath = createTestConfig(port: port, managementKey: managementKey)
        testConfigPath = configPath
        testManagementKey = managementKey

        // Track success to determine cleanup behavior
        var succeeded = false
        defer {
            if !succeeded {
                // Cleanup on any failure path (sync version for defer block)
                stopTestProxySync()
                cleanupTestConfig(configPath)
                testConfigPath = nil
                testManagementKey = nil
                managerState = proxyStatus.running ? .active : .idle
                testingVersion = nil
                testPort = nil
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-config", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw ProxyUpgradeError.dryRunFailed(error.localizedDescription)
        }

        testProcess = process

        // Slow machines can take longer than a fixed startup delay to bind the
        // management endpoint. Poll with a bounded request timeout instead of
        // rejecting an otherwise healthy proxy after one early connection.
        let startupOutcome = try await ProxyStartupHealthPoller().waitUntilReady(
            isProcessRunning: { process.isRunning },
            checkHealth: {
                await self.compatibilityChecker.isHealthy(
                    port: port,
                    managementKey: managementKey,
                    requestTimeout: 1
                )
            }
        )

        switch startupOutcome {
        case .ready:
            break
        case .processExited:
            throw ProxyUpgradeError.dryRunFailed(
                "proxy.upgrade.error.testProcessExited".localizedStatic()
            )
        case .timedOut:
            throw ProxyUpgradeError.dryRunFailed(
                "proxy.upgrade.error.startupTimedOut".localizedStatic()
            )
        }

        // Mark success - defer block will not cleanup
        succeeded = true
    }

    /// Promote a tested version to active.
    private func promote(version: String) async throws {
        guard managerState == .testing else {
            throw ProxyUpgradeError.dryRunFailed("Not in testing state")
        }

        managerState = .promoting

        // Stop the test proxy and clean up test config
        await stopTestProxy()
        if let configPath = testConfigPath {
            cleanupTestConfig(configPath)
            testConfigPath = nil
        }
        testManagementKey = nil

        // Stop the current active proxy if running
        let wasRunning = proxyStatus.running
        if wasRunning {
            stop()
        }

        // Update the current symlink
        try storageManager.setCurrentVersion(version)
        activeVersion = version

        // Restart proxy if it was running
        if wasRunning {
            try await start()
        }

        managerState = proxyStatus.running ? .active : .idle
        testingVersion = nil
        testPort = nil
    }

    /// Rollback to the previous version.
    func rollback() async throws {
        guard let previousVersion = findPreviousVersion() else {
            throw ProxyUpgradeError.rollbackFailed("No previous version to rollback to")
        }

        let replacedVersion = currentVersion
        managerState = .rollingBack

        // Stop current proxy
        let wasRunning = proxyStatus.running
        if wasRunning {
            stop()
        }

        // Set previous as current
        try storageManager.setCurrentVersion(previousVersion)
        activeVersion = previousVersion

        // Restart if was running
        if wasRunning {
            try await start()
        }

        managerState = proxyStatus.running ? .active : .idle

        // 上游 f553f9d：旧版本成功激活并恢复运行后才能清理被替换版本。
        // setCurrentVersion 或 start 抛错时保留原二进制，使用户仍可恢复原版本。
        if let replacedVersion, replacedVersion != previousVersion {
            try? storageManager.deleteVersion(replacedVersion)
        }

        NotificationManager.shared.notifyRollback(toVersion: previousVersion)
    }

    // MARK: - Private Helpers

    private func stopTestProxy() async {
        guard let process = testProcess, process.isRunning else {
            testProcess = nil
            testManagementKey = nil
            return
        }

        let pid = process.processIdentifier
        process.terminate()

        // Wait up to 2 seconds for graceful termination
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        if process.isRunning {
            kill(pid, SIGKILL)
        }

        testProcess = nil
        testManagementKey = nil

        // Also kill anything on test port
        if let port = testPort {
            Self.killProcessOnPortSync(port)
        }
    }

    /// Synchronous version for use in defer blocks.
    private func stopTestProxySync() {
        guard let process = testProcess, process.isRunning else {
            testProcess = nil
            testManagementKey = nil
            return
        }

        let pid = process.processIdentifier
        process.terminate()

        // Wait up to 2 seconds for graceful termination
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            kill(pid, SIGKILL)
        }

        testProcess = nil
        testManagementKey = nil

        // Also kill anything on test port
        if let port = testPort {
            Self.killProcessOnPortSync(port)
        }
    }

    private func findUnusedPort() throws -> UInt16 {
        // Try ports in range 18000-18100
        for port in UInt16(18000)...UInt16(18100) {
            if !isPortInUse(port) && port != proxyStatus.port {
                return port
            }
        }
        throw ProxyUpgradeError.dryRunFailed("No available port for testing")
    }

    private func isPortInUse(_ port: UInt16) -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return true }
        defer { close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return bindResult != 0
    }

    private func createTestConfig(port: UInt16, managementKey: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let testConfigPath = tempDir.appendingPathComponent("quotio-test-config-\(port).yaml").path

        let testConfig = """
        config-version: 8
        server:
          host: "127.0.0.1"
          port: \(port)
        oauth:
          auth-dir: "\(authDir)"
        access:
          api-keys:
            - "quotio-test-\(UUID().uuidString.prefix(8))"
        management:
          allow-remote: false
          secret-key: "\(managementKey)"
        observability:
          logs:
            debug: false
            logging-to-file: false
          usage:
            usage-statistics-enabled: false
        routing:
          strategy: "round-robin"
        """

        try? testConfig.write(toFile: testConfigPath, atomically: true, encoding: .utf8)
        return testConfigPath
    }

    private func cleanupTestConfig(_ configPath: String) {
        try? FileManager.default.removeItem(atPath: configPath)
    }

    /// Compare two semantic version strings.
    /// Returns true if `newer` is greater than `older`.
    /// Handles versions like "6.6.73-0" where the suffix after "-" is a build number.
    private func isNewerVersion(_ newer: String, than older: String) -> Bool {
        // Parse version string into (major, minor, patch, build) components
        // Format: "6.6.73-0" -> [6, 6, 73, 0]
        func parseVersion(_ version: String) -> [Int] {
            // First split by "-" to separate version from build number
            let dashParts = version.split(separator: "-")
            let mainVersion = String(dashParts.first ?? "")
            let buildNumber = dashParts.count > 1 ? Int(dashParts[1]) : nil

            // Split main version by "."
            var parts = mainVersion.split(separator: ".").compactMap { Int($0) }

            // Append build number if present
            if let build = buildNumber {
                parts.append(build)
            }

            return parts
        }

        let newerParts = parseVersion(newer)
        let olderParts = parseVersion(older)

        // Pad shorter array with zeros
        let maxLength = max(newerParts.count, olderParts.count)
        let paddedNewer = newerParts + Array(repeating: 0, count: maxLength - newerParts.count)
        let paddedOlder = olderParts + Array(repeating: 0, count: maxLength - olderParts.count)

        for (n, o) in zip(paddedNewer, paddedOlder) {
            if n > o { return true }
            if n < o { return false }
        }

        return false // Equal versions
    }

    private func findPreviousVersion() -> String? {
        let versions = installedVersions
        let current = currentVersion

        // Find the most recent version that isn't current
        return versions
            .filter { $0.version != current && ProxyVersionInfo(version: $0.version, sha256: "").isSupportedMajorVersion }
            .sorted { $0.installedAt > $1.installedAt }
            .first?.version
    }
}
