//
//  AgentConfigurationService.swift
//  Quotio - Generate agent configurations
//

import Foundation

actor AgentConfigurationService {
    private let fileManager = FileManager.default
    private let homeDirectory: URL
    private let trashBackup: @Sendable (URL) throws -> Void

    /// 允许测试注入临时用户目录，覆盖真实的读取、备份和重新配置流程，避免触碰用户凭据。
    /// 正常启动仍使用系统用户目录，现有调用方无需传入额外参数。
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashBackup: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.trashBackup = trashBackup
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
        /// 仅保存配置中明确声明的名称；没有声明时由表单和生成器统一回退到请求 ID。
        var modelDisplayNames: [ModelSlot: String] = [:]
        /// Claude Code 高级设置只在 Claude 配置读取路径回填；其他代理保留安全默认值。
        var claudeMaxContextTokens = AgentConfiguration.defaultClaudeMaxContextTokens
        var claudeAutoCompactPercentage = AgentConfiguration.defaultClaudeAutoCompactPercentage
        var claudeDisableAutoCompact = false
        var claudeModel1M: [ModelSlot: Bool] = [:]
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
        let home = homeDirectory.path
        var backups: [BackupFile] = []
        
        for configPath in agent.configPaths {
            let expandedPath = configPath.replacingOccurrences(of: "~", with: home)
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
        // Determine the original config path from the backup path
        // e.g., ~/.claude/settings.json.backup.123 -> ~/.claude/settings.json
        let originalPath = backup.path
            .replacingOccurrences(of: ".backup.\(Int(backup.timestamp.timeIntervalSince1970))", with: "")
        
        // Create a backup of current config before restoring
        if fileManager.fileExists(atPath: originalPath) {
            let currentBackupPath = "\(originalPath).backup.\(Int(Date().timeIntervalSince1970))"
            try? fileManager.copyItem(atPath: originalPath, toPath: currentBackupPath)
            try fileManager.removeItem(atPath: originalPath)
        }
        
        // Copy backup to original location
        try fileManager.copyItem(atPath: backup.path, toPath: originalPath)
    }
    
    // MARK: - Agent-Specific Read Implementations
    
    /// `[1m]` is a Claude Code model selector suffix, not part of Quotio's stored
    /// model ID. Strip exactly one terminal suffix so malformed IDs are not rewritten
    /// into a different request on read.
    private func normalizedClaudeModelID(_ value: String) -> (base: String, uses1M: Bool) {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.hasSuffix("[1m]") else { return (model, false) }
        return (String(model.dropLast(4)), true)
    }

    private func claudeRequestModel(baseModel: String, uses1M: Bool) -> String {
        let normalized = normalizedClaudeModelID(baseModel).base
        return uses1M ? normalized + "[1m]" : normalized
    }

    private func readClaudeCodeConfig() -> SavedAgentConfig? {
        let home = homeDirectory.path
        let configPath = "\(home)/.claude/settings.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let env = json["env"] as? [String: String] ?? [:]
        
        let baseURL = env["ANTHROPIC_BASE_URL"]
        let apiKey = env["ANTHROPIC_AUTH_TOKEN"]

        var modelSlots: [ModelSlot: String] = [:]
        var claudeModel1M: [ModelSlot: Bool] = [:]
        for slot in ModelSlot.allCases {
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            guard let requestModel = env[key] else { continue }
            let normalized = normalizedClaudeModelID(requestModel)
            modelSlots[slot] = normalized.base
            if normalized.uses1M {
                claudeModel1M[slot] = true
            }
        }

        let configuredDefaultModel = env["ANTHROPIC_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (json["model"] as? String)
        let defaultModel: String?
        if let configuredDefaultModel {
            let normalized = normalizedClaudeModelID(configuredDefaultModel)
            let followsSlot = ModelSlot.allCases.contains { slot in
                normalized.base == slot.rawValue || normalized.base == modelSlots[slot]
            }
            defaultModel = followsSlot ? normalized.base : configuredDefaultModel
        } else {
            defaultModel = nil
        }

        let parsedContextTokens = env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"].flatMap(Int.init)
        let claudeMaxContextTokens = (parsedContextTokens ?? AgentConfiguration.defaultClaudeMaxContextTokens) > 0
            ? (parsedContextTokens ?? AgentConfiguration.defaultClaudeMaxContextTokens)
            : AgentConfiguration.defaultClaudeMaxContextTokens
        let parsedCompactPercentage = env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"].flatMap(Int.init)
        let claudeAutoCompactPercentage = parsedCompactPercentage.flatMap { (1...100).contains($0) ? $0 : nil }
            ?? AgentConfiguration.defaultClaudeAutoCompactPercentage

        // Check if proxy is configured (localhost or 127.0.0.1 in base URL)
        let isProxy = baseURL?.contains("127.0.0.1") == true ||
                      baseURL?.contains("localhost") == true

        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: modelSlots,
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .claudeCode),
            defaultModel: defaultModel,
            modelDisplayNames: Dictionary(uniqueKeysWithValues: ModelSlot.allCases.compactMap { slot in
                guard let name = env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL_NAME"] else { return nil }
                return (slot, name)
            }),
            claudeMaxContextTokens: claudeMaxContextTokens,
            claudeAutoCompactPercentage: claudeAutoCompactPercentage,
            claudeDisableAutoCompact: env["DISABLE_AUTO_COMPACT"] == "1",
            claudeModel1M: claudeModel1M
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
        availableModels: [AvailableModel] = []
    ) async throws -> AgentConfigResult {
        
        // Pi 使用官方独立 provider 插件，代理与默认模式均交给同一服务处理。
        if agent == .pi {
            return try await PiAgentConfigurationService(homeDirectory: homeDirectory).generate(
                config: config, mode: mode, detectionService: detectionService
            )
        }

        // Check if we should generate default (non-proxy) configuration
        if config.setupMode == .defaultSetup {
            return try await generateDefaultConfiguration(agent: agent, mode: mode)
        }

        switch agent {
        case .pi:
            // 入口已统一分发 Pi，保留显式分支避免新增智能体后遗漏枚举处理。
            return .failure(error: "Pi configuration must use the dedicated provider service.")
        case .claudeCode:
            return generateClaudeCodeConfig(config: config, mode: mode, storageOption: storageOption)

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
    private func generateDefaultConfiguration(agent: CLIAgent, mode: ConfigurationMode) async throws -> AgentConfigResult {
        switch agent {
        case .pi:
            // 入口已统一分发 Pi，保留显式分支避免新增智能体后遗漏枚举处理。
            return .failure(error: "Pi configuration must use the dedicated provider service.")
        case .claudeCode:
            return generateClaudeCodeDefaultConfig(mode: mode)
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
    
    private func generateClaudeCodeDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = homeDirectory.path
        let configDir = "\(home)/.claude"
        let configPath = "\(configDir)/settings.json"
        
        // 映射与显示元数据必须一起清理，否则恢复默认后仍会留下旧代理模型的名称或说明。
        let keysToRemove = [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_MODEL",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
            "DISABLE_AUTO_COMPACT",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
            "CLAUDE_CODE_SUBAGENT_MODEL"
        ] + ModelSlot.allCases.flatMap { slot in
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            return [key, key + "_NAME", key + "_DESCRIPTION"]
        }
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                // Read existing settings
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var existingSettings = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // 同一秒内反复重新配置或恢复默认也必须保留独立备份。
                _ = try backupIfPresent(configPath)
                
                // 删除前记录受管模型，支持任意代理 ID 和别名；不再用 gpt/gemini 子串猜测归属。
                let oldEnv = existingSettings["env"] as? [String: String] ?? [:]
                let modelKeys = ["ANTHROPIC_MODEL"] + ModelSlot.allCases.map { "ANTHROPIC_DEFAULT_\($0.envSuffix)_MODEL" }
                let managedModels = Set(modelKeys.compactMap { oldEnv[$0] })
                if var env = existingSettings["env"] as? [String: String] {
                    for key in keysToRemove {
                        env.removeValue(forKey: key)
                    }
                    existingSettings["env"] = env.isEmpty ? nil : env
                }
                
                // 仅清理与受管默认值或槽映射相同的顶层模型，保留用户另行设置的模型。
                if let modelName = existingSettings["model"] as? String,
                   managedModels.contains(modelName) {
                    existingSettings.removeValue(forKey: "model")
                }
                
                // Write updated settings
                let updatedData = try JSONSerialization.data(withJSONObject: existingSettings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed Quotio proxy configuration. Claude Code will now use its default Anthropic API endpoint.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update settings: \(error.localizedDescription)")
            }
        }
        
        // Manual mode - show what would be removed
        let instructions = """
        To revert to default, remove these environment variables from ~/.claude/settings.json:
        \(keysToRemove.map { "- " + $0 }.joined(separator: "\n"))
        """
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [RawConfigOutput(
                format: .json,
                content: "Remove the above keys from ~/.claude/settings.json env section",
                filename: "instructions.txt",
                targetPath: configPath,
                instructions: instructions
            )],
            instructions: instructions,
            modelsConfigured: 0
        )
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
    private func generateClaudeCodeConfig(config: AgentConfiguration, mode: ConfigurationMode, storageOption: ConfigStorageOption) -> AgentConfigResult {
        let home = homeDirectory.path
        let configDir = "\(home)/.claude"
        let configPath = "\(configDir)/settings.json"

        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")

        // Store base IDs in the form model and apply `[1m]` only to the request
        // values emitted for Claude Code. This keeps disabling 1M reversible.
        var baseModels: [ModelSlot: String] = [:]
        var requestModels: [ModelSlot: String] = [:]
        for slot in ModelSlot.allCases {
            let selectedModel = config.modelSlots[slot]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseModel = selectedModel.flatMap { $0.isEmpty ? nil : $0 }
                ?? AvailableModel.defaultModels[slot]!.name
            baseModels[slot] = normalizedClaudeModelID(baseModel).base
            requestModels[slot] = claudeRequestModel(
                baseModel: baseModel,
                uses1M: config.usesClaude1MContext(for: slot)
            )
        }

        // Keep the existing launch-model selection unchanged unless it follows a
        // role that is explicitly opted into 1M. This preserves aliases and custom
        // launch IDs while ensuring the active 1M role is actually requested.
        let configuredDefaultModel = config.claudeModel
        let normalizedDefaultModel = normalizedClaudeModelID(configuredDefaultModel)
        let defaultModelSlot = ModelSlot.allCases.first { slot in
            normalizedDefaultModel.base == slot.rawValue || normalizedDefaultModel.base == baseModels[slot]
        }
        let effectiveDefaultModel: String
        if let defaultModelSlot, config.usesClaude1MContext(for: defaultModelSlot) {
            effectiveDefaultModel = requestModels[defaultModelSlot] ?? configuredDefaultModel
        } else {
            effectiveDefaultModel = configuredDefaultModel
        }

        // 三个槽是 Claude Code 的官方别名映射，值必须保留代理实际接受的模型 ID。
        // 不单独硬编码备用版本，以免界面默认值升级后，配置生成器仍写入旧版本。
        var quotioEnvConfig: [String: String] = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": config.apiKey,
            "ANTHROPIC_MODEL": effectiveDefaultModel,
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": String(config.effectiveClaudeMaxContextTokens),
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": String(config.claudeAutoCompactPercentage),
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
            "CLAUDE_CODE_SUBAGENT_MODEL": requestModels[.haiku] ?? ""
        ]
        if config.claudeDisableAutoCompact {
            quotioEnvConfig["DISABLE_AUTO_COMPACT"] = "1"
        }

        for slot in ModelSlot.allCases {
            let requestModel = requestModels[slot] ?? AvailableModel.defaultModels[slot]!.name
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            quotioEnvConfig[key] = requestModel

            // 官方 _NAME 控制模型选择器标题，_DESCRIPTION 同时用于 /model 的补全说明。
            // 仅设置映射时，Claude Code 会显示「Custom Opus/Sonnet/Haiku model」。
            // 名称可由用户单独编辑；说明同时保留实际 ID，让补全菜单也能区分展示名与请求目标。
            let displayName = config.claudeDisplayName(for: slot)
            quotioEnvConfig[key + "_NAME"] = displayName
            quotioEnvConfig[key + "_DESCRIPTION"] = displayName == requestModel
                ? requestModel
                : "\(displayName) · \(requestModel)"
        }

        // JSON 与 Shell 导出共用同一份字段，保证两种配置方式的映射和显示完全一致。
        // 单引号保护模型 ID 和凭据中的 $、反引号等字符；内嵌单引号拆分后再拼接。
        let shellExports = "# CLIProxyAPI Configuration for Claude Code\n" + quotioEnvConfig.keys.sorted().map { key in
            let value = quotioEnvConfig[key]!.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "export \(key)='\(value)'"
        }.joined(separator: "\n")

        do {
            // Read existing settings.json to preserve user configuration
            // This preserves: permissions, hooks, mcpServers, statusLine, plugins, etc.
            var existingConfig: [String: Any] = [:]
            if fileManager.fileExists(atPath: configPath),
               let existingData = fileManager.contents(atPath: configPath),
               let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                existingConfig = parsed
            }

            // Merge env object: preserve user's existing env keys, update only Quotio-managed keys.
            // `DISABLE_AUTO_COMPACT` has no false value: remove a stale Quotio entry
            // before merging when the user re-enables automatic compaction.
            var mergedEnv = existingConfig["env"] as? [String: String] ?? [:]
            if !config.claudeDisableAutoCompact {
                mergedEnv.removeValue(forKey: "DISABLE_AUTO_COMPACT")
            }
            for (key, value) in quotioEnvConfig {
                mergedEnv[key] = value
            }
            existingConfig["env"] = mergedEnv

            // Update model field (other top-level keys are automatically preserved)
            existingConfig["model"] = effectiveDefaultModel

            // Generate JSON from merged config
            let jsonData = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            let shellProfilePath = ShellType.zsh.profilePath
            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "settings.json",
                    targetPath: configPath,
                    instructions: "Option 1: Save as ~/.claude/settings.json"
                ),
                RawConfigOutput(
                    format: .shellExport,
                    content: shellExports,
                    filename: nil,
                    targetPath: shellProfilePath,
                    instructions: "Option 2: Add to your shell profile"
                )
            ]
            
            if mode == .automatic {
                var backupPath: String? = nil
                let shouldWriteJson = storageOption == .jsonOnly || storageOption == .both
                
                if shouldWriteJson {
                    try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
                    
                    // 重新配置必须先成功备份；重名时顺延时间戳，不覆盖已有备份。
                    backupPath = try backupIfPresent(configPath)
                    
                    try jsonData.write(to: URL(fileURLWithPath: configPath))
                }
                
                let instructions: String
                switch storageOption {
                case .jsonOnly:
                    instructions = "Configuration saved to ~/.claude/settings.json"
                case .shellOnly:
                    instructions = "Shell exports ready. Add to your shell profile to complete setup."
                case .both:
                    instructions = "Configuration saved to ~/.claude/settings.json and shell profile updated."
                }
                
                return .success(
                    type: .both,
                    mode: mode,
                    configPath: shouldWriteJson ? configPath : nil,
                    shellConfig: (storageOption == .shellOnly || storageOption == .both) ? shellExports : nil,
                    rawConfigs: rawConfigs,
                    instructions: instructions,
                    modelsConfigured: 3,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .both,
                    mode: mode,
                    configPath: configPath,
                    shellConfig: shellExports,
                    rawConfigs: rawConfigs,
                    instructions: "Choose one option: save settings.json OR add shell exports to your profile:",
                    modelsConfigured: 3
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }
    
    private func generateCodexConfig(config: AgentConfiguration, mode: ConfigurationMode) async throws -> AgentConfigResult {
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
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        
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

    private func backupIfPresent(_ path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        var timestamp = Int(Date().timeIntervalSince1970)
        var backupPath = "\(path).backup.\(timestamp)"
        while fileManager.fileExists(atPath: backupPath) {
            timestamp += 1
            backupPath = "\(path).backup.\(timestamp)"
        }
        try fileManager.copyItem(atPath: path, toPath: backupPath)
        return backupPath
    }
    
    private func generateOpenCodeConfig(config: AgentConfiguration, mode: ConfigurationMode, availableModels: [AvailableModel]) -> AgentConfigResult {
        let home = homeDirectory.path
        let configDir = "\(home)/.config/opencode"
        let configPath = "\(configDir)/opencode.json"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")

        // Convert available models to OpenCode format dynamically
        var quotioModels: [String: [String: Any]] = [:]
        let modelsToUse = availableModels.isEmpty ? AvailableModel.allModels : availableModels

        for model in modelsToUse {
            quotioModels[model.name] = buildOpenCodeModelConfig(for: model.name)
        }

        let quotioProvider: [String: Any] = [
            "models": quotioModels,
            "name": "Quotio",
            "npm": "@ai-sdk/anthropic",
            "options": [
                "apiKey": config.apiKey,
                "baseURL": "\(baseURL)/v1",
                "litellmProxy": true
            ]
        ]

        do {
            let existingData = fileManager.contents(atPath: configPath)

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
                    instructions: "Configuration updated. Run 'opencode' and use /models to select a model (e.g., quotio/\(modelsToUse.first?.name ?? "model")).",
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

        let openaiBaseURL = "\(config.proxyURL.replacingOccurrences(of: "/v1", with: ""))/v1"

        // Convert available models to Factory Droid format dynamically
        let modelsToUse = availableModels.isEmpty ? AvailableModel.allModels : availableModels
        let customModels: [[String: Any]] = modelsToUse.map { model in
            [
                "model": model.name,
                "model_display_name": model.name,
                "base_url": openaiBaseURL,
                "api_key": config.apiKey,
                "provider": "openai"
            ]
        }

        let factoryConfig: [String: Any] = ["custom_models": customModels]

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

                var backupPath: String? = nil
                if fileManager.fileExists(atPath: configPath) {
                    backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                    try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
                }

                try jsonData.write(to: URL(fileURLWithPath: configPath))

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
    
    /// Fetches the proxy's OpenAI-compatible `/v1/models` response exactly as reported.
    ///
    /// Nothing is substituted, cached or filtered: the result is the response body
    /// and nothing else, and any transport/decoding problem is thrown rather than
    /// masked. Callers that must show whether a catalog is genuinely live use this;
    /// `fetchAvailableModels(config:)` layers agent-setup-specific filtering on top.
    func fetchModelCatalog(config: AgentConfiguration) async throws -> [ModelCatalogEntry] {
        guard let url = URL(string: "\(config.proxyURL)/models") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let proxyConfig = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
        let session = URLSession(configuration: proxyConfig)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Parse OpenAI-compatible /v1/models response
        return try ModelCatalog.parse(data)
    }

    func fetchAvailableModels(config: AgentConfiguration) async throws -> [AvailableModel] {
        let parsedModels = ModelCatalog.agentSetupModels(from: try await fetchModelCatalog(config: config))

        // Fetch available Copilot models to filter out unavailable ones
        let copilotFetcher = CopilotQuotaFetcher()
        let availableCopilotModelIds = await copilotFetcher.fetchUserAvailableModelIds()

        return parsedModels.filter { model in
            // Filter GitHub Copilot models - only include those actually available to the user
            // If no Copilot accounts, still show the model (user might add account later)
            if model.provider == "github-copilot", !availableCopilotModelIds.isEmpty {
                return availableCopilotModelIds.contains(model.id)
            }
            return true
        }
    }
    
    func testConnection(agent: CLIAgent, config: AgentConfiguration) async -> ConnectionTestResult {
        let startTime = Date()
        
        guard let url = URL(string: "\(config.proxyURL)/models") else {
            return ConnectionTestResult(
                success: false,
                message: "Invalid proxy URL",
                latencyMs: nil,
                modelResponded: nil
            )
        }
        
        var request = URLRequest(url: url)
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        do {
            let proxyConfig = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
            let session = URLSession(configuration: proxyConfig)
            let (data, response) = try await session.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                return ConnectionTestResult(
                    success: false,
                    message: "Invalid response",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]],
                   let firstModel = models.first?["id"] as? String {
                    return ConnectionTestResult(
                        success: true,
                        message: "Connected successfully",
                        latencyMs: latencyMs,
                        modelResponded: firstModel
                    )
                }
                return ConnectionTestResult(
                    success: true,
                    message: "Connected successfully",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            } else {
                var errorMessage = "HTTP \(httpResponse.statusCode)"
                
                // Try to parse detailed error message from proxy response (OpenAI format)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any],
                   let detailedMessage = errorObj["message"] as? String {
                    errorMessage = detailedMessage
                }
                
                return ConnectionTestResult(
                    success: false,
                    message: errorMessage,
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }
        } catch {
            return ConnectionTestResult(
                success: false,
                message: error.localizedDescription,
                latencyMs: nil,
                modelResponded: nil
            )
        }
    }
}
