import Foundation

/// Antigravity 周期额度的统一读取契约，供本地直连与 CPA 精确凭据转发共同使用。
/// 此类型只决定请求和解析规则，不持有账号、缓存、Task 或可变状态；认证与项目发现仍归原获取器。
nonisolated struct AntigravityQuotaReader: Sendable {
    /// 调用方绑定本轮唯一凭据与原传输层；CPA 的 $TOKEN$ 不会被带到本地直连。
    let request: @Sendable (_ url: String, _ payload: String) async throws -> Data

    func fetch(projectID: String) async throws -> [ModelQuota] {
        try Task.checkCancellation()
        guard let project = QuotaResponseValue.string(projectID) else { throw QuotaFetchError.invalidResponse }
        let payload = String(decoding: try JSONEncoder().encode(["project": project]), as: UTF8.self)
        var lastError: Error = QuotaFetchError.invalidResponse
        for host in AntigravityQuotaEndpoints.summaryHosts {
            try Task.checkCancellation()
            do {
                let data = try await request(host + "/v1internal:retrieveUserQuotaSummary", payload)
                // 网络层可能不响应取消；提交前仍须复核，不能把迟到数据当作本轮刷新成功。
                try Task.checkCancellation()
                guard let models = AntigravityQuotaParser.summaryModels(from: data) else {
                    throw QuotaFetchError.invalidResponse
                }
                // 五小时与周额度，以及各自的重置时间，来自同一次同环境的权威汇总。
                // 不再拼接 production 周额度和 daily 模型级额度，也不以模型消耗推算周额度。
                return models
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }
}

/// 端点和客户端身份属于 Antigravity 协议，不属于通用 CPA 数值转换工具。
/// 对照 CPAMC fe296333 与 Magpie cb05dc2d；Hub 请求标识会影响汇总中是否包含 Gemini。
nonisolated enum AntigravityQuotaEndpoints {
    private static let productionHost = "https://cloudcode-pa.googleapis.com"
    private static let dailyHosts = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.sandbox.googleapis.com"
    ]
    /// 项目／订阅发现仍允许原正式环境回退，不改变已有账号的发现及套餐规则。
    static let hosts = dailyHosts + [productionHost]
    /// Antigravity 实际执行环境的周期额度。正式主机虽可能 HTTP 200，返回的却可能是
    /// 另一环境的满额和“查询时刻 + 七天”重置时间，因此不能将它当作额度失败时的有效兜底。
    /// 两个执行端点都失败时将错误交给原刷新宿主，沿用各模式的失败规则，
    /// 不在读取器中伪造成功、覆盖缓存或发布虚假的 0% 已用量。
    static let summaryHosts = dailyHosts
    /// 与 CPA 官方客户端当前 Hub 协议对齐。旧 cli/1.0.13 会使 daily 汇总遗漏 Gemini；
    /// 不使用本地 IDE 版本代替 Hub 版本，两者的产品版本号并不属于同一个协议序列。
    static let userAgent = "antigravity/hub/2.23.0 darwin/arm64"
}
