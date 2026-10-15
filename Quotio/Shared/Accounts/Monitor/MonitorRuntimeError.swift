//
//  MonitorRuntimeError.swift
//  Quotio
//

import Foundation

/// 原监控运行错误枚举；case 与 LocalizedError 文案保持原样，存储与发现继续使用相同错误类型。
nonisolated enum MonitorRuntimeError: LocalizedError {
    case credentialWriteFailed
    case invalidCredential
    case symbolicLinkRefused

    var errorDescription: String? {
        switch self {
        case .credentialWriteFailed: "Could not save the Monitor credential in Keychain."
        case .invalidCredential: "The Monitor credential file is invalid."
        case .symbolicLinkRefused: "Refusing to write credentials through a symbolic link."
        }
    }
}

