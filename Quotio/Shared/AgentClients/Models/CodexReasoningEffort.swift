//
//  CodexReasoningEffort.swift
//  Quotio
//

import Foundation

// Codex 的推理强度属于开放取值集合，独立文件便于维护其字符串映射与配置兼容约束。
// 保留 custom(String)、空值处理、默认 high 以及单字符串 Codable，未知的用户值仍可原样往返。
// 此次不增加新的已知选项，也不改变配置生成、回读或界面显示使用的值。

// MARK: - Codex Reasoning Effort

/// Reasoning effort accepted by Codex CLI's `model_reasoning_effort` key in
/// `~/.codex/config.toml`.
///
/// Codex treats this key as an **open** set. `ReasoningEffort` in
/// `codex-rs/protocol/src/openai_models.rs` names `none`, `minimal`, `low`,
/// `medium`, `high`, `xhigh`, `max` and `ultra`, and its hand-written
/// `FromStr` maps every other non-empty string to `ReasoningEffort::Custom`;
/// only the empty string is rejected. `custom` mirrors that escape hatch so a
/// value Quotio does not know is round-tripped verbatim instead of being
/// silently replaced.
nonisolated enum CodexReasoningEffort: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
    /// A valid Codex value Quotio does not have a named case for.
    /// Never produced for a value that maps to a named case — see `init(rawValue:)`.
    case custom(String)

    /// Fails only for the empty string, which Codex itself rejects with
    /// "reasoning_effort must not be empty".
    init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "minimal": self = .minimal
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh": self = .xhigh
        case "max": self = .max
        case "ultra": self = .ultra
        case "": return nil
        default: self = .custom(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .none: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        case .ultra: return "ultra"
        case .custom(let value): return value
        }
    }

    /// The named values Quotio offers in the picker, ordered by effort.
    /// A `custom` value read from the user's config is offered alongside these.
    static let allCases: [CodexReasoningEffort] = [
        .none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra
    ]

    var id: String { rawValue }

    /// Default effort, matching the value Quotio has historically written.
    static let defaultEffort: CodexReasoningEffort = .high

    var displayName: String {
        if case .custom(let value) = self {
            return String.localizedStringWithFormat(
                "agents.reasoningEffort.custom".localizedStatic(),
                value
            )
        }
        return "agents.reasoningEffort.\(rawValue)".localizedStatic()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CodexReasoningEffort(rawValue: rawValue) ?? .defaultEffort
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

