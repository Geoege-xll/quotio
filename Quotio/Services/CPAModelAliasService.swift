import Foundation
import CryptoKit
import Yams

/// 参考 EasyCLIProxyAPI 的 core_config/aliases.rs：配置来源优先、按协议写入 override，
/// OAuth 注册表先通过专用接口刷新，再保存 YAML。这里不增加独立于 CPA 的默认策略。
actor CPAModelAliasService {
    private let client: ManagementAPIClient
    private var isSaving = false

    init(client: ManagementAPIClient) { self.client = client }

    private struct Channel {
        let key: String
        let protocolName: String
    }

    private let channels: [Channel] = [
        .init(key: "vertex", protocolName: "gemini"), .init(key: "aistudio", protocolName: "gemini"),
        .init(key: "antigravity", protocolName: "antigravity"), .init(key: "claude", protocolName: "claude"),
        .init(key: "codex", protocolName: "codex"), .init(key: "kimi", protocolName: "openai"),
        .init(key: "xai", protocolName: "codex")
    ]
    private let sections = [
        ("codex-api-key", "Codex API", "codex-api", "codex"),
        ("openai-compatibility", "OpenAI API", "openai-compatible", "openai"),
        ("claude-api-key", "Claude API", "claude-api", "claude"),
        ("gemini-api-key", "Gemini API", "gemini-api", "gemini")
    ]

    private func usesV8(_ root: [String: Any]) -> Bool {
        CPAConfigLayout.isMigratedV8(root)
    }

    /// v8 的 API 密钥分组位于 api-keys 下，旧字段只供尚未迁移的配置读取。
    /// 来源 ID 保留完整路径，创建和删除时不会把新别名写回失效的顶层旧字段。
    private func sectionPath(_ legacy: String, in root: [String: Any]) -> String {
        guard usesV8(root) else { return legacy }
        let family: String
        switch legacy {
        case "codex-api-key": family = "codex"
        case "claude-api-key": family = "claude"
        case "gemini-api-key": family = "gemini"
        default: family = legacy
        }
        return "api-keys.\(family)"
    }

    private func providers(_ section: String, in root: [String: Any]) -> [[String: Any]] {
        guard section.hasPrefix("api-keys.") else { return root[section] as? [[String: Any]] ?? [] }
        let families = root["api-keys"] as? [String: Any] ?? [:]
        return families[String(section.dropFirst("api-keys.".count))] as? [[String: Any]] ?? []
    }

    private func setProviders(_ groups: [[String: Any]], section: String, in root: inout [String: Any]) {
        guard section.hasPrefix("api-keys.") else { root[section] = groups; return }
        var families = root["api-keys"] as? [String: Any] ?? [:]
        families[String(section.dropFirst("api-keys.".count))] = groups
        root["api-keys"] = families
    }

    private func oauthAliases(in root: [String: Any]) -> [String: Any] {
        if usesV8(root) {
            let oauth = root["oauth"] as? [String: Any] ?? [:]
            return oauth["model-alias"] as? [String: Any] ?? [:]
        }
        return root["oauth-model-alias"] as? [String: Any] ?? [:]
    }

    private func setOAuthAliases(_ aliases: [String: Any], in root: inout [String: Any]) {
        if usesV8(root) {
            var oauth = root["oauth"] as? [String: Any] ?? [:]
            oauth["model-alias"] = aliases
            root["oauth"] = oauth
        } else { root["oauth-model-alias"] = aliases }
    }

    private func payload(in root: [String: Any]) -> [String: Any] {
        if usesV8(root) {
            let requests = root["requests"] as? [String: Any] ?? [:]
            return requests["payload"] as? [String: Any] ?? [:]
        }
        return root["payload"] as? [String: Any] ?? [:]
    }

    private func setPayload(_ payload: [String: Any], in root: inout [String: Any]) {
        if usesV8(root) {
            var requests = root["requests"] as? [String: Any] ?? [:]
            requests["payload"] = payload
            root["requests"] = requests
        } else { root["payload"] = payload }
    }

    private func failure(_ key: String) -> NSError {
        NSError(domain: "CPAModelAliases", code: 1, userInfo: [NSLocalizedDescriptionKey: key.localizedStatic()])
    }

    private func revision(_ yaml: String) -> String {
        SHA256.hash(data: Data(yaml.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func parse(_ yaml: String) throws -> [String: Any] {
        // 完整解析器保留未被 UI 建模的字段；拒绝非映射配置，不靠正则改写敏感配置内容。
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw failure("cpaAliases.invalidConfig")
        }
        return root
    }

    private func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func identity(_ value: Any) -> (name: String, alias: String)? {
        if let name = text(value) { return (name, name) }
        guard let item = value as? [String: Any], let name = text(item["name"]) else { return nil }
        return (name, text(item["alias"]) ?? name)
    }

    private func levels(_ value: Any?, protocolName: String, apiFallback: Bool) -> [String] {
        let item = value as? [String: Any] ?? [:]
        let thinking = item["thinking"] as? [String: Any] ?? [:]
        let raw = thinking["levels"] as? [String] ?? item["reasoning_levels"] as? [String] ?? []
        var seen = Set<String>()
        let result = raw.compactMap(text).map { $0.lowercased() }.filter { seen.insert($0).inserted }
        // 与官方当前 API 来源兼容回退一致；OAuth 不猜测等级，只使用模型定义。
        return result.isEmpty && apiFallback && ["codex", "openai"].contains(protocolName)
            ? ["low", "medium", "high", "xhigh", "max"] : result
    }

    func load() async throws -> CPAModelAliasSnapshot {
        let yaml = try await client.fetchModelAliasYAML()
        let root = try parse(yaml)
        let catalog = Set(try await client.fetchModelAliasCatalog().map { $0.lowercased() })
        var sources: [CPAModelAliasSource] = []
        for (legacySection, fallback, kind, protocolName) in sections {
            let section = sectionPath(legacySection, in: root)
            for (providerIndex, rawProvider) in providers(section, in: root).enumerated() {
                guard rawProvider["disabled"] as? Bool != true else { continue }
                let provider = text(rawProvider["name"]) ?? "\(fallback) \(providerIndex + 1)"
                for (modelIndex, rawModel) in (rawProvider["models"] as? [Any] ?? []).enumerated() {
                    guard let model = identity(rawModel), catalog.contains(model.alias.lowercased()) else { continue }
                    if model.name != model.alias, effort(root, alias: model.alias, protocolName: protocolName) != nil { continue }
                    sources.append(.init(
                        id: "\(section):\(providerIndex):\(modelIndex)", model: model.alias, provider: provider,
                        kind: kind, protocolName: protocolName,
                        levels: levels(rawModel, protocolName: protocolName, apiFallback: true),
                        channel: nil, section: section, providerIndex: providerIndex, modelIndex: modelIndex
                    ))
                }
            }
        }
        let configuredCodex = Set(sources.filter { $0.kind == "codex-api" }.map { $0.model.lowercased() })
        let authFiles = try? await client.fetchAuthFiles()
        let active = authFiles.map { files in Set(files.filter { !$0.disabled }.map { normalizedChannel($0.provider) }) }
        var unavailable: [String] = []
        for channel in channels where active == nil || active!.contains(channel.key) {
            do {
                let data = try await client.fetchModelAliasDefinitions(channel: channel.key)
                let object = try JSONSerialization.jsonObject(with: data)
                let wrapper = object as? [String: Any]
                guard let definitions = object as? [[String: Any]] ?? wrapper?["models"] as? [[String: Any]] ?? wrapper?["data"] as? [[String: Any]] else {
                    throw failure("cpaAliases.invalidConfig")
                }
                for definition in definitions {
                    guard let name = text(definition["id"]), catalog.contains(name.lowercased()),
                          channel.key != "codex" || !configuredCodex.contains(name.lowercased()) else { continue }
                    sources.append(.init(
                        id: "\(channel.key)-oauth:\(name)", model: name, provider: "\(channel.key) OAuth",
                        kind: "\(channel.key)-oauth", protocolName: channel.protocolName,
                        levels: levels(definition, protocolName: channel.protocolName, apiFallback: false),
                        channel: channel.key, section: nil, providerIndex: nil, modelIndex: nil
                    ))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable.append(channel.key) }
        }
        try Task.checkCancellation()
        return .init(revision: revision(yaml), sources: sources.sorted { $0.id < $1.id },
                     aliases: aliases(root), unavailableChannels: unavailable)
    }

    private func normalizedChannel(_ provider: String) -> String {
        switch provider.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "vertex-ai": return "vertex"
        case "gemini", "gemini-cli", "ai-studio": return "aistudio"
        case "anthropic": return "claude"
        case "anti-gravity": return "antigravity"
        case "moonshot": return "kimi"
        case "grok", "x-ai": return "xai"
        default: return provider.lowercased()
        }
    }

    private func effort(_ root: [String: Any], alias: String, protocolName: String) -> String? {
        let payload = payload(in: root)
        for rule in payload["override"] as? [[String: Any]] ?? [] {
            let models = rule["models"] as? [[String: Any]] ?? []
            guard models.contains(where: {
                text($0["name"])?.lowercased() == alias.lowercased()
                    && text($0["protocol"])?.lowercased() == protocolName.lowercased()
            }), let params = rule["params"] as? [String: Any] else { continue }
            for key in ["reasoning.effort", "reasoning_effort", "output_config.effort", "generationConfig.thinkingConfig.thinkingLevel", "thinking.effort"] {
                if let value = text(params[key]) { return value.lowercased() }
            }
            if text(params["thinking.type"]) == "disabled" { return "none" }
            if protocolName == "claude", text(params["thinking.type"]) == "adaptive" { return "auto" }
        }
        return nil
    }

    private func aliases(_ root: [String: Any]) -> [CPAModelAlias] {
        var result: [CPAModelAlias] = []
        for (channel, raw) in oauthAliases(in: root) {
            let protocolName = channels.first { $0.key == channel }?.protocolName ?? channel
            for (index, value) in (raw as? [[String: Any]] ?? []).enumerated() {
                guard let model = identity(value), model.alias != model.name else { continue }
                result.append(.init(id: "oauth:\(channel):\(index)", model: model.name, alias: model.alias,
                                    provider: "\(channel) OAuth", protocolName: protocolName,
                                    effort: effort(root, alias: model.alias, protocolName: protocolName),
                                    channel: channel, section: nil, providerIndex: nil, modelIndex: index))
            }
        }
        for (legacySection, fallback, _, protocolName) in sections {
            let section = sectionPath(legacySection, in: root)
            for (providerIndex, provider) in providers(section, in: root).enumerated() {
                for (index, value) in (provider["models"] as? [Any] ?? []).enumerated() {
                    guard let model = identity(value), model.alias != model.name else { continue }
                    result.append(.init(id: "\(section):\(providerIndex):\(index)", model: model.name, alias: model.alias,
                                        provider: text(provider["name"]) ?? "\(fallback) \(providerIndex + 1)", protocolName: protocolName,
                                        effort: effort(root, alias: model.alias, protocolName: protocolName),
                                        channel: nil, section: section, providerIndex: providerIndex, modelIndex: index))
                }
            }
        }
        return result.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    func create(source: CPAModelAliasSource, alias rawAlias: String, effort rawEffort: String, expectedRevision: String) async throws {
        guard !isSaving else { throw failure("cpaAliases.busy") }
        isSaving = true
        defer { isSaving = false }
        let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedEffort = rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !alias.isEmpty, alias.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !alias.contains("*"), !alias.contains("?"), !alias.contains("("), !alias.contains(")"),
              alias.caseInsensitiveCompare(source.model) != .orderedSame else { throw failure("cpaAliases.invalidAlias") }
        let fresh = try await load()
        guard fresh.revision == expectedRevision, fresh.sources.contains(source) else { throw failure("cpaAliases.changed") }
        guard selectedEffort.isEmpty || source.levels.contains(selectedEffort) else { throw failure("cpaAliases.unsupportedEffort") }
        let catalog = try await client.fetchModelAliasCatalog()
        guard !catalog.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }),
              !fresh.aliases.contains(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) else { throw failure("cpaAliases.duplicate") }
        let yaml = try await client.fetchModelAliasYAML()
        guard revision(yaml) == expectedRevision else { throw failure("cpaAliases.changed") }
        var root = try parse(yaml)
        if let channel = source.channel {
            var oauth = oauthAliases(in: root)
            var entries = oauth[channel] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["name": source.model, "alias": alias, "fork": true]
            if channel == "antigravity" { entry["force-mapping"] = true }
            entries.append(entry)
            oauth[channel] = entries
            setOAuthAliases(oauth, in: &root)
        } else {
            guard let section = source.section, let p = source.providerIndex, let m = source.modelIndex else {
                throw failure("cpaAliases.changed")
            }
            var groups = providers(section, in: root)
            guard groups.indices.contains(p),
                  var models = groups[p]["models"] as? [Any], models.indices.contains(m),
                  let original = identity(models[m]), original.alias == source.model else { throw failure("cpaAliases.changed") }
            var entry = models[m] as? [String: Any] ?? ["name": original.name]
            entry["alias"] = alias
            if !selectedEffort.isEmpty, let display = text(entry["display-name"]) { entry["display-name"] = "\(display) (\(selectedEffort))" }
            models.append(entry)
            groups[p]["models"] = models
            setProviders(groups, section: section, in: &root)
        }
        if !selectedEffort.isEmpty {
            var payload = payload(in: root)
            var rules = payload["override"] as? [[String: Any]] ?? []
            rules.append(["models": [["name": alias, "protocol": source.protocolName]],
                          "params": params(source: source, effort: selectedEffort)])
            payload["override"] = rules
            setPayload(payload, in: &root)
        }
        try await persist(root, previousYAML: yaml, oauthChanged: source.channel != nil)
    }

    private func params(source: CPAModelAliasSource, effort: String) -> [String: String] {
        switch source.kind {
        case "claude-oauth", "claude-api":
            if effort == "none" { return ["thinking.type": "disabled"] }
            return effort == "auto" ? ["thinking.type": "adaptive"] : ["thinking.type": "adaptive", "output_config.effort": effort]
        case "aistudio-oauth", "vertex-oauth", "gemini-api", "antigravity-oauth":
            return ["generationConfig.thinkingConfig.thinkingLevel": effort]
        case "kimi-oauth":
            return effort == "none" ? ["thinking.type": "disabled"] : ["thinking.type": "enabled", "thinking.effort": effort]
        case "openai-compatible":
            var result = ["reasoning_effort": effort]
            if source.model.lowercased().hasPrefix("deepseek") { result["thinking.type"] = "enabled" }
            return result
        default: return ["reasoning.effort": effort]
        }
    }

    func delete(_ entry: CPAModelAlias, expectedRevision: String) async throws {
        guard !isSaving else { throw failure("cpaAliases.busy") }
        isSaving = true
        defer { isSaving = false }
        let yaml = try await client.fetchModelAliasYAML()
        guard revision(yaml) == expectedRevision else { throw failure("cpaAliases.changed") }
        var root = try parse(yaml)
        guard aliases(root).contains(entry) else { throw failure("cpaAliases.changed") }
        if let channel = entry.channel {
            var oauth = oauthAliases(in: root)
            var entries = oauth[channel] as? [[String: Any]] ?? []
            entries.remove(at: entry.modelIndex)
            oauth[channel] = entries
            setOAuthAliases(oauth, in: &root)
        } else if let section = entry.section, let p = entry.providerIndex {
            var groups = providers(section, in: root)
            guard groups.indices.contains(p), var models = groups[p]["models"] as? [Any],
                  models.indices.contains(entry.modelIndex) else { throw failure("cpaAliases.changed") }
            models.remove(at: entry.modelIndex)
            groups[p]["models"] = models
            setProviders(groups, section: section, in: &root)
        }
        // 别名删除后只移除对应的规则目标；共享规则中的其他模型和参数完整保留。
        // 若另一来源仍使用同一别名，不能删除仍在生效的共享 payload 策略。
        if !aliases(root).contains(where: { $0.alias.caseInsensitiveCompare(entry.alias) == .orderedSame }) {
            var payload = payload(in: root)
            if let rules = payload["override"] as? [[String: Any]] {
                payload["override"] = rules.compactMap { rule -> [String: Any]? in
                    guard let models = rule["models"] as? [[String: Any]] else { return rule }
                    let kept = models.filter { text($0["name"])?.lowercased() != entry.alias.lowercased() }
                    guard !kept.isEmpty else { return nil }
                    var copy = rule
                    copy["models"] = kept
                    return copy
                }
                setPayload(payload, in: &root)
            }
        }
        try await persist(root, previousYAML: yaml, oauthChanged: entry.channel != nil)
    }

    private func persist(_ root: [String: Any], previousYAML: String, oauthChanged: Bool) async throws {
        // 保存前再次检查乐观版本，避免覆盖其他客户端刚写入的配置。
        // CPA 的两个接口不提供跨请求事务；第二步失败必须明确报告部分保存，不能虚报成功。
        guard try await client.fetchModelAliasYAML() == previousYAML else { throw failure("cpaAliases.changed") }
        let isV8 = usesV8(root)
        if isV8 {
            // v8 只更新发生变化的别名列表和 override 列表；官方接口负责校验、保存与重载。
            // 整份 Yams.dump 会让无关服务商、密钥和注释失去原来的表示方式。
            let previous = try parse(previousYAML)
            typealias Change = (path: [String], before: Data?, after: Data?)
            func encoded(_ value: Any?) throws -> Data? {
                guard let value else { return nil }
                return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            }
            var changes: [Change] = []
            func appendIfChanged(_ path: [String], old: Any?, new: Any?) throws {
                let before = try encoded(old), after = try encoded(new)
                if before != after { changes.append((path, before, after)) }
            }
            try appendIfChanged(["oauth", "model-alias"], old: oauthAliases(in: previous), new: oauthAliases(in: root))
            for (legacy, _, _, _) in sections {
                let section = sectionPath(legacy, in: root)
                let family = String(section.dropFirst("api-keys.".count))
                try appendIfChanged(["api-keys", family], old: providers(section, in: previous), new: providers(section, in: root))
            }
            try appendIfChanged(["requests", "payload", "override"],
                                old: payload(in: previous)["override"], new: payload(in: root)["override"])
            var completed: [Change] = []
            do {
                for change in changes {
                    try await client.putV8Config(path: change.path, body: change.after)
                    completed.append(change)
                }
            } catch {
                let originalError = error
                // 多个路径写入不是事务；后一步失败时尽力逆序恢复，并明确报告恢复失败。
                var rollbackFailed = false
                for change in completed.reversed() {
                    do { try await client.putV8Config(path: change.path, body: change.before) }
                    catch { rollbackFailed = true }
                }
                if rollbackFailed { throw failure("cpaAliases.partialSave") }
                throw originalError
            }
            return
        }
        let updated = try Yams.dump(object: root)
        if oauthChanged && !isV8 {
            let data = try JSONSerialization.data(withJSONObject: oauthAliases(in: root))
            try await client.replaceOAuthModelAliases(data)
        }
        do { try await client.saveModelAliasYAML(updated) }
        catch {
            if oauthChanged && !isV8 { throw failure("cpaAliases.partialSave") }
            throw error
        }
    }
}
