import Foundation

/// 服务商与协议家族的展示名归一规则。
///
/// CPA 的用量事件和凭据列表只携带协议家族（如 `claude`、`openai-compatibility`），
/// `/v1/models` 的 `owned_by` 也常是小写标识。这里集中维护：
/// 1. 已知品牌与协议家族的规范大小写（Anthropic、OpenAI、GitHub Copilot 等）；
/// 2. 从模型 ID / 文件名特征识别跨协议第三方品牌（GLM、DeepSeek、Moonshot 等）；
/// 3. 未知英文标识的兜底分段首字母大写。
/// 归一只影响展示文本，不参与身份匹配、分组键或路由逻辑。
nonisolated enum ProviderDisplayName {
    /// 已知品牌与协议家族的规范展示名，键为小写标识。
    private static let canonicalNames: [String: String] = [
        "anthropic": "Anthropic",
        "claude": "Claude",
        "openai": "OpenAI",
        "codex": "Codex",
        "gemini": "Gemini",
        "google": "Google",
        "vertex": "Vertex AI",
        "github-copilot": "GitHub Copilot",
        "copilot": "GitHub Copilot",
        "deepseek": "DeepSeek",
        "moonshot": "Moonshot",
        "kimi": "Moonshot",
        "glm": "GLM",
        "zhipu": "GLM",
        "zhipuai": "GLM",
        "qwen": "Qwen",
        "minimax": "MiniMax",
        "grok": "Grok",
        "xai": "Grok",
        "openrouter": "OpenRouter",
        "antigravity": "Antigravity",
        "iflow": "iFlow",
        "kiro": "Kiro",
        "warp": "Warp",
        "clinepass": "ClinePass",
        // openai-compatibility 是 CPA 的协议家族而非品牌，用本地化短语表达兼容语义。
        "openai-compatibility": "provider.family.openaiCompatibility".localizedStatic(),
    ]

    /// 从任意标识（模型 ID、凭据文件名、归属文本）识别第三方品牌特征。
    /// 与 `ModelCatalogEntry.refinedOwner` 共用同一套特征规则，保证目录与路由页口径一致。
    static func brandHint(in identifier: String) -> String? {
        let lower = identifier.lowercased()
        // 智谱 GLM 系列（glm-4、glm-5.3、glm/glm-5.3、cogview、charglm）
        if lower.contains("glm") || lower.contains("zhipu") || lower.hasPrefix("cogview") || lower.hasPrefix("charglm") {
            return "GLM"
        }
        // DeepSeek 系列
        if lower.contains("deepseek") {
            return "DeepSeek"
        }
        // Moonshot / Kimi 系列
        if lower.contains("moonshot") || lower.contains("kimi") {
            return "Moonshot"
        }
        // MiniMax 系列
        if lower.contains("minimax") || lower.hasPrefix("abab") {
            return "MiniMax"
        }
        // Qwen 通义千问系列
        if lower.contains("qwen") {
            return "Qwen"
        }
        return nil
    }

    /// 任意归属标识 → 展示名。已知品牌返回规范名；含品牌特征的复合标识返回品牌名；
    /// 其余英文标识按 `-`/`_`/空格分段并首字母大写。
    static func normalize(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let key = trimmed.lowercased()
        if let known = canonicalNames[key] { return known }
        if let hint = brandHint(in: trimmed) { return hint }
        // 兜底分段大写："my-proxy-lab" → "My Proxy Lab"；单段 "siliconflow" → "Siliconflow"。
        return trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// 用量事件侧的上游品牌名：优先用模型 ID 特征识别跨协议接入的第三方模型，
    /// 无特征时回退协议家族规范名（原生 Claude / OpenAI 模型不含第三方特征）。
    static func eventProviderName(provider: String, model: String?) -> String {
        if let model, let brand = brandHint(in: model) {
            return brand
        }
        return normalize(provider)
    }
}
