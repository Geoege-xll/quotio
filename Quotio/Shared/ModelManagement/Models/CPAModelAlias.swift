import Foundation

/// UI 仅持有模型身份和能力，不接触完整 YAML、API Key 或 OAuth 凭据。
nonisolated struct CPAModelAliasSource: Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    let provider: String
    let kind: String
    let protocolName: String
    let levels: [String]
    let channel: String?
    let section: String?
    let providerIndex: Int?
    let modelIndex: Int?
}

nonisolated struct CPAModelAlias: Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    let alias: String
    let provider: String
    let protocolName: String
    let effort: String?
    let channel: String?
    let section: String?
    let providerIndex: Int?
    let modelIndex: Int
}

nonisolated struct CPAModelAliasSnapshot: Sendable {
    let revision: String
    let sources: [CPAModelAliasSource]
    let aliases: [CPAModelAlias]
    let unavailableChannels: [String]
}

/// 同名别名可能存在于不同来源中；只有所有匹配条目的强度一致，才显示单一确定值。
nonisolated enum CPAModelAliasPolicy {
    static func entries(for model: String, in aliases: [CPAModelAlias]) -> [CPAModelAlias] {
        aliases.filter { $0.alias.caseInsensitiveCompare(model) == .orderedSame }
    }

    static func fixedEffort(for model: String, in aliases: [CPAModelAlias]) -> String? {
        let matches = entries(for: model, in: aliases)
        guard !matches.isEmpty, matches.allSatisfy({ $0.effort != nil }) else { return nil }
        let values = Set(matches.compactMap(\.effort))
        return values.count == 1 ? values.first : nil
    }
}
