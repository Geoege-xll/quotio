//
//  ProxyError.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation

/// 代理安装和运行期间的通用错误，供界面与管理流程统一呈现。
enum ProxyError: LocalizedError {
    case binaryNotFound
    case startupFailed
    case operationInProgress
    case networkError(String)
    case noCompatibleBinary
    case extractionFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "CLIProxyAPI upstream binary is not installed. Open Settings and install a release."
        case .startupFailed:
            return "Failed to start proxy server."
        case .operationInProgress:
            return "Another operation is already in progress. Please wait."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .noCompatibleBinary:
            return "No compatible binary found for your system."
        case .extractionFailed:
            return "Failed to extract binary from archive."
        case .downloadFailed:
            return "Failed to download binary."
        }
    }
}
