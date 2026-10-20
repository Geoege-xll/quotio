//
//  AgentConfigurationService.swift
//  Quotio - Generate agent configurations
//

import Foundation

/// 单次受管目录提交的同步许可，生命周期仍由原 AgentSetupViewModel 持有。
/// actor 调用排队后仍能被主线程同步失效；检查与本地提交使用同一把锁，
/// 不能先检查 Bool、释放锁后再写盘。锁内没有网络或 await，不新增任务或业务状态宿主。
nonisolated final class ClaudeCatalogCommitAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isValid = true

    func invalidate() { lock.withLock { isValid = false } }

    func withPermission<T>(_ body: () -> T) -> T? {
        lock.withLock {
            guard isValid, !Task.isCancelled else { return nil }
            return body()
        }
    }
}

actor AgentConfigurationService {
    private let fileManager = FileManager.default
    private let homeDirectory: URL
    /// 原 actor 仍唯一负责文件事务；所有 Claude 操作共享初始化时解析的同一个目标目录。
    private let claudeLocation: ClaudeConfigurationLocation
    private let trashBackup: @Sendable (URL) throws -> Void
    private let writeConfigurationData: @Sendable (Data, URL) throws -> Void
    private let fetchPiModels: @Sendable (String, String) async throws -> [AvailableModel]
    /// Pi 查证与安装会让 actor 可重入；互斥仍归原配置服务，不新增持有 Task 的队列或单例。
    /// 已开始的文件事务完整完成，新页面的第二次自动写入／恢复必须稍后重试，避免旧事务覆盖新文件。
    private var isConfiguringPi = false

    /// 允许测试注入临时用户目录，覆盖真实的读取、备份和重新配置流程，避免触碰用户凭据。
    /// 正常启动仍使用系统用户目录，现有调用方无需传入额外参数。
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fetchPiModels: @escaping @Sendable (String, String) async throws -> [AvailableModel] = { url, key in
            try await AgentModelCatalogService.fetchAvailableModels(proxyURL: url, apiKey: key)
        },
        writeConfigurationData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        trashBackup: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        claudeConfigDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.homeDirectory = homeDirectory
        // 测试显式传入临时 home 时不继承本机目录覆盖，避免离线回归误写真实配置。
        // 生产默认 home 继续使用实际进程环境；调用者也可明确注入整个位置契约。
        let inherited = environment ?? (homeDirectory == FileManager.default.homeDirectoryForCurrentUser
            ? ProcessInfo.processInfo.environment : [:])
        self.claudeLocation = ClaudeConfigurationLocation(homeDirectory: homeDirectory,
            directory: claudeConfigDirectory, environment: inherited)
        self.fetchPiModels = fetchPiModels
        self.trashBackup = trashBackup
        self.writeConfigurationData = writeConfigurationData
    }
    
    // MARK: - Saved Configuration Models
    
    /// Represents the currently saved configuration for an agent
    struct SavedAgentConfig: Sendable {
        let baseURL: String?
        let apiKey: String?
        let modelSlots: [ModelSlot: String]
        let isProxyConfigured: Bool
        let backupFiles: [BackupFile]
        /// Reasoning effort read from Codex CLI's `model_reasoning_effort` (Codex only).
        var reasoningEffort: CodexReasoningEffort? = nil
        /// Claude 启动模型与三档别名映射分别回填，避免重新配置时强制切回 Opus。
        var defaultModel: String? = nil
        var claudeDefaultModel1M = false
        /// 仅保存自定义名称；旧自动 ID 名称归一为空，由表单和生成器统一回退到角色名。
        var modelDisplayNames: [ModelSlot: String] = [:]
        var modelPlatformHints: [String: String] = [:]
        /// Claude Code 高级设置只在 Claude 配置读取路径回填；其他代理保留安全默认值。
        var claudeMaxContextTokens = AgentConfiguration.defaultClaudeMaxContextTokens
        var claudeAutoCompactPercentage = AgentConfiguration.defaultClaudeAutoCompactPercentage
        var claudeDisableAutoCompact = false
        var claudeModel1M: [ModelSlot: Bool] = [:]
        var claudeGatewayModelDiscovery = false
        var claudeModelPicker = ClaudeModelPickerConfiguration.roleDefaults(mode: .native)
        var claudeSubagentModel: String? = nil
        /// 与模型值分开回读，保留外部强制覆盖的原始值及只开启 FORCE 的合法配置。
        var claudeSubagentModelForce: String? = nil
        /// 只读模型引用快照用于同一份兼容性预览；最终保存仍重新读取磁盘，不持有凭据副本。
        var claudeLegacyModelReferences = ClaudeLegacyModelReferences()
    }
    
    /// Represents a backup file that can be restored
    struct BackupFile: Identifiable, Sendable {
        let path: String
        let timestamp: Date
        let agent: CLIAgent
        
        var id: String { path }
        
        // Use static formatter for performance
        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
        
        var displayName: String {
            Self.dateFormatter.string(from: timestamp)
        }
    }
    
    // MARK: - Read Existing Configuration

    /// 已保存路径是事务输入，不能在备份／恢复时重新回到旧的静态默认目录。
    /// 其他客户端继续沿用原配置路径，Claude 统一采用显式或环境覆盖后的实际位置。
    private func configurationPaths(for agent: CLIAgent) -> [String] {
        if agent == .claudeCode { return [claudeLocation.settings.path] }
        return agent.configPaths.map { $0.replacingOccurrences(of: "~", with: homeDirectory.path) }
    }
    
    /// Read the current saved configuration for an agent
    func readConfiguration(agent: CLIAgent) -> SavedAgentConfig? {
        switch agent {
        case .pi:
            return PiAgentSupport.readSavedConfiguration(homeDirectory: homeDirectory, backups: listBackups(agent: agent))
        case .claudeCode:
            return readClaudeCodeConfig()
        case .codexCLI:
            return readCodexConfig()
        case .ampCLI:
            return readAmpConfig()
        case .openCode:
            return readOpenCodeConfig()
        case .factoryDroid:
            return readFactoryDroidConfig()
        }
    }
    
    /// List available backup files for an agent
    func listBackups(agent: CLIAgent) -> [BackupFile] {
        var backups: [BackupFile] = []
        
        for expandedPath in configurationPaths(for: agent) {
            let directory = (expandedPath as NSString).deletingLastPathComponent
            let filename = (expandedPath as NSString).lastPathComponent
            
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            
            for file in contents {
                if file.hasPrefix(filename + ".backup.") {
                    let fullPath = "\(directory)/\(file)"
                    // Extract timestamp from filename (e.g., settings.json.backup.1736840000)
                    if let timestampStr = file.components(separatedBy: ".backup.").last,
                       let timestamp = Double(timestampStr), timestamp.isFinite, timestamp >= 0 {
                        let date = Date(timeIntervalSince1970: timestamp)
                        backups.append(BackupFile(path: fullPath, timestamp: date, agent: agent))
                    }
                }
            }
        }
        
        // Sort by most recent first
        return backups.sorted { $0.timestamp > $1.timestamp }
    }
    
    /// 只允许删除该代理配置目录中实际列出的普通备份文件，拒绝伪造路径和符号链接。
    /// 使用系统废纸篓提供恢复能力；注入操作让测试无需改动真实废纸篓。
    func deleteBackup(_ backup: BackupFile) throws {
        let url = URL(fileURLWithPath: backup.path)
        guard listBackups(agent: backup.agent).contains(where: { $0.path == backup.path }),
              try fileManager.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType == .typeRegular,
              try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw BackupDeletionError.invalidBackup
        }
        try trashBackup(url)
    }

    enum BackupDeletionError: LocalizedError {
        case invalidBackup

        var errorDescription: String? {
            "agents.backups.invalidBackup".localizedStatic()
        }
    }

    /// Restore configuration from a backup file
    func restoreFromBackup(_ backup: BackupFile) throws {
        // 恢复也会写 Pi 的两份配置之一，不能与同服务内尚未完成的自动保存交错。
        if backup.agent == .pi, isConfiguringPi {
            throw PiAgentSupport.failure("agents.pi.configurationInProgress".localizedStatic())
        }
        // 恢复只能使用原目录中实际列出的普通备份；先读、成功备份当前文件，再原子替换。
        // 任何备份／写入失败都保留当前配置，不能先删除文件，更不能忽略备份失败。
        guard listBackups(agent: backup.agent).contains(where: { $0.path == backup.path }),
              try fileManager.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType == .typeRegular,
              let originalPath = configurationPaths(for: backup.agent)
                .first(where: { backup.path.hasPrefix($0 + ".backup.") }) else { throw BackupDeletionError.invalidBackup }
        let data = try Data(contentsOf: URL(fileURLWithPath: backup.path))
        let before = try currentFileData(originalPath)
        _ = try backupIfPresent(originalPath)
        try replaceConfiguration(data, path: originalPath, expected: before)

    }
    
    // MARK: - Agent-Specific Read Implementations
    
    /// `[1m]` is a Claude Code model selector suffix, not part of Quotio's stored
    /// model ID. Strip exactly one terminal suffix so malformed IDs are not rewritten
    /// into a different request on read.
    private func normalizedClaudeModelID(_ value: String) -> (base: String, uses1M: Bool) {
        AgentConfiguration.normalizedClaudeModelID(value)
    }

    /// 回填与保存冲突核对共用整数语义，兼容旧串的前导零／正号与外部 JSON 整数。
    /// 不接受布尔或小数，不能把 true 当成 1 令牌；此规则只解析显式值，不推断模型容量。
    private func claudeContextTokens(from value: Any?) -> Int? {
        let parsed = (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? (value as? NSNumber).flatMap { number in
                CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : Int(number.stringValue)
            }
        return parsed.flatMap { $0 > 0 ? $0 : nil }
    }

    private func readClaudeCodeConfig() -> SavedAgentConfig? {
        let configPath = claudeLocation.settings.path
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // 仅投影当前支持的字符串值，不因一个未来扩展字段而丢弃其他有效的模型和连接配置。
        let env = (json["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        
        let baseURL = env["ANTHROPIC_BASE_URL"]
        let apiKey = env["ANTHROPIC_AUTH_TOKEN"]
        let projection = ClaudeCatalogProjection.read(in: json)

        var modelSlots: [ModelSlot: String] = [:]
        var claudeModel1M: [ModelSlot: Bool] = [:]
        for slot in ModelSlot.allCases {
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            guard let requestModel = env[key] else { continue }
            let normalized = normalizedClaudeModelID(requestModel)
            modelSlots[slot] = normalized.base
            if normalized.uses1M, projection?.isAutomaticContext(slot.rawValue, selector: requestModel) != true {
                claudeModel1M[slot] = true
            } else if !normalized.uses1M, projection?.isExplicitNormalContext(slot, selector: requestModel) == true {
                claudeModel1M[slot] = false
            }
        }

        let configuredDefaultModel = env["ANTHROPIC_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (json["model"] as? String)
            ?? env["ANTHROPIC_DEFAULT_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
        let defaultModel: String?
        let defaultModel1M: Bool
        if let configuredDefaultModel {
            let normalized = normalizedClaudeModelID(configuredDefaultModel)
            // 实际 ID 与角色映射相同也不能判为继承；默认行的后缀独立回填。
            // 外部 CLI 保存的角色[1m] 是显式选择器，保留原生语义而不修改角色本身。
            defaultModel = normalized.uses1M && ModelSlot(rawValue: normalized.base) != nil
                ? normalized.base + "[1m]" : normalized.base
            defaultModel1M = normalized.uses1M
                && projection?.isAutomaticContext("default", selector: configuredDefaultModel) != true
        } else {
            defaultModel = nil
            defaultModel1M = false
        }

        let rawContext = (json["env"] as? [String: Any])?["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]
        let claudeMaxContextTokens = claudeContextTokens(from: rawContext)
        let parsedCompactPercentage = env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"].flatMap(Int.init)
        let claudeAutoCompactPercentage = parsedCompactPercentage.flatMap { (1...100).contains($0) ? $0 : nil }
            ?? AgentConfiguration.defaultClaudeAutoCompactPercentage

        // 已保存来源包括隧道、局域网和远端 CPA，只有明确官方端点才回到官方模式。
        let isProxy = ClaudeConfigurationSource.isProxyEndpoint(baseURL)

        let displayNames = Dictionary(uniqueKeysWithValues: ModelSlot.allCases.compactMap { slot -> (ModelSlot, String)? in
            let modelID = modelSlots[slot] ?? AvailableModel.defaultModels[slot]?.name ?? ""
            guard let name = AgentConfiguration.normalizedClaudeDisplayName(
                env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL_NAME"], for: slot, modelID: modelID) else { return nil }
            return (slot, name)
        })
        var picker = ClaudeCatalogOwnership.picker(in: json)
        if let projection { picker = projection.restoringMenu(picker) }
        // 页面已经移除菜单编辑入口，回填的菜单仅用于兼容与预览，不主动取得写入权限。
        // 即使是旧版 Quotio 创建的菜单，也保留原顺序、标题、说明和未知字段；
        // 不能把已有文本清空成“自动名称”，否则保存模型槽时会意外重新生成旧菜单。
        picker.shouldWrite = false

        // 多个角色可引用同一模型；已有说明给出不同平台时，不按遍历顺序任选一个。
        var platformsByModel: [String: Set<String>] = [:]
        for (slot, model) in modelSlots {
            if let platform = ClaudeModelPresentation.platformHint(model: model,
                description: env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL_DESCRIPTION"]) {
                platformsByModel[model, default: []].insert(platform)
            }
        }
        let platformHints = platformsByModel.compactMapValues { $0.count == 1 ? $0.first : nil }

        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: modelSlots,
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .claudeCode),
            defaultModel: defaultModel,
            claudeDefaultModel1M: defaultModel1M,
            modelDisplayNames: displayNames,
            modelPlatformHints: platformHints,
            claudeMaxContextTokens: claudeMaxContextTokens,
            claudeAutoCompactPercentage: claudeAutoCompactPercentage,
            claudeDisableAutoCompact: env["DISABLE_AUTO_COMPACT"] == "1",
            claudeModel1M: claudeModel1M,
            claudeGatewayModelDiscovery: ["1", "true"].contains(
                env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"]?.lowercased() ?? ""
            ),
            claudeModelPicker: picker,
            claudeSubagentModel: env["CLAUDE_CODE_SUBAGENT_MODEL"].flatMap { value in
                guard !value.isEmpty else { return nil }
                return projection?.isAutomaticContext("subagent", selector: value) == true
                    ? ClaudeModelReference(value).base : value
            },
            claudeSubagentModelForce: env["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"],
            claudeLegacyModelReferences: .read(json)
        )
    }
    
    private func readCodexConfig() -> SavedAgentConfig? {
        let home = homeDirectory.path
        let configPath = "\(home)/.codex/config.toml"
        
        guard fileManager.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        
        // 借鉴 cc-switch 的分层读取：只取顶层模型与服务商，不能被 profiles/MCP 表覆盖。
        // 复用已有的 TOML 扫描器，跳过注释和多行字符串，并支持引号键与行尾注释。
        let model = parseCodexTOMLString(from: content, key: "model")
        let provider = parseCodexTOMLString(from: content, key: "model_provider")
        let reasoningEffort = parseTopLevelCodexReasoningEffort(from: content)
        let baseURL = provider.flatMap { provider in
            parseCodexTOMLString(from: content, key: "base_url", section: ["model_providers", provider])
        }
        let host = baseURL.flatMap { URL(string: $0)?.host }
        let isProxy = provider == "cliproxyapi" || host == "127.0.0.1" || host == "localhost"

        var modelSlots: [ModelSlot: String] = [:]
        if let m = model {
            modelSlots[.sonnet] = m  // Codex uses single model
        }
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: nil,  // API key is in auth.json
            modelSlots: modelSlots,
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .codexCLI),
            reasoningEffort: reasoningEffort
        )
    }
    
    private func readAmpConfig() -> SavedAgentConfig? {
        let home = homeDirectory.path
        let settingsPath = "\(home)/.config/amp/settings.json"
        
        guard fileManager.fileExists(atPath: settingsPath),
              let data = fileManager.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let baseURL = json["amp.url"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: nil,  // API key is in secrets.json
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .ampCLI)
        )
    }
    
    private func readOpenCodeConfig() -> SavedAgentConfig? {
        let home = homeDirectory.path
        let configPath = "\(home)/.config/opencode/opencode.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? OpenCodeConfigEditor.parseObject(data) else {
            return nil
        }

        // Check for quotio provider
        guard let providers = json["provider"] as? [String: Any],
              let quotioProvider = providers["quotio"] as? [String: Any],
              let options = quotioProvider["options"] as? [String: Any] else {
            return SavedAgentConfig(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: listBackups(agent: .openCode)
            )
        }
        
        let baseURL = options["baseURL"] as? String
        let apiKey = options["apiKey"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .openCode)
        )
    }
    
    private func readFactoryDroidConfig() -> SavedAgentConfig? {
        let home = homeDirectory.path
        let configPath = "\(home)/.factory/config.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        guard let customModels = json["custom_models"] as? [[String: Any]],
              let firstModel = customModels.first else {
            return SavedAgentConfig(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: listBackups(agent: .factoryDroid)
            )
        }
        
        let baseURL = firstModel["base_url"] as? String
        let apiKey = firstModel["api_key"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .factoryDroid)
        )
    }
    
    // MARK: - Helper Functions
    
    private func extractTOMLValue(from line: String) -> String? {
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let valueStart = line.index(after: equalIndex)
        var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    
    private func extractExportValue(from line: String) -> String? {
        // Handle: export VAR="value" or export VAR=value
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let valueStart = line.index(after: equalIndex)
        var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// Escape a value for use in a TOML basic string.
    /// Handles quotes, backslashes, and ASCII control characters.
    private func escapeTOMLString(_ value: String) -> String {
        var escaped = ""

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x00...0x1F, 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return escaped
    }

    func buildManagedCodexTOML(
        model: String,
        proxyURL: String,
        reasoningEffort: CodexReasoningEffort = .defaultEffort
    ) -> String {
        let escapedModel = escapeTOMLString(model)
        let escapedProxyURL = escapeTOMLString(proxyURL)
        // A `custom` effort carries a literal value read from the user's file.
        let escapedReasoningEffort = escapeTOMLString(reasoningEffort.rawValue)

        return """
        # CLIProxyAPI Configuration for Codex CLI
        model_provider = "cliproxyapi"
        model = "\(escapedModel)"
        model_reasoning_effort = "\(escapedReasoningEffort)"

        [model_providers.cliproxyapi]
        name = "cliproxyapi"
        base_url = "\(escapedProxyURL)"
        wire_api = "responses"
        """
    }

    private func parseTOMLSectionName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }

        if trimmed.hasPrefix("[[") {
            guard let closeRange = trimmed.range(of: "]]") else { return nil }
            let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let section = String(trimmed[start..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            return section.isEmpty ? nil : section
        }

        guard let closeIndex = trimmed.firstIndex(of: "]") else { return nil }
        let start = trimmed.index(after: trimmed.startIndex)
        guard start <= closeIndex else { return nil }
        let section = String(trimmed[start..<closeIndex]).trimmingCharacters(in: .whitespaces)
        return section.isEmpty ? nil : section
    }

    private func isCodexManagedTopLevelKey(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equalIndex = trimmed.firstIndex(of: "=") else { return false }
        let key = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return key == "model_provider" || key == "model" || key == "model_reasoning_effort"
    }

    /// Tracks TOML multi-line string state (`"""` / `'''`) across a line-by-line
    /// scan so that text inside a string body is never mistaken for a table
    /// header or a key/value pair.
    private struct CodexTOMLScanner {
        /// Quote character of the multi-line string currently open, or `nil`
        /// when the scanner is at TOML structure level.
        private var openMultilineQuote: Character?

        /// Feeds one line to the scanner.
        /// - Returns: `true` when the line is TOML structure, `false` when it is
        ///   part of a multi-line string body (including its closing delimiter).
        mutating func isStructuralLine(_ line: String) -> Bool {
            let characters = Array(line)
            let startedInsideMultiline = openMultilineQuote != nil
            var index = 0

            while index < characters.count {
                let character = characters[index]

                if let quote = openMultilineQuote {
                    if character == quote, Self.isTriple(characters, at: index, quote: quote) {
                        openMultilineQuote = nil
                        index += 3
                    } else {
                        index += 1
                    }
                    continue
                }

                switch character {
                case "#":
                    // A comment runs to the end of the line.
                    index = characters.count
                case "\"", "'":
                    if Self.isTriple(characters, at: index, quote: character) {
                        openMultilineQuote = character
                        index += 3
                    } else {
                        index = Self.endOfSingleLineString(characters, from: index, quote: character)
                    }
                default:
                    index += 1
                }
            }

            return !startedInsideMultiline
        }

        private static func isTriple(_ characters: [Character], at index: Int, quote: Character) -> Bool {
            guard index + 2 < characters.count else { return false }
            return characters[index + 1] == quote && characters[index + 2] == quote
        }

        private static func endOfSingleLineString(
            _ characters: [Character],
            from index: Int,
            quote: Character
        ) -> Int {
            var cursor = index + 1
            while cursor < characters.count {
                let character = characters[cursor]
                // Literal strings ('...') do not support escapes.
                if quote == "\"", character == "\\" {
                    cursor += 2
                    continue
                }
                if character == quote {
                    return cursor + 1
                }
                cursor += 1
            }
            return characters.count
        }
    }

    /// Reads the **top-level** `model_reasoning_effort` from a Codex `config.toml`.
    ///
    /// `model_reasoning_effort` is a top-level key, but the same key is also legal
    /// under `[profiles.*]` and other tables. Table headers are tracked so a
    /// profile's value is never reported as — and then used to overwrite — the
    /// top-level setting. Returns `nil` when the top-level key is absent, so the
    /// caller keeps its default.
    func parseTopLevelCodexReasoningEffort(from content: String) -> CodexReasoningEffort? {
        parseCodexTOMLString(from: content, key: "model_reasoning_effort")
            .flatMap(CodexReasoningEffort.init(rawValue:))
    }

    /// 读取指定表中的标量字符串；section 为 nil 时仅匹配顶层。
    /// 表头后的键始终属于该表，数组表和多行字符串里的伪 model 键不会污染顶层配置。
    private func parseCodexTOMLString(from content: String, key: String, section: [String]? = nil) -> String? {
        var scanner = CodexTOMLScanner()
        var currentSection: [String]?
        for line in content.components(separatedBy: .newlines) {
            guard scanner.isStructuralLine(line) else { continue }
            if let name = parseTOMLSectionName(from: line) {
                // 无法识别的表也已结束顶层区域，不能用 nil 将其误当成顶层。
                currentSection = parseCodexTOMLTablePath(name) ?? []
                continue
            }
            guard currentSection == section else { continue }
            if let value = extractCodexTOMLStringValue(from: line, key: key) {
                return value
            }
        }
        return nil
    }

    /// 按 TOML 键路径拆分表头，引号内的点属于服务商 ID，而不是表层级分隔符。
    /// 例如 [model_providers."local.proxy"] 应匹配顶层 model_provider = "local.proxy"。
    private func parseCodexTOMLTablePath(_ name: String) -> [String]? {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        for character in name {
            if let activeQuote = quote {
                token.append(character)
                if escaped {
                    escaped = false
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                token.append(character)
            } else if character == "." {
                tokens.append(token)
                token = ""
            } else {
                token.append(character)
            }
        }
        guard quote == nil else { return nil }
        tokens.append(token)
        let path = tokens.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : parseCodexTOMLScalarString(value)
        }
        return path.count == tokens.count ? path : nil
    }

    /// Reads the value of a TOML assignment to `key`, tolerating quoted keys,
    /// literal strings and trailing comments. Returns `nil` unless the line is
    /// an assignment to exactly `key` with a value this parser can round-trip.
    private func extractCodexTOMLStringValue(from line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equalIndex = trimmed.firstIndex(of: "=") else { return nil }

        var lineKey = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
        if lineKey.count >= 2, let first = lineKey.first, lineKey.last == first, first == "\"" || first == "'" {
            lineKey = String(lineKey.dropFirst().dropLast())
        }
        guard lineKey == key else { return nil }

        let value = String(trimmed[trimmed.index(after: equalIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return parseCodexTOMLScalarString(value)
    }

    private func parseCodexTOMLScalarString(_ value: String) -> String? {
        let characters = Array(value)
        guard let first = characters.first else { return nil }

        // Multi-line strings are not a value Quotio can safely round-trip.
        if characters.count >= 3, characters[1] == first, characters[2] == first,
           first == "\"" || first == "'" {
            return nil
        }

        if first == "\"" {
            var result = ""
            var index = 1
            while index < characters.count {
                let character = characters[index]
                if character == "\\" {
                    index += 1
                    guard index < characters.count else { return nil }
                    switch characters[index] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    // Don't guess at \u / \b / \f — leave the value untouched.
                    default: return nil
                    }
                    index += 1
                    continue
                }
                if character == "\"" {
                    return result.isEmpty ? nil : result
                }
                result.append(character)
                index += 1
            }
            return nil  // Unterminated string.
        }

        if first == "'" {
            guard let closingIndex = value.dropFirst().firstIndex(of: "'") else { return nil }
            let literal = String(value[value.index(after: value.startIndex)..<closingIndex])
            return literal.isEmpty ? nil : literal
        }

        // Bare value: invalid TOML for a string, but read it leniently rather
        // than discarding what the user wrote.
        let bare = value
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? nil : bare
    }

    private typealias ManagedCodexConfigParts = (topLevel: [String], section: [String])

    private func splitManagedCodexConfig(_ managedConfig: String) -> ManagedCodexConfigParts {
        let lines = managedConfig.components(separatedBy: .newlines)
        guard let sectionStart = lines.firstIndex(where: { parseTOMLSectionName(from: $0) != nil }) else {
            return (lines, [])
        }
        return (Array(lines[..<sectionStart]), Array(lines[sectionStart...]))
    }

    private func extractManagedCodexBanner(from managedConfig: String) -> String? {
        for line in managedConfig.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return trimmed.hasPrefix("#") ? trimmed : nil
        }
        return nil
    }

    private func filterExistingCodexLines(existingContent: String, managedBanner: String?) -> [String] {
        let lines = existingContent.components(separatedBy: .newlines)
        var filteredLines: [String] = []
        var skippingCliproxySection = false
        var hasSeenAnySection = false
        var scanner = CodexTOMLScanner()

        for line in lines {
            // Lines inside a multi-line string body are content, never structure.
            let isStructural = scanner.isStructuralLine(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isStructural, let sectionName = parseTOMLSectionName(from: trimmed) {
                let cliproxySection = "model_providers.cliproxyapi"
                if sectionName == cliproxySection || sectionName.hasPrefix(cliproxySection + ".") {
                    skippingCliproxySection = true
                    continue
                }
                skippingCliproxySection = false
                hasSeenAnySection = true
            }

            if skippingCliproxySection {
                continue
            }

            if let managedBanner, isStructural, !hasSeenAnySection && trimmed == managedBanner {
                continue
            }

            if isStructural, !hasSeenAnySection && isCodexManagedTopLevelKey(trimmed) {
                continue
            }

            filteredLines.append(line)
        }

        while filteredLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            filteredLines.removeLast()
        }

        return filteredLines
    }

    private func composeMergedCodexConfig(filteredLines: [String], managedParts: ManagedCodexConfigParts) -> String {
        var firstSectionIndex = filteredLines.count
        var scanner = CodexTOMLScanner()
        for (index, line) in filteredLines.enumerated() {
            guard scanner.isStructuralLine(line) else { continue }
            if parseTOMLSectionName(from: line) != nil {
                firstSectionIndex = index
                break
            }
        }

        var topLevelLines = Array(filteredLines[..<firstSectionIndex])
        let remainingSections = Array(filteredLines[firstSectionIndex...])

        while topLevelLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            topLevelLines.removeLast()
        }

        var leadingHeaderIndex = 0
        while leadingHeaderIndex < topLevelLines.count {
            let trimmed = topLevelLines[leadingHeaderIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                leadingHeaderIndex += 1
            } else {
                break
            }
        }

        var leadingHeader = Array(topLevelLines[..<leadingHeaderIndex])
        var userTopLevel = Array(topLevelLines[leadingHeaderIndex...])

        while leadingHeader.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            leadingHeader.removeLast()
        }

        while userTopLevel.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            userTopLevel.removeFirst()
        }
        while userTopLevel.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            userTopLevel.removeLast()
        }

        var merged: [String] = []
        if !leadingHeader.isEmpty {
            merged.append(contentsOf: leadingHeader)
        }

        if !merged.isEmpty && merged.last?.isEmpty == false {
            merged.append("")
        }
        merged.append(contentsOf: managedParts.topLevel)

        if !userTopLevel.isEmpty {
            if merged.last?.isEmpty == false {
                merged.append("")
            }
            merged.append(contentsOf: userTopLevel)
        }

        if merged.last?.isEmpty == false {
            merged.append("")
        }
        merged.append(contentsOf: managedParts.section)

        if !remainingSections.isEmpty {
            if merged.last?.isEmpty == false {
                merged.append("")
            }
            merged.append(contentsOf: remainingSections)
        }

        return merged
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func mergeCodexConfig(existingContent: String, managedConfig: String) -> String {
        let managedBanner = extractManagedCodexBanner(from: managedConfig)
        let managedParts = splitManagedCodexConfig(managedConfig)
        let filteredLines = filterExistingCodexLines(existingContent: existingContent, managedBanner: managedBanner)
        return composeMergedCodexConfig(filteredLines: filteredLines, managedParts: managedParts)
    }
    
    func generateConfiguration(
        agent: CLIAgent,
        config: AgentConfiguration,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption = .jsonOnly,
        detectionService: AgentDetectionService,
        availableModels: [AvailableModel] = [],
        shell: ShellType = .zsh
    ) async throws -> AgentConfigResult {
        
        // UI 与直接生成调用共享保存屏障：缺客户端密钥时禁止写入空认证，
        // 检查在任何 Pi 安装、备份或文件修改之前执行；恢复非代理模式仍允许空 key。
        if config.setupMode == .proxy, config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(error: "agents.models.clientKeyRequired".localizedStatic())
        }

        // Pi 使用官方独立 provider 插件，代理与默认模式均交给同一服务处理。
        if agent == .pi {
            if mode == .automatic {
                guard !isConfiguringPi else {
                    return .failure(error: "agents.pi.configurationInProgress".localizedStatic())
                }
                isConfiguringPi = true
            }
            defer { if mode == .automatic { isConfiguringPi = false } }
            return try await PiAgentConfigurationService(homeDirectory: homeDirectory, fetchModels: fetchPiModels).generate(
                config: config, mode: mode, detectionService: detectionService
            )
        }

        // Check if we should generate default (non-proxy) configuration
        if config.setupMode == .defaultSetup {
            return try await generateDefaultConfiguration(agent: agent, mode: mode, shell: shell)
        }

        switch agent {
        case .pi:
            // 入口已统一分发 Pi，保留显式分支避免新增智能体后遗漏枚举处理。
            return .failure(error: "Pi configuration must use the dedicated provider service.")
        case .claudeCode:
            return generateClaudeCodeConfig(config: config, mode: mode, storageOption: storageOption,
                                           availableModels: availableModels, shell: shell)

        case .codexCLI:
            return try await generateCodexConfig(config: config, mode: mode)

        case .ampCLI:
            return try await generateAmpConfig(config: config, mode: mode)

        case .openCode:
            return generateOpenCodeConfig(config: config, mode: mode, availableModels: availableModels)

        case .factoryDroid:
            return generateFactoryDroidConfig(config: config, mode: mode, availableModels: availableModels)
        }
    }
    
    // MARK: - Generate Default (Non-Proxy) Configuration
    
    /// Generates configuration that removes Quotio proxy settings while preserving user settings
    private func generateDefaultConfiguration(agent: CLIAgent, mode: ConfigurationMode, shell: ShellType = .zsh) async throws -> AgentConfigResult {
        switch agent {
        case .pi:
            // 入口已统一分发 Pi，保留显式分支避免新增智能体后遗漏枚举处理。
            return .failure(error: "Pi configuration must use the dedicated provider service.")
        case .claudeCode:
            return generateClaudeCodeDefaultConfig(mode: mode, shell: shell)
        case .codexCLI:
            return generateCodexDefaultConfig(mode: mode)
        case .ampCLI:
            return generateAmpDefaultConfig(mode: mode)
        case .openCode:
            return generateOpenCodeDefaultConfig(mode: mode)
        case .factoryDroid:
            return generateFactoryDroidDefaultConfig(mode: mode)
        }
    }
    
    /// 官方恢复也是一份完整目标：按同一严格快照撤下已知配置，并返回受管 Shell 的清理动作。
    /// 不按 env 的整体字符串类型决定能否清理，未知根字段和任意 env 扩展值原样保留。
    private func generateClaudeCodeDefaultConfig(mode: ConfigurationMode, shell: ShellType = .zsh) -> AgentConfigResult {
        do {
            let snapshot = try readClaudeSettingsSnapshot()
            var settings = snapshot.object
            let oldEnv = settings["env"] as? [String: Any] ?? [:]
            let legacyMenuOwned = settings[ClaudeCatalogOwnership.rootKey] == nil
                && (settings["modelPicker"] as? [String: Any])?["quotioManaged"] as? Bool == true
            let menuOwned = ClaudeCatalogOwnership.source(in: settings) != nil || legacyMenuOwned
            var managedModels = (["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_MODEL"]
                + ModelSlot.allCases.map { "ANTHROPIC_DEFAULT_" + $0.envSuffix + "_MODEL" })
                .compactMap { oldEnv[$0] as? String }
            if menuOwned {
                // /model 可以把追加菜单的具体型号保存为默认，它未必出现在任何角色槽。
                // 删除菜单前保留其归属证据，避免恢复官方后继续向官方发送该代理专用型号。
                managedModels += ((settings["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]] ?? [])
                    .compactMap { $0["model"] as? String }
            }
            let ownedWireIDs = Set(managedModels.compactMap { ClaudeModelReference($0).wireModelID })
            if menuOwned {
                // 撤下受管菜单的已知行为字段；未知菜单扩展继续留在原位置，完整旧行另有原字节备份。
                if var picker = settings["modelPicker"] as? [String: Any] {
                    for field in ["options", "replaceBuiltInOptions"] + ClaudeCatalogOwnership.legacyKeys {
                        picker.removeValue(forKey: field)
                    }
                    if picker.isEmpty { settings.removeValue(forKey: "modelPicker") }
                    else { settings["modelPicker"] = picker }
                }
            }
            settings = ClaudeCatalogOwnership.removingKnownFields(in: settings)
            var env = oldEnv
            for key in ClaudeManagedEnvironment.keys { env.removeValue(forKey: key) }
            if env.isEmpty { settings.removeValue(forKey: "env") } else { settings["env"] = env }
            if let model = settings["model"] as? String {
                let role = ModelSlot(rawValue: normalizedClaudeModelID(model).base)
                let mappedRole = role.map { oldEnv["ANTHROPIC_DEFAULT_" + $0.envSuffix + "_MODEL"] != nil } ?? false
                let wireOwned = ClaudeModelReference(model).wireModelID.map { ownedWireIDs.contains($0) } ?? false
                if wireOwned || mappedRole { settings.removeValue(forKey: "model") }
            }
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let path = claudeLocation.settings.path
            if mode == .automatic {
                var result = AgentConfigResult.success(type: .file, mode: mode,
                    configPath: snapshot.data == nil ? nil : path,
                    instructions: "agents.claude.official.restored".localizedStatic(), modelsConfigured: 0)
                if snapshot.data != nil {
                    let committed = try commitClaudeSettings(data, expected: snapshot.data)
                    result.backupPath = committed.backupPath
                    result.claudeRollback = committed.receipt
                }
                // 即使原 JSON 不存在，历史仅 Shell 配置也必须被撤下；不能把没有文件当作恢复完成。
                result.claudeShellAction = .remove
                return result
            }
            let instructions = String(format: "agents.claude.official.manual".localizedStatic(), path, shell.profilePath)
            return .success(type: .file, mode: mode, rawConfigs: [
                .init(format: .json, content: String(decoding: data, as: UTF8.self), filename: "settings.json",
                      targetPath: path, instructions: instructions)
            ], instructions: instructions, modelsConfigured: 0)
        } catch {
            return .failure(error: error.localizedDescription)
        }
    }
    
    private func generateCodexDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = homeDirectory.path
        let configPath = "\(home)/.codex/config.toml"
        let authPath = "\(home)/.codex/auth.json"

        // config.toml and auth.json are cleaned independently: either file can be
        // missing while the other still carries Quotio's managed entries, so
        // nesting the auth.json cleanup inside the config.toml branch left the
        // managed key behind and still reported success.
        if mode == .automatic {
            do {
                var cleanedConfig = false
                if fileManager.fileExists(atPath: configPath) {
                    let content = try String(contentsOfFile: configPath, encoding: .utf8)

                    // Collision-safe backup, same helper as every other managed file.
                    _ = try backupIfPresent(configPath)

                    // Reuse the same TOML-aware filtering used by merge path,
                    // including managed banner removal.
                    let stubManagedConfig = buildManagedCodexTOML(model: "", proxyURL: "")
                    let managedBanner = extractManagedCodexBanner(from: stubManagedConfig)
                    let filteredLines = filterExistingCodexLines(existingContent: content, managedBanner: managedBanner)
                    let newContent = filteredLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                    try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                    cleanedConfig = true
                }

                // Removes only a "quotio-" prefixed OPENAI_API_KEY, so a user's
                // own key and their native credentials are never touched.
                let cleanedAuth = try revertCodexAuthJSON(at: authPath)

                if cleanedConfig || cleanedAuth {
                    return .success(
                        type: .file,
                        mode: mode,
                        configPath: cleanedConfig ? configPath : nil,
                        authPath: nil,
                        shellConfig: nil,
                        rawConfigs: [],
                        instructions: "Removed CLIProxyAPI configuration. Codex CLI will now use OpenAI API directly.",
                        modelsConfigured: 0
                    )
                }
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }

        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "agents.codex.revertManualInstructions".localizedStatic(),
            modelsConfigured: 0
        )
    }
    
    private func generateAmpDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = homeDirectory.path
        let settingsPath = "\(home)/.config/amp/settings.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: settingsPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
                var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(settingsPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: settingsPath, toPath: backupPath)
                
                // Remove amp.url
                settings.removeValue(forKey: "amp.url")
                
                let updatedData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: settingsPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: settingsPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed proxy URL. Amp CLI will now use its default endpoint.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update settings: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove 'amp.url' from ~/.config/amp/settings.json",
            modelsConfigured: 0
        )
    }
    
    private func generateOpenCodeDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = homeDirectory.path
        let configPath = "\(home)/.config/opencode/opencode.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))

                // Remove only the Quotio-managed provider entry, preserving
                // every other user setting — comments included (#176). When
                // there is nothing to remove, leave the file untouched.
                guard let updatedData = try OpenCodeConfigEditor.removingProviders(existing: data, keys: ["quotio"]) else {
                    return .success(
                        type: .file,
                        mode: mode,
                        configPath: configPath,
                        authPath: nil,
                        shellConfig: nil,
                        rawConfigs: [],
                        instructions: "agents.opencode.notConfigured".localizedStatic(),
                        modelsConfigured: 0
                    )
                }

                _ = try backupIfPresent(configPath)
                try updatedData.write(to: URL(fileURLWithPath: configPath))

                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed Quotio provider. OpenCode will use its default providers.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove 'provider.quotio' section from ~/.config/opencode/opencode.json",
            modelsConfigured: 0
        )
    }
    
    private func generateFactoryDroidDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = homeDirectory.path
        let configPath = "\(home)/.factory/config.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                
                // Remove custom_models that point to localhost
                if var customModels = config["custom_models"] as? [[String: Any]] {
                    customModels = customModels.filter { model in
                        guard let baseURL = model["base_url"] as? String else { return true }
                        return !baseURL.contains("127.0.0.1") && !baseURL.contains("localhost")
                    }
                    config["custom_models"] = customModels.isEmpty ? nil : customModels
                }
                
                let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed proxy models. Factory Droid will use its default configurations.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove custom_models with localhost base_url from ~/.factory/config.json",
            modelsConfigured: 0
        )
    }
    
    /// 同一份严格快照供代理保存与官方恢复使用；无法理解的文件不能当成首次配置覆盖。
    /// 原始字节继续作为 CAS 基线及回滚输入，未知对象成员不经过字符串字典的整体强转。
    private func readClaudeSettingsSnapshot() throws -> (data: Data?, object: [String: Any]) {
        let original = try currentFileData(claudeLocation.settings.path)
        guard let original else { return (nil, [:]) }
        if String(data: original, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return (original, [:])
        }
        guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              object["env"] == nil || object["env"] is [String: Any] else { throw ClaudeCommitError.unreadable }
        return (original, object)
    }

    /// 统一 JSON 提交边界：读取方提供原字节，原 actor 备份、比较、原子替换并返回同一回滚回执。
    /// 官方恢复与普通保存共用此路径；报告只是附属诊断，写失败也不能留下半成功的配置。
    private func commitClaudeSettings(_ data: Data, expected: Data?, plan: ClaudeConfigurationPlan? = nil)
        throws -> (backupPath: String?, receipt: ClaudeConfigurationRollback) {
        let path = claudeLocation.settings.path
        guard try currentFileData(path) == expected else { throw ClaudeCommitError.changed }
        try fileManager.createDirectory(at: claudeLocation.directory, withIntermediateDirectories: true)
        let backupPath = try backupIfPresent(path)
        let reportPath = plan?.isCatalogManaged == true
            ? (backupPath ?? path + ".initial." + UUID().uuidString) + ".migration.json" : nil
        if let reportPath, let plan {
            let report = try JSONSerialization.data(withJSONObject: plan.migrationReport(backupPath: backupPath), options: [.prettyPrinted, .sortedKeys])
            try writeConfigurationData(report, URL(fileURLWithPath: reportPath))
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportPath)
        }
        let receipt = ClaudeConfigurationRollback(original: expected, written: data, reportPath: reportPath)
        do {
            try replaceConfiguration(data, path: path, expected: expected)
            if let reportPath, let plan {
                var committed = plan.migrationReport(backupPath: backupPath)
                committed["status"] = "committed"
                try writeConfigurationData(JSONSerialization.data(withJSONObject: committed, options: [.prettyPrinted, .sortedKeys]),
                                           URL(fileURLWithPath: reportPath))
            }
            return (backupPath, receipt)
        } catch {
            if (try? currentFileData(path)) == data { try rollbackClaudeConfiguration(receipt) }
            throw error
        }
    }

    /// Generates Claude Code configuration with smart merge behavior
    ///
    /// **Merge Strategy:**
    /// - Reads existing settings.json if present
    /// - Preserves ALL user configuration: permissions, hooks, mcpServers, statusLine, plugins, etc.
    /// - Merges env object: keeps user's env keys (MCP_API_KEY, etc.), updates only Quotio's ANTHROPIC_* keys
    /// - Updates model field with current selection
    ///
    /// **Backup Behavior:**
    /// - Creates timestamped backup on each reconfigure: settings.json.backup.{unix_timestamp}
    /// - Each backup is unique and never overwritten
    /// - All previous backups are preserved
    private func generateClaudeCodeConfig(config requestedConfig: AgentConfiguration, mode: ConfigurationMode, storageOption requestedStorage: ConfigStorageOption,
                                         availableModels: [AvailableModel], shell: ShellType = .zsh) -> AgentConfigResult {
        let operation = ClaudeConfigurationOperation(mode: mode, storage: requestedStorage)
        let storageOption = operation.storage
        // 自动保存与手动预览使用同一条校验；未填写的自定义值不能写成 0，也不能偷偷退回 200K。
        if let tokens = requestedConfig.claudeMaxContextTokens, tokens <= 0 {
            return .failure(error: "agents.claude.advanced.context.validation".localizedStatic())
        }
        let configPath = claudeLocation.settings.path

        // 在原 actor 的同步事务内读取最新文件，先建立计划，再生成 JSON／Shell。
        // 未编辑菜单不能被表单旧快照覆盖；计划只迁移有当前目录证据的请求 ID，完整保留其余原字段。
        let originalData: Data?
        var existingConfig: [String: Any]
        do { (originalData, existingConfig) = try readClaudeSettingsSnapshot() }
        catch { return .failure(error: "agents.claudeCompatibility.unreadable".localizedStatic()) }
        if requestedConfig.claudeCatalogManaged {
            guard existingConfig["env"] == nil || existingConfig["env"] is [String: Any],
                  existingConfig["modelSettings"] == nil || existingConfig["modelSettings"] is [String: Any],
                  existingConfig["advisorModel"] == nil || existingConfig["advisorModel"] is String,
                  ClaudeCatalogOwnership.canWrite(in: existingConfig) else {
                return .failure(error: "agents.claudeCompatibility.unreadable".localizedStatic())
            }
        }
        if requestedConfig.claudeCatalogManaged, let env = existingConfig["env"] as? [String: Any] {
            let modelKeys = ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                             "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE", "CLAUDE_CODE_MODEL_CAPABILITIES"]
                + ModelSlot.allCases.map { "ANTHROPIC_DEFAULT_" + $0.envSuffix + "_MODEL" }
            guard modelKeys.allSatisfy({ env[$0] == nil || env[$0] is String }) else {
                return .failure(error: "agents.claudeCompatibility.unreadable".localizedStatic())
            }
        }
        var input = requestedConfig
        if !input.claudeModelPicker.shouldWrite {
            input.claudeModelPicker = .read(existingConfig["modelPicker"])
            // 未编辑菜单始终以最新磁盘为基线，仅撤销仍匹配来源记录的自动值，再由同一计划重新投影。
            if input.claudeCatalogManaged, let projection = ClaudeCatalogProjection.read(in: existingConfig) {
                input.claudeModelPicker = projection.restoringMenu(input.claudeModelPicker)
            }
            input.claudeModelPicker.shouldWrite = false
        }
        let plan = ClaudeConfigurationPlan(configuration: input, availableModels: availableModels,
                                           legacy: .read(existingConfig))
        let config = plan.configuration
        if requestedConfig.claudeCatalogManaged {
            guard storageOption != .shellOnly else { return .failure(error: "agents.catalog.requiresJSON".localizedStatic()) }
            guard plan.catalogCount > 0 else { return .failure(error: "agents.models.empty".localizedStatic()) }
            guard plan.blockingReferences.isEmpty else {
                return .failure(error: "agents.catalog.blocked".localizedStatic() + " " + plan.blockingReferences.joined(separator: ", "))
            }
        }
        let existingEnv = existingConfig["env"] as? [String: Any] ?? [:]
        // JSON 中的 env 可能压过 Shell。只输出 Shell 无法撤下或替换旧 JSON 窗口，必须明确阻止半成功。
        // 在 actor 最新磁盘快照上复核，覆盖页面打开后其他程序改写该键的情况；未碰未知 env 与压缩设置。
        let contextNeedsJSON = existingEnv["CLAUDE_CODE_MAX_CONTEXT_TOKENS"].map { old in
            guard let desired = config.claudeMaxContextTokens else { return true }
            return claudeContextTokens(from: old) != desired
        } ?? false
        if storageOption == .shellOnly, contextNeedsJSON {
            return .failure(error: "agents.claude.advanced.context.requiresJSON".localizedStatic())
        }
        let oldSubagent = ClaudeSubagentSettings(model: existingEnv["CLAUDE_CODE_SUBAGENT_MODEL"] as? String,
                                               force: existingEnv["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] as? String)
        var subagentNeedsJSON = config.claudeSubagentSettings.requiresJSONUpdate(comparedTo: oldSubagent)
        // 在原 actor 的最新磁盘快照上校验，不能仅依赖页面打开时的 savedConfig。
        // 手动输出中的 Shell 同样是独立方案：发生冲突时不能继续给出可复制但实际不生效的脚本。
        if let selector = config.claudeSubagentSelector,
           let role = ModelSlot(rawValue: AgentConfiguration.normalizedClaudeModelID(selector).base),
           let oldRole = existingEnv["ANTHROPIC_DEFAULT_\(role.envSuffix)_MODEL"] as? String,
           oldRole != config.claudeRequestModel(for: role) {
            // 角色名未变也可能更换其目标；旧 JSON 中的角色映射同样会压过新的 Shell 映射。
            subagentNeedsJSON = true
        }
        if storageOption == .shellOnly, subagentNeedsJSON {
            return .failure(error: "agents.claudeSubagent.requiresJSON".localizedStatic())
        }
        if mode == .automatic, storageOption == .shellOnly, plan.requiresJSONUpdate {
            return .failure(error: "agents.claudeCompatibility.requiresJSON".localizedStatic())
        }
        let baseURL = clientServiceBaseURL(config.proxyURL)

        // Store base IDs in the form model and apply `[1m]` only to the request
        // values emitted for Claude Code. This keeps disabling 1M reversible.
        var requestModels: [ModelSlot: String] = [:]
        for slot in config.configuredClaudeSlots {
            requestModels[slot] = config.claudeRequestModel(for: slot)
        }

        // 默认角色保留 alias，由 Claude 继承该槽的模型和上下文；具体 ID 使用独立的 1M 状态。
        let effectiveDefaultModel = config.claudeDefaultModelSelector

        // 原生角色槽使用 Claude Code 的官方别名映射，值必须保留代理实际接受的模型 ID。
        // 不单独硬编码备用版本，以免界面默认值升级后，配置生成器仍写入旧版本。
        var quotioEnvConfig: [String: String] = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": config.apiKey,
            // 启动默认值不能用 ANTHROPIC_MODEL 持续钉住：/model 会更新顶层 model，
            // 高优先级的旧环境变量会让重启后的选择回退。默认变量允许 CLI 保存的新选择优先。
            "ANTHROPIC_DEFAULT_MODEL": config.claudeCatalogManaged ? config.claudeDefaultRequestModel : config.claudeDefaultFallbackModel,
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": String(config.claudeAutoCompactPercentage),
            // 显式写入 0，既清理旧版硬编码的 1，也防止继承的发现设置重新展开网关目录。
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": config.claudeGatewayModelDiscovery ? "1" : "0"
        ]
        // 仅明确的自定义值才覆盖客户端窗口。已有 200000 也是合法自定义值，不凭数值猜它是否来自旧版。
        if let tokens = config.effectiveClaudeMaxContextTokens {
            quotioEnvConfig["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(tokens)
        }
        if let subagent = config.claudeSubagentSettings.environmentModel {
            quotioEnvConfig["CLAUDE_CODE_SUBAGENT_MODEL"] = subagent
        }
        if let force = config.claudeSubagentModelForce {
            quotioEnvConfig["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] = force
        }
        if config.claudeDisableAutoCompact {
            quotioEnvConfig["DISABLE_AUTO_COMPACT"] = "1"
        }
        // 旧后台模型与能力关联键也属于同一计划，Shell 输出不能继续引用旧网关身份。
        if let model = plan.legacy.smallFastModel { quotioEnvConfig["ANTHROPIC_SMALL_FAST_MODEL"] = model }
        if let capabilities = plan.legacy.capabilities { quotioEnvConfig["CLAUDE_CODE_MODEL_CAPABILITIES"] = capabilities }

        for slot in config.configuredClaudeSlots {
            let requestModel = requestModels[slot] ?? config.claudeRequestModel(for: slot)
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            quotioEnvConfig[key] = requestModel

            // 官方 _NAME 控制模型选择器标题，_DESCRIPTION 同时用于 /model 的补全说明。
            // 自动名称保留 Opus/Sonnet/Haiku，两个角色指向同一模型时也不会出现重复的 ID 标题。
            // 用户自定义名称继续保留；说明始终包含实际 ID，补全与会话内面板都能核对请求目标。
            let displayName = plan.displayName(for: slot)
            quotioEnvConfig[key + "_NAME"] = displayName
            quotioEnvConfig[key + "_DESCRIPTION"] = config.claudeModelDescription(for: slot, availableModels: availableModels)
        }

        // 两种输出共用角色映射和显示信息；仅 Shell 配置仍需要显式启动覆盖，
        // 否则已有 settings.json 的 model 会压过新选择，且部分角色不能作为 DEFAULT_MODEL。
        // 同时保存 JSON 和 Shell 时，由 JSON 持有可被 /model 更新的选择，并清除旧的 Shell 强制值。
        var shellEnvConfig = quotioEnvConfig
        // 手动配置中的 Shell 是可单独复制的备选方案，即使传入 both 也不能依赖 JSON 已应用。
        let clearShellOverride = mode == .automatic && storageOption == .both
        if !clearShellOverride {
            shellEnvConfig["ANTHROPIC_MODEL"] = effectiveDefaultModel
        }
        // 撤销与赋值共用同一份管理键集合，避免清空 Fable、压缩或子代理后旧 Shell export 残留。
        // 不靠字符串替换把 POSIX 脚本转换成 fish；每条声明由目标 Shell 原生生成。
        let shellExports = "# CLIProxyAPI Configuration for Claude Code\n"
            + Set(ClaudeManagedEnvironment.keys).sorted().map { key in
                shell.environmentStatement(key: key, value: shellEnvConfig[key])
            }.joined(separator: "\n")
        // JSON env 对同名 Shell 值有优先级：所有受管值统一比较，不能只检查上下文和子代理。
        // 只检查已存在的 JSON 覆盖；JSON 没有的键仍可以由 Shell 正常提供。
        let shellNeedsJSON = ClaudeManagedEnvironment.keys.contains { key in
            guard let old = existingEnv[key] else { return false }
            // 上下文已有严格整数规则，等价的旧字符串／JSON 整数不能在这里再次被原字节比较否定。
            if key == "CLAUDE_CODE_MAX_CONTEXT_TOKENS" { return contextNeedsJSON }
            if ["CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE"].contains(key) { return subagentNeedsJSON }
            return (old as? String) != shellEnvConfig[key]
        } || ((existingConfig["model"] as? String).map { $0 != effectiveDefaultModel } ?? false)
        if operation.writesShell, !operation.writesJSON, shellNeedsJSON {
            return .failure(error: "agents.claudeCompatibility.requiresJSON".localizedStatic())
        }

        do {
            // 计划合并只修改已确认的模型引用，不重建未知结构；权限、hooks 等继续沿用原磁盘对象。
            existingConfig = try plan.mergingLegacyReferences(into: existingConfig)

            // Merge env object: preserve user's existing env keys, update only Quotio-managed keys.
            // `DISABLE_AUTO_COMPACT` has no false value: remove a stale Quotio entry
            // before merging when the user re-enables automatic compaction.
            var mergedEnv = existingConfig["env"] as? [String: Any] ?? [:]
            // 目标快照一次性替换我们已知的环境键：缺失意味着明确撤销，而非保留旧覆盖。
            // 只移除受管键，未来 env 成员（包括数值、对象）仍按原始 JSON 类型保留。
            for key in ClaudeManagedEnvironment.keys { mergedEnv.removeValue(forKey: key) }
            for (key, value) in quotioEnvConfig {
                mergedEnv[key] = value
            }
            existingConfig["env"] = mergedEnv

            // Update model field (other top-level keys are automatically preserved)
            existingConfig["model"] = effectiveDefaultModel

            // 精选列表只管理菜单显示，不写 availableModels 限制，也不改变实际角色映射。
            // 外部扩展字段由模型层保留；切回原生列表是用户明确选择，才撤下当前菜单。
            if config.claudeModelPicker.shouldWrite {
                if let picker = try config.claudePickerJSONObject() {
                    existingConfig["modelPicker"] = picker
                } else if config.claudeModelPicker.mode == .native {
                    existingConfig.removeValue(forKey: "modelPicker")
                }
            }
            // 原有 Magpie 菜单继续保留，只整理明确识别的显示元数据。
            // 这里处理实际磁盘对象，避免通过表单快照覆盖其他工具刚更新的账号或扩展字段。
            if let picker = existingConfig["modelPicker"] {
                existingConfig["modelPicker"] = ClaudeModelPresentation.formattedMagpieMenu(picker)
            }

            if config.claudeCatalogManaged {
                // 根对象未知键为 CLI passthrough，/model 保存后仍能据指纹识别同一后端。
                existingConfig = ClaudeCatalogOwnership.recording(in: existingConfig, source: plan.sourceIdentifier)
                existingConfig = ClaudeCatalogProjection.generated(input: input, output: config).recording(in: existingConfig)
            }
            // Generate JSON from merged config
            let jsonData = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            let shellProfilePath = shell.profilePath
            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "settings.json",
                    targetPath: configPath,
                    instructions: "Option 1: Save as " + configPath
                ),
                RawConfigOutput(
                    format: .shellExport,
                    content: shellExports,
                    filename: nil,
                    targetPath: shellProfilePath,
                    instructions: contextNeedsJSON ? "agents.claude.advanced.context.requiresJSON".localizedStatic()
                        : (shellNeedsJSON || subagentNeedsJSON || config.claudeCatalogManaged) ? "agents.claudeSubagent.shellNeedsJSON".localizedStatic() : "Option 2: Add to your shell profile"
                )
            ]
            
            if mode == .automatic {
                let shouldWriteJson = operation.writesJSON
                let committed = shouldWriteJson ? try commitClaudeSettings(jsonData, expected: originalData, plan: plan) : nil
                let backupPath = committed?.backupPath

                let instructions: String
                switch storageOption {
                case .jsonOnly:
                    instructions = "Configuration saved to " + configPath
                case .shellOnly:
                    instructions = "Shell exports ready. Add to your shell profile to complete setup."
                case .both:
                    instructions = "Configuration saved to " + configPath + " and shell profile updated."
                }
                
                var result = AgentConfigResult.success(
                    type: .both,
                    mode: mode,
                    configPath: shouldWriteJson ? configPath : nil,
                    shellConfig: (storageOption == .shellOnly || storageOption == .both) ? shellExports : nil,
                    rawConfigs: rawConfigs,
                    instructions: instructions,
                    modelsConfigured: config.claudeCatalogManaged ? config.configuredClaudeSlots.count : 3,
                    backupPath: backupPath
                )
                // JSON 与 Shell 是同一用户操作的两个阶段，第二阶段失败必须能回滚所有 JSON 保存方式。
                result.claudeRollback = committed?.receipt
                result.claudeShellAction = operation.writesShell ? .replace(shellExports)
                    : config.claudeCatalogManaged ? .remove : .preserve
                return result
            } else {
                return .success(
                    type: .both,
                    mode: mode,
                    configPath: configPath,
                    shellConfig: shellExports,
                    rawConfigs: rawConfigs,
                    instructions: contextNeedsJSON ? "agents.claude.advanced.context.requiresJSON".localizedStatic()
                        : (shellNeedsJSON || subagentNeedsJSON || config.claudeCatalogManaged) ? "agents.claudeSubagent.shellNeedsJSON".localizedStatic()
                        : "Choose one option: save settings.json OR add shell exports to your profile:",
                    modelsConfigured: config.claudeCatalogManaged ? config.configuredClaudeSlots.count : 3
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }
    
    private func generateCodexConfig(config: AgentConfiguration, mode: ConfigurationMode) async throws -> AgentConfigResult {
        // 新配置必须由用户从实时目录选择或明确手填；接口失败不能悄悄写入固定型号或空 model。
        // 此校验同时覆盖手动预览和直接服务调用，并且发生在备份、目录创建与凭据写入之前。
        guard !config.codexModel.isEmpty else {
            return .failure(error: "agents.models.selectRequired".localizedStatic())
        }
        let home = homeDirectory.path
        let codexDir = "\(home)/.codex"
        let configPath = "\(codexDir)/config.toml"
        let authPath = "\(codexDir)/auth.json"

        let managedConfigTOML = buildManagedCodexTOML(
            model: config.codexModel,
            proxyURL: config.proxyURL,
            reasoningEffort: config.codexReasoningEffort
        )

        let configTOML: String
        if fileManager.fileExists(atPath: configPath) {
            do {
                let existingConfig = try String(contentsOfFile: configPath, encoding: .utf8)
                configTOML = mergeCodexConfig(existingContent: existingConfig, managedConfig: managedConfigTOML)
            } catch {
                Log.warning("Failed to read existing Codex config at \(configPath): \(error.localizedDescription). Falling back to managed-only config.")
                configTOML = managedConfigTOML + "\n"
            }
        } else {
            configTOML = managedConfigTOML + "\n"
        }
        
        // auth.json holds Codex CLI's own credentials (access_token, refresh
        // token, account_id, ...). Quotio only owns the OPENAI_API_KEY entry, so
        // the managed write merges into the existing file rather than replacing
        // it — replacing it destroyed the user's native login (#367).
        //
        // `managed` (the Quotio key alone) is what the manual preview renders and
        // what "Copy All" copies; `merged` is only ever written to disk in
        // automatic mode. Keeping them apart means native tokens never reach the
        // UI or the clipboard.
        let authPayloads = Self.codexAuthPayloads(
            existing: fileManager.contents(atPath: authPath),
            apiKey: config.apiKey,
            path: authPath
        )

        let rawConfigs = [
            RawConfigOutput(
                format: .toml,
                content: configTOML,
                filename: "config.toml",
                targetPath: configPath,
                instructions: "Save this as ~/.codex/config.toml"
            ),
            RawConfigOutput(
                format: .json,
                content: authPayloads.managed,
                filename: "auth.json",
                targetPath: authPath,
                instructions: "agents.codex.authJSONMergeKey".localizedStatic()
            )
        ]

        if mode == .automatic {
            try fileManager.createDirectory(atPath: codexDir, withIntermediateDirectories: true)

            let backupPath = try backupIfPresent(configPath)
            _ = try backupIfPresent(authPath)

            try configTOML.write(toFile: configPath, atomically: true, encoding: .utf8)
            try authPayloads.merged.write(toFile: authPath, atomically: true, encoding: .utf8)

            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
            
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                authPath: authPath,
                rawConfigs: rawConfigs,
                instructions: "Configuration files created. Codex CLI is now configured to use CLIProxyAPI.",
                modelsConfigured: 1,
                backupPath: backupPath
            )
        } else {
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                authPath: authPath,
                rawConfigs: rawConfigs,
                instructions: "agents.codex.mergeAndSaveFiles".localizedStatic(),
                modelsConfigured: 1
            )
        }
    }
    
    private func generateAmpConfig(config: AgentConfiguration, mode: ConfigurationMode) async throws -> AgentConfigResult {
        let home = homeDirectory.path
        let configDir = "\(home)/.config/amp"
        let dataDir = "\(home)/.local/share/amp"
        let settingsPath = "\(configDir)/settings.json"
        let secretsPath = "\(dataDir)/secrets.json"
        let baseURL = clientServiceBaseURL(config.proxyURL)
        
        let settingsData = try Self.mergedAmpJSON(existing: nil, updates: ["amp.url": baseURL])
        let secretsData = try Self.mergedAmpJSON(existing: nil, updates: ["apiKey@\(baseURL)": config.apiKey])
        let settingsJSON = String(decoding: settingsData, as: UTF8.self)
        let secretsJSON = String(decoding: secretsData, as: UTF8.self)
        
        let envExports = """
        # Alternative: Environment variables for Amp CLI
        export AMP_URL="\(baseURL)"
        export AMP_API_KEY="\(config.apiKey)"
        """
        
        let rawConfigs = [
            RawConfigOutput(
                format: .json,
                content: settingsJSON,
                filename: "settings.json",
                targetPath: settingsPath,
                instructions: "agents.amp.mergeSettings".localizedStatic()
            ),
            RawConfigOutput(
                format: .json,
                content: secretsJSON,
                filename: "secrets.json",
                targetPath: secretsPath,
                instructions: "agents.amp.mergeSecrets".localizedStatic()
            ),
            RawConfigOutput(
                format: .shellExport,
                content: envExports,
                filename: nil,
                targetPath: "\(ShellType.zsh.profilePath) (alternative)",
                instructions: "agents.amp.useEnvironmentVariables".localizedStatic()
            )
        ]
        
        if mode == .automatic {
            try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

            let existingSettings = fileManager.contents(atPath: settingsPath)
            let existingSecrets = fileManager.contents(atPath: secretsPath)
            let mergedSettings = try Self.mergedAmpJSON(
                existing: existingSettings,
                updates: ["amp.url": baseURL]
            )
            let mergedSecrets = try Self.mergedAmpJSON(
                existing: existingSecrets,
                updates: ["apiKey@\(baseURL)": config.apiKey]
            )
            let backupPath = try backupIfPresent(settingsPath)
            _ = try backupIfPresent(secretsPath)

            try mergedSettings.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            try mergedSecrets.write(to: URL(fileURLWithPath: secretsPath), options: .atomic)
            
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsPath)
            
            return .success(
                type: .both,
                mode: mode,
                configPath: settingsPath,
                authPath: secretsPath,
                shellConfig: envExports,
                rawConfigs: rawConfigs,
                instructions: "agents.amp.configSuccess".localizedStatic(),
                modelsConfigured: 1,
                backupPath: backupPath
            )
        } else {
            return .success(
                type: .both,
                mode: mode,
                configPath: settingsPath,
                authPath: secretsPath,
                shellConfig: envExports,
                rawConfigs: rawConfigs,
                instructions: "agents.amp.mergeAndSaveFiles".localizedStatic(),
                modelsConfigured: 1
            )
        }
    }

    nonisolated static func mergedAmpJSON(existing: Data?, updates: [String: String]) throws -> Data {
        var object: [String: Any] = [:]
        if let existing {
            guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            object = decoded
        }
        for (key, value) in updates {
            object[key] = value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Strips the Quotio-managed `OPENAI_API_KEY` from the auth.json at `path`,
    /// backing the file up first. Returns `true` when the file was rewritten.
    ///
    /// Deliberately independent of `config.toml`: reverting used to be nested
    /// inside the `config.toml` branch, so a user whose `config.toml` had already
    /// been removed kept the managed key in `auth.json` forever. A corrupt or
    /// user-owned `auth.json` is left untouched rather than failing the revert.
    func revertCodexAuthJSON(at path: String) throws -> Bool {
        guard let authData = fileManager.contents(atPath: path),
              let cleaned = (try? Self.codexAuthJSONRemovingQuotioKey(existing: authData)).flatMap({ $0 })
        else { return false }

        _ = try backupIfPresent(path)
        try cleaned.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }

    /// The two ~/.codex/auth.json renderings a configuration run needs.
    ///
    /// - `managed`: the Quotio-owned key on its own. Safe to display and copy,
    ///   so this is what manual mode shows.
    /// - `merged`: the Quotio key merged into the user's current file. Written
    ///   to disk in automatic mode only, because it carries native credentials.
    ///
    /// An unreadable/corrupt existing file degrades to the managed-only content
    /// (with a warning), matching the `config.toml` merge fallback.
    nonisolated static func codexAuthPayloads(
        existing: Data?,
        apiKey: String,
        path: String
    ) -> (managed: String, merged: String) {
        // Building from `nil` cannot fail, so the managed rendering is total.
        let managedData = (try? mergedCodexAuthJSON(existing: nil, apiKey: apiKey))
            ?? Data(#"{"OPENAI_API_KEY":"\#(apiKey)"}"#.utf8)
        let managed = String(decoding: managedData, as: UTF8.self)

        guard let existing else { return (managed: managed, merged: managed) }
        do {
            let mergedData = try mergedCodexAuthJSON(existing: existing, apiKey: apiKey)
            return (managed: managed, merged: String(decoding: mergedData, as: UTF8.self))
        } catch {
            Log.warning("Failed to parse existing Codex auth.json at \(path): \(error.localizedDescription). Falling back to managed-only auth.json.")
            return (managed: managed, merged: managed)
        }
    }

    /// Merges the Quotio proxy key into the existing ~/.codex/auth.json content,
    /// preserving every other field (access_token, refresh token, account_id, ...)
    /// so configuring the proxy does not sign the user out of Codex CLI (#367).
    /// Throws if `existing` is not a JSON object.
    nonisolated static func mergedCodexAuthJSON(existing: Data?, apiKey: String) throws -> Data {
        var object: [String: Any] = [:]
        if let existing {
            guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            object = decoded
        }
        object["OPENAI_API_KEY"] = apiKey
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Removes the Quotio-managed OPENAI_API_KEY (a "quotio-" prefixed value)
    /// from ~/.codex/auth.json content, preserving all other fields.
    /// Returns nil when there is nothing to remove (no key, or a user-owned key).
    /// Throws if `existing` is not a JSON object.
    nonisolated static func codexAuthJSONRemovingQuotioKey(existing: Data) throws -> Data? {
        guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let key = decoded["OPENAI_API_KEY"] as? String, key.hasPrefix("quotio-") else {
            return nil
        }
        var object = decoded
        object.removeValue(forKey: "OPENAI_API_KEY")
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// 最终提交前比较原字节，原子替换并回读验证；外部修改不得被旧计划覆盖。
    private func currentFileData(_ path: String) throws -> Data? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func replaceConfiguration(_ data: Data, path: String, expected: Data?) throws {
        guard try currentFileData(path) == expected else { throw ClaudeCommitError.changed }
        // Dotfiles 可能由符号链接管理；原子替换真实目标，保留用户原来的链接关系。
        let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let permissions = (try? fileManager.attributesOfItem(atPath: destination.path)[.posixPermissions]) ?? 0o600
        do {
            try writeConfigurationData(data, destination)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            guard try currentFileData(path) == data else { throw ClaudeCommitError.changed }
        } catch {
            if (try? currentFileData(path)) == data {
                if let expected { try expected.write(to: destination, options: .atomic) }
                else { try fileManager.removeItem(at: destination) }
            }
            throw error
        }
    }

    enum ClaudeCommitError: LocalizedError {
        case changed
        case unreadable
        var errorDescription: String? {
            switch self {
            case .changed: "agents.catalog.fileChanged".localizedStatic()
            case .unreadable: "agents.claudeCompatibility.unreadable".localizedStatic()
            }
        }
    }

    /// Shell 阶段失败只回滚本事务仍拥有的 JSON；外部已经改写时报告失败，保留双方备份供恢复。
    func rollbackClaudeConfiguration(_ receipt: ClaudeConfigurationRollback) throws {
        let path = claudeLocation.settings.path
        guard try currentFileData(path) == receipt.written else { throw ClaudeCommitError.changed }
        if let original = receipt.original { try replaceConfiguration(original, path: path, expected: receipt.written) }
        else { try fileManager.removeItem(at: URL(fileURLWithPath: path).resolvingSymlinksInPath()) }
        if let reportPath = receipt.reportPath,
           let data = fileManager.contents(atPath: reportPath),
           var report = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            report["status"] = "rolledBack"
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
    }

    /// 账号变更只接管已有版本标记且指纹匹配的用户配置；未迁移／外部服务不写盘。
    /// 读取与重建都在原 actor 中，自动同步不会借用配置页未保存的草稿。
    func managedClaudeConfiguration(serviceBaseURLs: [String]) -> AgentConfiguration? {
        guard let saved = readClaudeCodeConfig(), saved.claudeModelPicker.isQuotioManaged,
              saved.claudeModelPicker.extraFields["quotioCatalogVersion"] == .integer(1),
              let base = saved.baseURL, let key = saved.apiKey else { return nil }
        let url = ClaudeConfigurationSource.modelAPIBaseURL(base)
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: url, apiKey: key)
        guard serviceBaseURLs.contains(where: { endpoint in
            ModelCatalogClient.modelsURL(baseURL: ClaudeConfigurationSource.modelAPIBaseURL(endpoint))
                == ModelCatalogClient.modelsURL(baseURL: url)
        }), saved.claudeModelPicker.extraFields["quotioCatalogSource"] == .string(ClaudeConfigurationPlan.sourceID(url: url, key: key)) else { return nil }
        config.modelSlots = saved.modelSlots
        config.claudeDefaultModel = saved.defaultModel
        config.claudeDefaultModel1M = saved.claudeDefaultModel1M
        config.claudeModelDisplayNames = saved.modelDisplayNames
        config.claudeModelPlatformHints = saved.modelPlatformHints
        config.claudeMaxContextTokens = saved.claudeMaxContextTokens
        config.claudeAutoCompactPercentage = saved.claudeAutoCompactPercentage
        config.claudeDisableAutoCompact = saved.claudeDisableAutoCompact
        config.claudeModel1M = saved.claudeModel1M
        config.claudeSubagentModel = saved.claudeSubagentModel
        config.claudeSubagentModelForce = saved.claudeSubagentModelForce
        config.claudeModelPicker = saved.claudeModelPicker
        config.claudeCatalogManaged = true
        return config
    }

    func synchronizeManagedClaudeCatalog(sourceID: String, serviceBaseURLs: [String], models: [AvailableModel],
                                         authorization: ClaudeCatalogCommitAuthorization? = nil) -> AgentConfigResult? {
        if let authorization {
            // 许可必须在 actor 真正执行时再检查；调用前后的 MainActor UUID 校验无法撤销已排队的写入。
            // 递归的无许可分支是同一 actor 内的同步事务，锁一直覆盖最新读取、备份和原子提交。
            return authorization.withPermission {
                synchronizeManagedClaudeCatalog(sourceID: sourceID, serviceBaseURLs: serviceBaseURLs, models: models)
            } ?? nil
        }
        guard let config = managedClaudeConfiguration(serviceBaseURLs: serviceBaseURLs),
              ClaudeConfigurationPlan.sourceID(url: config.proxyURL, key: config.apiKey) == sourceID else { return nil }
        // 当前磁盘对象是最终基线；同一 actor 同步生成／提交，不存在网络 await 重入。
        let plan = ClaudeConfigurationPlan(configuration: config, availableModels: models, legacy: .read(
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: claudeLocation.settings))) as? [String: Any] ?? [:]))
        guard plan.blockingReferences.isEmpty else { return .failure(error: "agents.catalog.blocked".localizedStatic() + " " + plan.blockingReferences.joined(separator: ", ")) }
        // 先生成纯预览，字节相同不重复备份或写入，避免手动刷新造成备份膨胀。
        let preview = generateClaudeCodeConfig(config: config, mode: .manual, storageOption: .jsonOnly, availableModels: models)
        let path = claudeLocation.settings
        if let content = preview.rawConfigs.first(where: { $0.format == .json })?.content,
           (try? Data(contentsOf: path)) == Data(content.utf8) { return preview }
        return generateClaudeCodeConfig(config: config, mode: .automatic, storageOption: .jsonOnly, availableModels: models)
    }

    private func backupIfPresent(_ path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        var timestamp = Int(Date().timeIntervalSince1970)
        var backupPath = "\(path).backup.\(timestamp)"
        while fileManager.fileExists(atPath: backupPath) {
            timestamp += 1
            backupPath = "\(path).backup.\(timestamp)"
        }
        // 备份存放原字节而非符号链接本身，恢复列表中的文件始终独立于原目标。
        try Data(contentsOf: URL(fileURLWithPath: path)).write(to: URL(fileURLWithPath: backupPath), options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
        return backupPath
    }
    
    /// 只移除末尾的兼容版本段，不能全局替换 /v1：例如 https://v1.example.com/prefix/v1
    /// 的主机名和中间路径都属于用户服务地址。各生成器继续按原协议添加自己的请求路径。
    private func clientServiceBaseURL(_ apiBaseURL: String) -> String {
        var value = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") { value.removeLast(3) }
        return value
    }

    private func generateOpenCodeConfig(config: AgentConfiguration, mode: ConfigurationMode, availableModels: [AvailableModel]) -> AgentConfigResult {
        let home = homeDirectory.path
        let configDir = "\(home)/.config/opencode"
        let configPath = "\(configDir)/opencode.json"
        let baseURL = clientServiceBaseURL(config.proxyURL)
        let existingData = fileManager.contents(atPath: configPath)

        // 配置文件是用户长期编辑的文档，不是实时目录缓存。即使本轮目录非空，也不能
        // 删除未返回的旧 ID，或用家族猜测覆盖同 ID 的显示名、能力、上下文和自定义参数。
        let savedProvider: [String: Any]
        do {
            // 原编辑器允许空文件／纯空白作为首次配置；预读取元数据必须遵守同一契约。
            let blank = existingData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            let object = blank ? [:] : try existingData.map { try OpenCodeConfigEditor.parseObject($0) } ?? [:]
            savedProvider = (object["provider"] as? [String: Any])?["quotio"] as? [String: Any] ?? [:]
            if let models = savedProvider["models"], !(models is [String: [String: Any]]) {
                return .failure(error: "OpenCode provider.quotio.models must be an object. Existing configuration was preserved.")
            }
            if let options = savedProvider["options"], !(options is [String: Any]) {
                return .failure(error: "OpenCode provider.quotio.options must be an object. Existing configuration was preserved.")
            }
        } catch {
            return .failure(error: String(format: "agents.opencode.parseFailed".localizedStatic(), configPath, error.localizedDescription))
        }
        var quotioModels = savedProvider["models"] as? [String: [String: Any]] ?? [:]
        let explicitModels = config.modelSlots.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for model in availableModels.map(\.name) + explicitModels.sorted() where quotioModels[model] == nil {
            quotioModels[model] = buildOpenCodeModelConfig(for: model)
        }
        guard !quotioModels.isEmpty else {
            return .failure(error: "agents.models.empty".localizedStatic())
        }

        // 仅更新本功能负责的连接键；未知 provider/options 元数据属于已有配置，不能被重建清空。
        var quotioProvider = savedProvider
        quotioProvider["models"] = quotioModels
        if quotioProvider["name"] == nil { quotioProvider["name"] = "Quotio" }
        if quotioProvider["npm"] == nil { quotioProvider["npm"] = "@ai-sdk/anthropic" }
        var options = savedProvider["options"] as? [String: Any] ?? [:]
        options["apiKey"] = config.apiKey
        options["baseURL"] = "\(baseURL)/v1"
        options["litellmProxy"] = true
        quotioProvider["options"] = options

        do {
            let jsonData: Data
            do {
                jsonData = try OpenCodeConfigEditor.merging(
                    existing: existingData,
                    providers: ["quotio": quotioProvider]
                )
            } catch {
                if mode == .automatic && existingData != nil {
                    // Never fall back to overwriting a file we could not parse:
                    // that wipes user settings like `plugin` and other providers (#176).
                    return .failure(error: String(
                        format: "agents.opencode.parseFailed".localizedStatic(),
                        configPath,
                        error.localizedDescription
                    ))
                }
                jsonData = try OpenCodeConfigEditor.merging(
                    existing: nil,
                    providers: ["quotio": quotioProvider]
                )
            }
            let jsonString = String(decoding: jsonData, as: UTF8.self)

            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "opencode.json",
                    targetPath: configPath,
                    instructions: "Merge provider.quotio into ~/.config/opencode/opencode.json"
                )
            ]

            if mode == .automatic {
                try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)

                let backupPath = try backupIfPresent(configPath)

                try jsonData.write(to: URL(fileURLWithPath: configPath))

                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Configuration updated. Run 'opencode' and use /models to select a model (e.g., quotio/\(quotioModels.keys.sorted().first ?? "model")).",
                    modelsConfigured: quotioModels.count,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Merge provider.quotio section into your existing ~/.config/opencode/opencode.json:",
                    modelsConfigured: quotioModels.count
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }

    /// Build OpenCode model configuration based on model name patterns
    private func buildOpenCodeModelConfig(for modelName: String) -> [String: Any] {
        let displayName = modelName.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")

        var modelConfig: [String: Any] = ["name": displayName]

        // Determine limits and capabilities based on model family
        if modelName.contains("claude") {
            modelConfig["limit"] = ["context": 200000, "output": 64000]
            // Claude models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("gemini") {
            modelConfig["limit"] = ["context": 1048576, "output": 65536]
            // Gemini models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("gpt") {
            modelConfig["limit"] = ["context": 400000, "output": 32768]
            // GPT-4+ models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("qwen") && modelName.contains("vl") {
            // Qwen VL (vision-language) models
            modelConfig["limit"] = ["context": 128000, "output": 16384]
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.lowercased().contains("minimax") {
            // MiniMax multimodal models: 1M context with text, image, and video input
            modelConfig["limit"] = ["context": 1000000, "output": 16384]
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image", "video"], "output": ["text"]]
        } else {
            // Default: text-only models
            modelConfig["limit"] = ["context": 128000, "output": 16384]
            modelConfig["attachment"] = false
            modelConfig["modalities"] = ["input": ["text"], "output": ["text"]]
        }

        // Add reasoning options for thinking/reasoning models
        if modelName.contains("thinking") {
            modelConfig["reasoning"] = true
            modelConfig["options"] = ["thinking": ["type": "enabled", "budgetTokens": 10000]]
        } else if modelName.contains("codex") || modelName.hasPrefix("gpt-5") || modelName.hasPrefix("o1") || modelName.hasPrefix("o3") {
            modelConfig["reasoning"] = true
            if modelName.contains("max") {
                modelConfig["options"] = ["reasoning": ["effort": "high"]]
            } else if modelName.contains("mini") {
                modelConfig["options"] = ["reasoning": ["effort": "low"]]
            } else {
                modelConfig["options"] = ["reasoning": ["effort": "medium"]]
            }
        }

        return modelConfig
    }

    private func generateFactoryDroidConfig(config: AgentConfiguration, mode: ConfigurationMode, availableModels: [AvailableModel]) -> AgentConfigResult {
        let home = homeDirectory.path
        let configDir = "\(home)/.factory"
        let configPath = "\(configDir)/config.json"

        let openaiBaseURL = "\(clientServiceBaseURL(config.proxyURL))/v1"

        // 严格读取并合并旧文档：实时目录成功同样不能清空用户其他设置、旧模型或同 ID 的自定义参数。
        // 解析失败必须停止，不能用“有新目录”作为覆盖损坏文件的理由。
        var factoryConfig: [String: Any]
        do {
            if fileManager.fileExists(atPath: configPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                // 尚未写入内容的初始文件与不存在等价；有实际内容但格式错误时仍禁止覆盖。
                if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    factoryConfig = [:]
                } else {
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .failure(error: "Factory configuration must be a JSON object. Existing file was preserved.")
                    }
                    factoryConfig = object
                }
            } else {
                factoryConfig = [:]
            }
            if let models = factoryConfig["custom_models"], !(models is [[String: Any]]) {
                return .failure(error: "Factory custom_models must be an array. Existing configuration was preserved.")
            }
        } catch {
            return .failure(error: "Failed to read Factory configuration: \(error.localizedDescription)")
        }
        var customModels = factoryConfig["custom_models"] as? [[String: Any]] ?? []
        var managedNames = Set<String>()
        for index in customModels.indices {
            // base_url 缺失的旧记录沿用前轮回填；显式属于其他服务的记录必须保留其连接与认证，
            // 不能因为模型名相同就把用户另一个提供商改接到 CPA。
            let previousBase = customModels[index]["base_url"] as? String
            guard previousBase == nil || previousBase?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == openaiBaseURL,
                  let name = customModels[index]["model"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            customModels[index]["base_url"] = openaiBaseURL
            customModels[index]["api_key"] = config.apiKey
            managedNames.insert(name)
        }
        let explicitModels = config.modelSlots.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for name in availableModels.map(\.name) + explicitModels.sorted() where managedNames.insert(name).inserted {
            customModels.append(["model": name, "model_display_name": name, "base_url": openaiBaseURL,
                                 "api_key": config.apiKey, "provider": "openai"])
        }
        guard !managedNames.isEmpty else {
            return .failure(error: "agents.models.empty".localizedStatic())
        }
        factoryConfig["custom_models"] = customModels

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: factoryConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "config.json",
                    targetPath: configPath,
                    instructions: "Save this as ~/.factory/config.json"
                )
            ]

            if mode == .automatic {
                try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)

                // 备份失败时不继续覆盖；复用同一套防重名备份规则，再原子替换本次合并结果。
                let backupPath = try backupIfPresent(configPath)
                try jsonData.write(to: URL(fileURLWithPath: configPath), options: .atomic)

                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Configuration saved. Run 'droid' or 'factory' to start using Factory Droid.",
                    modelsConfigured: customModels.count,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Copy the configuration below and save it as ~/.factory/config.json:",
                    modelsConfigured: customModels.count
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }
    
    // 保留原模型读取接口供既有调用兼容；实际只读业务统一委托共享服务，原配置状态与写入方法不变。
    /// Fetches the proxy's OpenAI-compatible `/v1/models` response exactly as reported.
    ///
    /// Nothing is substituted, cached or filtered: the result is the response body
    /// and nothing else, and any transport/decoding problem is thrown rather than
    /// masked. Callers that must show whether a catalog is genuinely live use this;
    /// `fetchAvailableModels(config:)` layers agent-setup-specific filtering on top.
    func fetchModelCatalog(config: AgentConfiguration) async throws -> [ModelCatalogEntry] {
        try await AgentModelCatalogService.fetchModelCatalog(proxyURL: config.proxyURL, apiKey: config.apiKey)
    }

    func fetchAvailableModels(config: AgentConfiguration) async throws -> [AvailableModel] {
        try await AgentModelCatalogService.fetchAvailableModels(proxyURL: config.proxyURL, apiKey: config.apiKey)
    }
    
    func testConnection(agent: CLIAgent, config: AgentConfiguration) async -> ConnectionTestResult {
        await AgentModelCatalogService.testConnection(proxyURL: config.proxyURL, apiKey: config.apiKey)
    }
}
