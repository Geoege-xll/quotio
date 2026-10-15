// Claude 模型说明和 Magpie 菜单格式化规则同时服务预览与文件生成，归入共享客户端模型。
// 本次整文件迁移并保留全部原实现；只读展示不改变模型请求 ID、账号路由或外部菜单中的未知字段。

import Foundation

/// Claude 的展示元数据规则，不参与模型选择、账号路由或请求 ID 的改写。
/// 固定角色使用“平台/模型”，Magpie 追加项使用“模型名称｜平台与账号”。
nonisolated enum ClaudeModelPresentation {
    static func platformSlug(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, !raw.contains("/"), !raw.contains("@"), !raw.contains(":"),
              !raw.contains("\n"), !raw.contains("\r") else { return nil }
        switch raw {
        case "google", "gemini", "google-ai": return "google"
        case "zhipu", "zhipuai", "zhipu glm", "glm", "智谱": return "zhipu"
        case "claude", "anthropic": return "anthropic"
        case "github-copilot", "github copilot", "copilot": return "copilot"
        default: return raw.replacingOccurrences(of: " ", with: "-")
        }
    }

    /// 已带平台前缀的 ID 直接展示；裸 ID 只使用目录明确归属或之前保存的匹配提示。
    /// owned_by 仅是展示归属，不代表会由哪个账号服务；来源有冲突时不任选一个平台。
    static func platformModel(_ selector: String, availableModels: [AvailableModel] = [], hints: [String: String] = [:]) -> String {
        let parsed = AgentConfiguration.normalizedClaudeModelID(selector)
        let normalized = parsed.base + (parsed.uses1M ? "[1m]" : "")
        guard !parsed.base.isEmpty, !parsed.base.contains("/") else { return normalized }
        let matches = availableModels.filter {
            AgentConfiguration.normalizedClaudeModelID($0.id).base == parsed.base
                || AgentConfiguration.normalizedClaudeModelID($0.name).base == parsed.base
        }
        let platforms = Set(matches.compactMap { $0.displayPlatform.flatMap(platformSlug) })
        guard platforms.count <= 1 else { return normalized }
        guard let platform = platforms.first ?? hints[parsed.base].flatMap(platformSlug) else { return normalized }
        return platform + "/" + normalized
    }

    /// 只从“平台/同一个实际模型”恢复提示，普通自定义说明或另一模型的旧说明不能成为平台来源。
    static func platformHint(model: String, description: String?) -> String? {
        let target = AgentConfiguration.normalizedClaudeModelID(model).base
        guard !target.isEmpty, !target.contains("/"), let description else { return nil }
        let parts = AgentConfiguration.normalizedClaudeModelID(description).base.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, String(parts[1]) == target else { return nil }
        return platformSlug(String(parts[0]))
    }

    private static func platformNames(_ raw: String) -> (title: String, synonyms: [String]) {
        let slug = platformSlug(raw) ?? raw
        switch slug {
        case "codex": return ("Codex", ["Codex", "OpenAI Codex"])
        case "zhipu": return ("智谱", ["智谱", "Zhipu", "Zhipu GLM", "GLM"])
        case "google": return ("Google", ["Google", "Gemini"])
        case "anthropic": return ("Anthropic", ["Anthropic", "Claude"])
        case "copilot": return ("GitHub Copilot", ["GitHub Copilot", "Copilot"])
        case "openai": return ("OpenAI", ["OpenAI"])
        case "antigravity": return ("Antigravity", ["Antigravity"])
        case "group": return ("路由组", ["routing group", "路由组"])
        default: return (raw.capitalized, [raw, raw.capitalized])
        }
    }

    /// 仅处理带 Magpie 明确说明标记的条目；用户自定义文本和已经格式化的条目不会被再次改写。
    /// 账号直接来自该条目的既有说明，不读取本机登录账号来填充，更不把目录 owned_by 当成账号。
    static func magpieOption(_ option: ClaudeModelPickerOption) -> ClaudeModelPickerOption? {
        let note = option.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = " · via magpie"
        guard note == "via magpie" || note.hasSuffix(marker) else { return nil }
        let parsed = AgentConfiguration.normalizedClaudeModelID(option.selector)
        let parts = parsed.base.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let slug = platformSlug(String(parts[0])) else { return nil }
        let platform = platformNames(slug)
        var result = option
        var label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in platform.synonyms {
            let ending = " · " + suffix
            if label.lowercased().hasSuffix(ending.lowercased()) {
                label = String(label.dropLast(ending.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if label.isEmpty { label = String(parts[1]) }
        if parsed.uses1M, !label.lowercased().hasSuffix("[1m]") { label += "[1m]" }
        var account = note == "via magpie" ? "" : String(note.dropLast(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        for name in platform.synonyms {
            if account.caseInsensitiveCompare(name) == .orderedSame { account = ""; break }
            let prefix = name + " · "
            if account.lowercased().hasPrefix(prefix.lowercased()) {
                account = String(account.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        result.label = label
        result.description = platform.title + (account.isEmpty ? "" : " · " + account)
        return result
    }

    /// 对磁盘菜单仅修改可识别行的 label/description；不重建菜单、不排序、不去重。
    /// 未知结构整段保留，所有扩展字段与原始请求选择器仍由原 JSON 对象持有。
    static func formattedMagpieMenu(_ object: Any) -> Any {
        guard ClaudeModelPickerConfiguration.read(object).mode != .external,
              var menu = object as? [String: Any], var rows = menu["options"] as? [[String: Any]] else { return object }
        for index in rows.indices {
            guard let model = rows[index]["model"] as? String else { continue }
            let option = ClaudeModelPickerOption(model: model, label: rows[index]["label"] as? String ?? "",
                description: rows[index]["description"] as? String ?? "")
            guard let formatted = magpieOption(option) else { continue }
            rows[index]["label"] = formatted.label
            rows[index]["description"] = formatted.description
        }
        menu["options"] = rows
        return menu
    }
}
