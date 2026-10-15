import Foundation

/// CPA 账号调度的共同校验契约，由管理 API、账号权重编辑和共享提供商配置复用。
/// 规则与原错误类型成组维护，不依赖设置视图、表单草稿或 Binding，也不持有任何任务或状态。
/// 权重与账号优先级不同：仅影响加权轮询比例，非正数在该策略下排除账号。
/// 使用可选值兼容没有 weight 的旧提供商数据；nil 表示保留原配置，新凭据由 CPA 缺省为 1。
nonisolated enum CPAAccountWeight {
    static let maximum = 1_000_000

    static func parse(_ text: String) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value <= maximum else {
            throw CPASettingsValidationError.invalidWeight
        }
        return value
    }
}

/// 保留既有类型名称、全部错误 case 与本地化反馈，兼容原调用方的模式匹配和错误展示。
/// 设置草稿也复用此错误契约，但草稿、按 scope 的补丁与保存基线仍由 Settings 原类型负责。
/// localizedStatic 是基础设施现有的语言辅助；错误格式化不读取页面状态或改写配置。
nonisolated enum CPASettingsValidationError: LocalizedError {
    case invalidWeight
    case invalidNumber(String)
    case emptySessionTTL

    var errorDescription: String? {
        switch self {
        case .invalidWeight: "settings.cpa.weightInvalid".localizedStatic()
        case .invalidNumber(let field): String(format: "settings.cpa.numberInvalid".localizedStatic(), field.localizedStatic())
        case .emptySessionTTL: "settings.cpa.sessionTTLInvalid".localizedStatic()
        }
    }
}
