//
//  OAuthState.swift
//  Quotio
//

import Foundation

/// 账号授权弹窗与 CPA 会话协调器共用的原有状态模型。
/// 完整保留会话身份、设备流标记、回调反馈和构造默认值，既有调用方继续使用 OAuthState。
/// 本模型仅表达当前授权状态；会话任务仍由原协调器持有，页面状态仍存储在 QuotaViewModel。
struct OAuthState {
    let provider: AIProvider
    /// 每次授权独立的 UI 身份；同提供商重试也必须清空上一次回调反馈。
    let sessionID: UUID
    var isDeviceFlow: Bool
    var callbackStatus: CallbackStatus = .idle

    enum CallbackStatus { case idle, submitting, submitted, failed }

    /// 设备授权由用户在上游页面确认，CPA 不接受此流程的手动 localhost 回调。
    var supportsManualCallback: Bool {
        status == .polling && !isDeviceFlow && provider != .grok && provider != .copilot && provider != .kiro
    }
    var status: OAuthStatus
    var state: String?
    var userCode: String?
    var error: String?
    var authURL: String?

    enum OAuthStatus {
        case waiting, polling, success, error
    }

    init(provider: AIProvider, status: OAuthStatus, state: String? = nil, userCode: String? = nil, error: String? = nil, authURL: String? = nil, sessionID: UUID = UUID(), isDeviceFlow: Bool = false) {
        self.sessionID = sessionID
        self.isDeviceFlow = isDeviceFlow
        self.provider = provider
        self.status = status
        self.state = state
        self.userCode = userCode
        self.error = error
        self.authURL = authURL
    }
}
