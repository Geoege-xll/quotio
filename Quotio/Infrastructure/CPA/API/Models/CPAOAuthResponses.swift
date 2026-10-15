import Foundation

// CPA v8 授权响应的纯值契约；保留设备流字段、可选有效期和既有浏览器授权兼容。
// 这里只调整声明归属，不改变授权会话、轮询时限或界面状态的所有者。

// MARK: - OAuth Flow

nonisolated struct OAuthURLResponse: Codable, Sendable {
    let status: String
    let url: String?
    let state: String?
    let userCode: String?
    // v8 的设备流返回有效期（秒）；字段可选，兼容既有浏览器授权响应。
    let flow: String?
    let expiresIn: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, url, state, error, flow
        case userCode = "user_code"
        case expiresIn = "expires_in"
    }

    init(status: String, url: String? = nil, state: String? = nil, userCode: String? = nil, error: String? = nil, flow: String? = nil, expiresIn: Double? = nil) {
        self.status = status
        self.url = url
        self.state = state
        self.userCode = userCode
        self.flow = flow
        self.expiresIn = expiresIn
        self.error = error
    }
}

nonisolated struct OAuthStatusResponse: Codable, Sendable {
    let status: String
    let error: String?
}
