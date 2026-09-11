import Foundation

/// 客户端兼容扫描和原生权限适配。统一库只保存内容；每次切换明确写入客户端原生配置，
/// 从而让 OpenCode 扫描 Claude/Codex 目录时仍遵守用户为 OpenCode 单独选择的开关。
nonisolated struct WorkspaceSkillClientConfiguration {
    let homeDir: String
    struct Change { let path: String; let data: Data }

    var configurationPaths: [String] {
        [homeDir + "/.codex/config.toml", homeDir + "/.config/opencode/opencode.json", homeDir + "/.config/opencode/opencode.jsonc"]
    }

    private var openCodePath: String {
        let jsonc = homeDir + "/.config/opencode/opencode.jsonc"
        return FileManager.default.fileExists(atPath: jsonc) ? jsonc : homeDir + "/.config/opencode/opencode.json"
    }

    private func read(_ path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // 配置文件是外部资源；遇到软链接时不隐式改写其目标，保留给用户明确处理。
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { throw WorkspaceSkillError.conflict(path) }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func change(agent: WorkspaceAgent, skillDirectory: String, skillName: String, enabled: Bool) throws -> [Change] {
        switch agent {
        case .codex:
            let path = configurationPaths[0]
            let existing = try read(path) ?? Data()
            guard let text = String(data: existing, encoding: .utf8) else { throw WorkspaceSkillError.incompleteOperation("Codex 配置不是 UTF-8") }
            let value = try WorkspaceSkillCodexConfiguration.setting(text, paths: codexPaths(skillDirectory), enabled: enabled)
            return [Change(path: path, data: Data(value.utf8))]
        case .opencode:
            // OpenCode 的权限键支持通配符；技能名称不能含模式字符，否则“精确禁用”会影响其他技能。
            guard !skillName.isEmpty, !skillName.contains(where: { "*?[]".contains($0) }) else {
                throw WorkspaceSkillError.incompleteOperation("技能名称含通配符，无法为 OpenCode 精确配置：\(skillName)")
            }
            let path = openCodePath
            return [Change(path: path, data: try OpenCodeConfigEditor.mergingSkillPermission(existing: read(path), skillName: skillName, enabled: enabled))]
        default: return []
        }
    }

    func isEnabled(agent: WorkspaceAgent, skillDirectory: String, skillName: String) throws -> Bool {
        switch agent {
        case .codex:
            guard let data = try read(configurationPaths[0]), let text = String(data: data, encoding: .utf8) else { return true }
            return try WorkspaceSkillCodexConfiguration.isEnabled(text, paths: codexPaths(skillDirectory))
        case .opencode:
            // JSONC 后载入；存在该文件但没有匹配规则时，再使用 JSON 中的有效规则。
            var action: String?
            for path in configurationPaths.dropFirst() {
                if let data = try read(path), let next = try OpenCodeConfigEditor.skillPermission(existing: data, skillName: skillName) { action = next }
            }
            return action != "deny"
        default: return true
        }
    }

    private func codexPaths(_ directory: String) -> Set<String> {
        // Codex 会规范化技能路径，不同版本可能保留发现路径或解析后的真实路径。
        // 同步三种身份，避免迁移后的旧 .codex 链接或 ~/.agents 的发现结果绕过禁用。
        Set([".quotio/skills", ".agents/skills", ".codex/skills"].map { homeDir + "/" + $0 + "/" + directory + "/SKILL.md" })
    }
}

/// 只编辑 [[skills.config]] 的 enabled 字段，保留模型、MCP、注释等其他 TOML 文本。
/// 对不能明确定位的内联数组/重复字段选择拒绝写入，避免生成重复表或误改多行提示词。
nonisolated enum WorkspaceSkillCodexConfiguration {
    private struct Block { let range: Range<Int>; let path: String; let enabledLine: Int?; let enabled: Bool }

    static func setting(_ text: String, paths: Set<String>, enabled: Bool) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let blocks = try parse(lines)
        var found: Set<String> = []
        var inserts: [(Int, String)] = []
        for block in blocks where paths.contains(block.path) {
            found.insert(block.path)
            if let index = block.enabledLine {
                let comment = commentSuffix(lines[index])
                lines[index] = "enabled = \(enabled ? "true" : "false")" + comment
            } else { inserts.append((block.range.upperBound, "enabled = \(enabled ? "true" : "false")")) }
        }
        for (index, line) in inserts.sorted(by: { $0.0 > $1.0 }) { lines.insert(line, at: index) }
        var output = lines.joined(separator: "\n")
        for path in paths.subtracting(found).sorted() {
            // TOML 不支持 JSON 的可选 \/ 转义，必须保留路径斜杠；其余 JSON 基础转义兼容 TOML basic string。
            let quoted = String(data: try JSONSerialization.data(withJSONObject: path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
            output += "\n\n[[skills.config]]\npath = \(quoted)\nenabled = \(enabled ? "true" : "false")\n"
        }
        // 再解析输出校验本次变更，不把损坏配置交给 CLI。
        guard try isEnabled(output, paths: paths) == enabled else { throw WorkspaceSkillError.incompleteOperation("Codex 技能配置校验失败") }
        return output
    }

    static func isEnabled(_ text: String, paths: Set<String>) throws -> Bool {
        !((try parse(text.components(separatedBy: "\n"))).contains { paths.contains($0.path) && !$0.enabled })
    }

    private static func parse(_ lines: [String]) throws -> [Block] {
        var headers: [(Int, String)] = []
        var multiLine: String?
        for (index, line) in lines.enumerated() {
            let structural = scan(line, multiLine: &multiLine)
            let trimmed = structural.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                let header = trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                    .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                headers.append((index, header))
            }
            // 已存在其他 TOML 形式时停止，避免向同一个 skills.config 重复追加数组表。
            if headers.isEmpty, trimmed.range(of: "^(?:skills|\"skills\"|'skills')\\s*=", options: .regularExpression) != nil {
                // TOML 内联表定义后不可在文档末尾扩展；即使原值是 skills = {} 也必须拒绝追加。
                throw WorkspaceSkillError.incompleteOperation("Codex 使用 skills 内联表，暂不能安全合并")
            }
            if trimmed.range(of: "^(?:skills\\.config|[\"']skills[\"']\\.[\"']config[\"'])\\s*=", options: .regularExpression) != nil {
                throw WorkspaceSkillError.incompleteOperation("Codex 使用内联 skills.config，暂不能安全合并")
            }
        }
        guard multiLine == nil else { throw WorkspaceSkillError.incompleteOperation("Codex TOML 多行字符串未闭合") }
        var result: [Block] = []
        for (offset, header) in headers.enumerated() {
            let end = offset + 1 < headers.count ? headers[offset + 1].0 : lines.count
            if header.1 == "[skills]", lines[(header.0 + 1)..<end].contains(where: {
                $0.trimmingCharacters(in: .whitespaces).range(of: "^[\"']?config[\"']?\\s*=", options: .regularExpression) != nil
            }) { throw WorkspaceSkillError.incompleteOperation("Codex 使用内联技能配置，暂不能安全合并") }
            guard header.1 == "[[skills.config]]" else { continue }
            var path: String?
            var enabled = true
            var enabledLine: Int?
            var localMultiLine: String?
            for index in (header.0 + 1)..<end {
                let line = scan(lines[index], multiLine: &localMultiLine)
                guard let equal = line.firstIndex(of: "=") else { continue }
                let key = line[..<equal].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "path" {
                    guard path == nil else { throw WorkspaceSkillError.incompleteOperation("Codex 技能路径字段重复") }
                    path = try parseString(value)
                } else if key == "enabled" {
                    guard enabledLine == nil, value == "true" || value == "false" else { throw WorkspaceSkillError.incompleteOperation("Codex 技能 enabled 无效或重复") }
                    enabledLine = index
                    enabled = value == "true"
                }
            }
            guard let path else { throw WorkspaceSkillError.incompleteOperation("Codex skills.config 缺少明确 path") }
            result.append(Block(range: header.0..<end, path: path, enabledLine: enabledLine, enabled: enabled))
        }
        return result
    }

    private static func parseString(_ value: String) throws -> String {
        if value.hasPrefix("'"), value.hasSuffix("'"), !value.hasPrefix("'''") { return String(value.dropFirst().dropLast()) }
        if value.hasPrefix("\""), !value.hasPrefix("\"\"\""), let data = value.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String { return parsed }
        throw WorkspaceSkillError.incompleteOperation("Codex 技能 path 必须是可解析的单行字符串")
    }

    /// 返回去除注释后的结构文本，字符串中的 # 保持原样；多行字符串内部的伪表头不会参与定位。
    private static func scan(_ line: String, multiLine: inout String?) -> String {
        var index = line.startIndex
        var quote: Character?
        var result = ""
        while index < line.endIndex {
            if let delimiter = multiLine {
                if line[index...].hasPrefix(delimiter) {
                    multiLine = nil
                    index = line.index(index, offsetBy: 3)
                } else { index = line.index(after: index) }
                continue
            }
            let character = line[index]
            if let current = quote {
                result.append(character)
                if character == "\\", current == "\"" {
                    index = line.index(after: index)
                    if index < line.endIndex { result.append(line[index]) }
                } else if character == current { quote = nil }
            } else if character == "#" { break }
            else if line[index...].hasPrefix("\"\"\"") || line[index...].hasPrefix("'''") {
                let delimiter = String(line[index..<line.index(index, offsetBy: 3)])
                multiLine = delimiter
                result += delimiter
                index = line.index(index, offsetBy: 3)
                continue
            } else {
                result.append(character)
                if character == "\"" || character == "'" { quote = character }
            }
            if index < line.endIndex { index = line.index(after: index) }
        }
        return result
    }

    private static func commentSuffix(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line.hasSuffix("\r") ? "\r" : "" }
        return " " + line[hash...]
    }
}
