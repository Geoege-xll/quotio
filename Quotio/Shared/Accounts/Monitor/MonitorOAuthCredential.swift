//
//  MonitorOAuthCredential.swift
//  Quotio
//

import Foundation

/// 原监控 OAuth 凭据值；保留字段、可选值、编码与 Equatable 语义，继续用于原凭据 CAS 比较。
nonisolated struct MonitorOAuthCredential: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var expiresAt: Date?
    var extra: [String: String]
}

