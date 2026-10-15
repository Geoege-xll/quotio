//
//  MonitorAccount.swift
//  Quotio
//

import Foundation

/// 原监控账号值模型；保留 Codable 字段、稳定身份、来源权限与禁用状态，不建立新的账号映射。
/// 显示名称继续使用原空白裁剪与回退规则，跨类型辅助统一归入 MonitorIdentity。
nonisolated struct MonitorAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: AIProvider
    let accountKey: String
    let displayName: String
    let source: MonitorAccountSource
    let credentialReference: String?
    let canDelete: Bool
    var isDisabled: Bool

    var deduplicationKey: String {
        let identity = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(provider.rawValue):\(identity)"
    }

    static func make(
        provider: AIProvider,
        accountKey: String,
        displayName: String? = nil,
        source: MonitorAccountSource,
        credentialReference: String? = nil,
        canDelete: Bool = false,
        isDisabled: Bool = false
    ) -> MonitorAccount {
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let idSeed = "\(provider.rawValue)|\(normalized.lowercased())"
        return MonitorAccount(
            id: "monitor-" + MonitorIdentity.fingerprint(idSeed),
            provider: provider,
            accountKey: normalized,
            displayName: MonitorIdentity.nilIfBlank(displayName) ?? normalized,
            source: source,
            credentialReference: credentialReference,
            canDelete: canDelete,
            isDisabled: isDisabled
        )
    }

    static func makeLegacy(_ file: DirectAuthFile) -> MonitorAccount {
        let accountKey: String
        if file.provider == .codex || file.provider == .copilot {
            accountKey = file.menuBarAccountKey
        } else if let email = file.email, !email.isEmpty {
            accountKey = email
        } else {
            accountKey = file.filename.replacingOccurrences(of: ".json", with: "")
        }
        let displayName = MonitorIdentity.nilIfBlank(file.email) ?? MonitorIdentity.nilIfBlank(file.login) ?? file.filename
        return make(
            provider: file.provider,
            accountKey: accountKey,
            displayName: displayName,
            source: .legacyCLIProxy,
            credentialReference: file.filePath
        )
    }
}

