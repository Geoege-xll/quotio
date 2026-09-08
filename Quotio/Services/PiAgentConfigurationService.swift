import Foundation

/// 与 EasyCLIProxyAPI 的 Pi provider 协议保持一致，集中定义路径和注册判断。
/// 不读取或改写 models.json，避免与 Pi 自身的其他 provider 配置相互覆盖。
nonisolated enum PiAgentSupport {
    static let package = "npm:@router-for-me/pi-cliproxyapi-provider"
    static let provider = "cliproxyapi"

    static func configURLs(homeDirectory: URL) -> [URL] {
        // 配置和两类统计共用路径解析，安装方式不改变 Pi 的默认数据目录。
        let directory = URL(fileURLWithPath: PiSessionPaths.agentDirectory(
            homeDirectory: homeDirectory.path, environment: ProcessInfo.processInfo.environment), isDirectory: true)
        return [directory.appendingPathComponent("cliproxyapi.json"), directory.appendingPathComponent("settings.json")]
    }

    static func isProviderPackage(_ entry: Any) -> Bool {
        let source = (entry as? String) ?? ((entry as? [String: Any])?["source"] as? String)
        guard let source else { return false }
        // Pi 同时支持字符串、带 source 的对象，以及固定版本的 npm 注册项。
        return source == package || source.hasPrefix(package + "@")
    }

    static func object(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw failure("Pi 配置必须是 JSON 对象，已停止写入：\(url.lastPathComponent)")
        }
        return object
    }

    static func isConfigured(homeDirectory: URL) -> Bool {
        let urls = configURLs(homeDirectory: homeDirectory)
        guard let config = try? object(at: urls[0]), let settings = try? object(at: urls[1]),
              let packages = settings["packages"] as? [Any], packages.contains(where: isProviderPackage),
              settings["defaultProvider"] as? String == provider,
              let model = settings["defaultModel"] as? String, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = config["apiKey"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let base = config["baseUrl"] as? String, let url = URL(string: base),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        return true
    }

    static func readSavedConfiguration(
        homeDirectory: URL, backups: [AgentConfigurationService.BackupFile]
    ) -> AgentConfigurationService.SavedAgentConfig? {
        let urls = configURLs(homeDirectory: homeDirectory)
        guard urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let config = try? object(at: urls[0]), let settings = try? object(at: urls[1]) else { return nil }
        // 只有 CPA 的默认模型才属于本接入；不把用户其他 provider 的模型误填到 CPA。
        let model = settings["defaultProvider"] as? String == provider ? settings["defaultModel"] as? String : nil
        let base = (config["baseUrl"] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1" }
        return .init(baseURL: base, apiKey: config["apiKey"] as? String,
                     modelSlots: model.map { [.sonnet: $0] } ?? [:],
                     isProxyConfigured: isConfigured(homeDirectory: homeDirectory), backupFiles: backups)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Quotio.PiConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Pi 的安装和配置只在用户提交自动配置时执行；读取状态、手动预览均不会启动进程。
/// 文件操作由独立 actor 串行执行，安装进程在后台等待，避免阻塞界面主线程。
actor PiAgentConfigurationService {
    private let homeDirectory: URL
    private let fileManager = FileManager.default

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    func generate(config: AgentConfiguration, mode: ConfigurationMode, detectionService: AgentDetectionService) async throws -> AgentConfigResult {
        let urls = PiAgentSupport.configURLs(homeDirectory: homeDirectory)
        let configURL = urls[0]
        let settingsURL = urls[1]
        let usesProxy = config.setupMode == .proxy
        let model = (config.modelSlots[.sonnet] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var settings = try PiAgentSupport.object(at: settingsURL)
        // packages 类型错误不能按空列表处理，否则会破坏原有插件注册。
        if let packages = settings["packages"], !(packages is [Any]) {
            throw PiAgentSupport.failure("Pi settings.json 的 packages 必须是数组，已保留原文件。")
        }
        var providerConfig = usesProxy ? try PiAgentSupport.object(at: configURL) : [:]
        if usesProxy {
            guard !model.isEmpty else { throw PiAgentSupport.failure("请先为 Pi 选择 CPA 提供的默认模型。") }
            guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PiAgentSupport.failure("配置 Pi 需要可用的 CPA API 密钥。")
            }
            guard var endpoint = URLComponents(string: config.proxyURL),
                  ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""), endpoint.host != nil,
                  endpoint.user == nil, endpoint.password == nil else {
                throw PiAgentSupport.failure("Pi 的 CPA 服务地址无效。")
            }
            // 其他智能体使用 /v1；官方 Pi 插件自行拼接 API 路径，必须去掉末尾 /v1。
            var path = endpoint.path
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasSuffix("/v1") { path.removeLast(3) }
            endpoint.path = path
            endpoint.query = nil
            endpoint.fragment = nil
            guard let baseURL = endpoint.url?.absoluteString else { throw PiAgentSupport.failure("无法生成 Pi 服务地址。") }
            providerConfig["baseUrl"] = baseURL
            providerConfig["apiKey"] = config.apiKey
            if mode == .automatic {
                // 保存前重新读取远程目录，不将其他智能体的静态兜底列表视为模型可用的证据。
                let models = try await AgentConfigurationService(homeDirectory: homeDirectory).fetchAvailableModels(config: config)
                guard models.contains(where: { $0.name == model }) else {
                    throw PiAgentSupport.failure("CPA 当前未提供模型 \(model)，请刷新模型列表后重新选择。")
                }
            }
        }

        let targets = usesProxy ? urls : [settingsURL]
        var backupPath: String?
        if mode == .automatic {
            try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 在插件安装之前备份，settings.json 的原始插件列表也能够通过现有备份界面恢复。
            for url in targets {
                let backup = try backupIfPresent(url)
                if backupPath == nil { backupPath = backup }
            }
            if usesProxy && !((settings["packages"] as? [Any]) ?? []).contains(where: PiAgentSupport.isProviderPackage) {
                let status = await detectionService.detectAgent(.pi)
                guard let binary = status.binaryPath else { throw PiAgentSupport.failure("未找到 Pi 可执行文件，请先安装 Pi。") }
                try await Self.installProvider(binary: binary, homeDirectory: homeDirectory, directory: settingsURL.deletingLastPathComponent())
            }
            // 安装器会修改 settings.json；必须基于安装后的内容合并，保留它新增的字段。
            settings = try PiAgentSupport.object(at: settingsURL)
            if let packages = settings["packages"], !(packages is [Any]) {
                throw PiAgentSupport.failure("Pi 插件安装后的 packages 格式无效，原始配置已备份。")
            }
            if usesProxy {
                // 等待网络期间用户可能编辑连接文件，只覆盖本功能负责的两个键。
                var latest = try PiAgentSupport.object(at: configURL)
                latest["baseUrl"] = providerConfig["baseUrl"]
                latest["apiKey"] = providerConfig["apiKey"]
                providerConfig = latest
            }
        }

        var packages = settings["packages"] as? [Any] ?? []
        if usesProxy {
            if !packages.contains(where: PiAgentSupport.isProviderPackage) {
                guard mode == .manual else {
                    throw PiAgentSupport.failure("Pi 安装器未注册 CLIProxyAPI 插件，已停止写入连接配置。")
                }
                packages.append(PiAgentSupport.package)
            }
            settings["packages"] = packages
            settings["defaultProvider"] = PiAgentSupport.provider
            settings["defaultModel"] = model
        } else {
            // 默认模式仅停用本 provider，保留其他包及用户切换到其他 provider 后的默认模型。
            if settings["packages"] != nil { settings["packages"] = packages.filter { !PiAgentSupport.isProviderPackage($0) } }
            if settings["defaultProvider"] as? String == PiAgentSupport.provider {
                settings.removeValue(forKey: "defaultProvider")
                settings.removeValue(forKey: "defaultModel")
            }
        }

        let values = usesProxy ? [providerConfig, settings] : [settings]
        let payloads = try values.map { value -> Data in
            var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            return data
        }
        let command = "PI_CODING_AGENT_DIR=\(Self.shellQuote(settingsURL.deletingLastPathComponent().path)) pi install \(PiAgentSupport.package)"
        let instructions = usesProxy
            ? (mode == .manual ? "先运行以下命令安装官方插件，再合并下列配置文件。\n\(command)\n完成后重启 Pi。" : "Pi 的官方 CLIProxyAPI 插件与默认模型已配置，请重启 Pi。")
            : "已生成停用 CPA 插件注册的配置。保留其他插件、设置和连接文件；应用后请重启 Pi，并选择原有提供商。"
        let rawConfigs = zip(targets, payloads).map { url, data in
            RawConfigOutput(format: .json, content: String(decoding: data, as: UTF8.self),
                            filename: url.lastPathComponent, targetPath: url.path, instructions: instructions)
        }
        if mode == .automatic { try writeTogether(targets: targets, payloads: payloads) }
        return .success(type: .file, mode: mode, configPath: usesProxy ? configURL.path : settingsURL.path,
                        authPath: usesProxy ? settingsURL.path : nil, rawConfigs: rawConfigs,
                        instructions: instructions, modelsConfigured: usesProxy ? 1 : 0, backupPath: backupPath)
    }

    private func backupIfPresent(_ url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        var timestamp = Int(Date().timeIntervalSince1970)
        var backup = url.path + ".backup.\(timestamp)"
        while fileManager.fileExists(atPath: backup) {
            timestamp += 1
            backup = url.path + ".backup.\(timestamp)"
        }
        try fileManager.copyItem(atPath: url.path, toPath: backup)
        return backup
    }

    /// 两份配置逐个原子替换；第二份失败时恢复已写文件，避免连接参数与默认模型半更新。
    /// 插件安装由 Pi 管理，不在回滚时删除安装产物；安装前备份仍保留供用户恢复。
    private func writeTogether(targets: [URL], payloads: [Data]) throws {
        let originals: [Data?] = try targets.map { fileManager.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil }
        var written: [Int] = []
        do {
            for index in targets.indices {
                try payloads[index].write(to: targets[index], options: .atomic)
                written.append(index)
                // 配置中包含业务密钥，仅允许当前用户读写。
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targets[index].path)
            }
        } catch {
            var failedRollback = false
            for index in written.reversed() {
                do {
                    if let original = originals[index] { try original.write(to: targets[index], options: .atomic) }
                    else { try fileManager.removeItem(at: targets[index]) }
                } catch { failedRollback = true }
            }
            if failedRollback { throw PiAgentSupport.failure("Pi 配置写入及回滚失败，请使用安装前备份恢复。") }
            throw error
        }
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func installProvider(binary: String, homeDirectory: URL, directory: URL) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["install", PiAgentSupport.package]
            process.currentDirectoryURL = homeDirectory
            var environment = PiAgentInstallation(homeDirectory: homeDirectory.path,
                environment: ProcessInfo.processInfo.environment).processEnvironment(binaryPath: binary)
            environment["HOME"] = homeDirectory.path
            environment["PI_CODING_AGENT_DIR"] = directory.path
            environment["CI"] = "1"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // 不经 shell 执行，不把连接密钥传入命令行，也不收集可能含敏感信息的安装输出。
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180, execute: timeout)
            defer { timeout.cancel() }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PiAgentSupport.failure("Pi 官方插件安装失败或超时（退出码 \(process.terminationStatus)）。请检查 npm 网络连接，或切换手动配置执行安装命令。")
            }
        }.value
    }
}
