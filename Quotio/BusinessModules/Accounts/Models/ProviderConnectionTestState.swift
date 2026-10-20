import Foundation

/// 两个账号连接弹窗共用的测试提交规则。此值仍由原 Sheet 的 @State 持有，
/// 不创建 Task、单例或网络服务；密钥快照只在本轮请求期间存于内存，不写入日志或偏好。
struct ProviderConnectionTestState {
    struct Request: Equatable {
        let id = UUID()
        let baseURL: String
        let apiKey: String

        init(baseURL: String, apiKey: String) {
            self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func matches(baseURL: String, apiKey: String) -> Bool {
            self.baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                && self.apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    struct Result {
        let success: Bool
        let latencyMs: Int?
        let message: String
    }

    private var pending: Request?
    private(set) var result: Result?
    var isTesting: Bool { pending != nil }

    mutating func begin(baseURL: String, apiKey: String) -> Request {
        let request = Request(baseURL: baseURL, apiKey: apiKey)
        pending = request
        result = nil
        return request
    }

    /// 编辑和关闭立即失效；即使输入改回原值，也不能复用上一次授权的测试结果。
    mutating func invalidate() { pending = nil; result = nil }

    mutating func complete(_ request: Request, baseURL: String, apiKey: String, result: Result) {
        // 不依赖 onChange 的调度时机：结果提交还要核对当前实际输入。
        // 旧请求不能清除新请求的 pending，也不能把失败或成功回写到新表单。
        guard pending == request else { return }
        pending = nil
        guard request.matches(baseURL: baseURL, apiKey: apiKey), !Task.isCancelled else { return }
        self.result = result
    }
}
