import Foundation
import Yams

/// 判断磁盘文件是否已经完成 CPA 8 的结构迁移，而不是只检查声明的版本号。
/// 官方明确指出单独写入 `config-version: 8` 不会迁移旧字段；误判后继续写入会覆盖客户端密钥。
nonisolated enum CPAConfigLayout {
    enum EditError: LocalizedError {
        case invalidConfig
        case invalidPath

        var errorDescription: String? {
            switch self {
            case .invalidConfig: return "CPA 配置不是有效的 YAML 映射"
            case .invalidPath: return "CPA 配置字段路径与现有结构冲突"
            }
        }
    }

    static func isMigratedV8(_ root: [String: Any]) -> Bool {
        guard root["server"] is [String: Any], root["management"] is [String: Any] else { return false }
        if let apiKeys = root["api-keys"], !(apiKeys is [String: Any]) { return false }

        // quota-exceeded 是官方迁移后仍可能保留的兼容字段，因此不放在此列表中。
        let legacyRootFields: Set<String> = [
            "host", "port", "auth-dir", "remote-management", "proxy-url", "debug",
            "logging-to-file", "usage-statistics-enabled", "request-retry", "max-retry-interval",
            "codex-api-key", "claude-api-key", "gemini-api-key", "openai-compatibility",
            "glm-api-key", "oauth-model-alias", "payload"
        ]
        return legacyRootFields.isDisjoint(with: Set(root.keys))
    }

    /// 寻找 YAML 行尾注释；引号内的 `#` 是值的一部分，不能当注释截取。
    private static func trailingComment(in line: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"" && character == "\\" && !escaped {
                    escaped = true
                    previous = character
                    continue
                }
                if character == activeQuote && !escaped { quote = nil }
                escaped = false
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous?.isWhitespace == true {
                return String(line[index...])
            }
            previous = character
        }
        return ""
    }

    /// 将新值写入已解析的行内映射，输出仍是合法的 YAML 行内 JSON 映射。
    private static func replacing(in mapping: [String: Any], path: ArraySlice<String>, value: Any) throws -> [String: Any] {
        guard let key = path.first else { throw EditError.invalidPath }
        var result = mapping
        if path.count == 1 {
            result[key] = value
        } else {
            let child = result[key] as? [String: Any] ?? [:]
            result[key] = try replacing(in: child, path: path.dropFirst(), value: value)
        }
        return result
    }

    private static func mapping(in root: [String: Any], path: ArraySlice<String>) -> [String: Any]? {
        var current: Any = root
        for key in path {
            guard let next = (current as? [String: Any])?[key] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    /// 对 v8 配置做局部文本更新，而不是把包含密钥的整份 YAML 交给 Yams 重新输出。
    /// 此方法只写简单标量或字符串列表；用户在其他字段上的注释和格式保持逐字不变。
    static func updating(_ yaml: String, path: [String], value: Any) throws -> String {
        guard !path.isEmpty, let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw EditError.invalidConfig
        }
        var current: Any = root
        for key in path {
            guard let mapping = current as? [String: Any] else { throw EditError.invalidPath }
            guard let next = mapping[key] else { current = NSNull(); break }
            current = next
        }
        if !(current is NSNull),
           try Yams.dump(object: current) == Yams.dump(object: value) { return yaml }

        // JSON 的字符串转义和数组形式同时是合法 YAML 标量/流列表，避免手工拼接引号与反斜线。
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let literal = String(data: encoded, encoding: .utf8) else { throw EditError.invalidConfig }
        var lines = yaml.components(separatedBy: "\n")
        var scopeStart = 0
        var scopeEnd = lines.count
        var parentIndent = -1

        for (depth, key) in path.enumerated() {
            let candidates = (scopeStart..<scopeEnd).compactMap { index -> Int? in
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let indent = line.prefix { $0 == " " }.count
                return indent > parentIndent ? indent : nil
            }
            let childIndent = candidates.min() ?? max(0, parentIndent + 2)
            let match = (scopeStart..<scopeEnd).first { index in
                let line = lines[index]
                let indent = line.prefix { $0 == " " }.count
                return indent == childIndent && line.dropFirst(indent).hasPrefix("\(key):")
            }

            if let match {
                if depth == path.count - 1 {
                    let comment = trailingComment(in: lines[match])
                    let suffix = comment.isEmpty ? "" : " " + comment
                    lines[match] = String(repeating: " ", count: childIndent) + key + ": " + literal + suffix
                    break
                }
                let remainder = lines[match].dropFirst(childIndent + key.count + 1)
                    .trimmingCharacters(in: .whitespaces)
                if remainder.hasPrefix("{") {
                    // 用户手写的 `server: {port: 8317}` 是行内映射，不能在下一行插入缩进子键。
                    guard let existing = mapping(in: root, path: path[...depth]) else { throw EditError.invalidPath }
                    let updated = try replacing(in: existing, path: path[(depth + 1)...], value: value)
                    let encodedMap = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
                    guard let mapLiteral = String(data: encodedMap, encoding: .utf8) else { throw EditError.invalidConfig }
                    let comment = trailingComment(in: lines[match])
                    lines[match] = String(repeating: " ", count: childIndent) + key + ": " + mapLiteral
                        + (comment.isEmpty ? "" : " " + comment)
                    break
                }
                // 只在本级映射的缩进范围内继续查找，不能误改另一个同名子字段。
                var end = match + 1
                while end < scopeEnd {
                    let line = lines[end]
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("#") && line.prefix(while: { $0 == " " }).count <= childIndent {
                        break
                    }
                    end += 1
                }
                scopeStart = match + 1
                scopeEnd = end
                parentIndent = childIndent
            } else {
                // 缺失的后续映射一次补齐；插入在所属父节点末尾，不触碰其它段落。
                var indent = childIndent
                let added = path[depth...].enumerated().map { offset, part -> String in
                    defer { indent += 2 }
                    let suffix = offset == path.count - depth - 1 ? " " + literal : ""
                    return String(repeating: " ", count: indent) + part + ":" + suffix
                }
                lines.insert(contentsOf: added, at: scopeEnd)
                break
            }
        }
        let result = lines.joined(separator: "\n")
        guard (try Yams.load(yaml: result)) is [String: Any] else { throw EditError.invalidConfig }
        return result
    }
}
