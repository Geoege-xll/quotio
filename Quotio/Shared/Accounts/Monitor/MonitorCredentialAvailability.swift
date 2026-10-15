//
//  MonitorCredentialAvailability.swift
//  Quotio
//

import Foundation

/// 原凭据可用性值；unknown、present、missing 语义不变，不把取数失败改判为凭据删除。
nonisolated enum MonitorCredentialAvailability: Equatable, Sendable {
    case unknown
    case present
    case missing
}

