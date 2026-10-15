import SwiftUI

/// 账号模块内额度布局的显示适配器，集中保留原有颜色阈值、文本和环形未知值的换算规则。
/// 只根据传入的显示模式计算结果，不持有偏好、账号数据或任务；通用百分比纯规则仍由
/// QuotaPercentagePresentation 提供。改为模块内可见仅用于拆分后的同模块视图复用，
/// 不复制算法、不调整阈值，也不迁移到跨业务的 Shared 工具目录。
struct QuotaDisplayHelper {
    let displayMode: QuotaDisplayMode

    func statusColor(remainingPercent: Double) -> Color {
        guard QuotaPercentagePresentation.isKnown(remainingPercent) else { return .secondary }
        let clamped = max(0, min(100, remainingPercent))
        let usedPercent = 100 - clamped
        let checkValue = displayMode == .used ? usedPercent : clamped

        if displayMode == .used {
            if checkValue < 70 { return .green }
            if checkValue < 90 { return .yellow }
            return .red
        }

        if checkValue > 50 { return .green }
        if checkValue > 20 { return .orange }
        return .red
    }

    func displayPercent(remainingPercent: Double) -> Double {
        QuotaPercentagePresentation.displayValue(remainingPercent, showUsed: displayMode == .used) ?? 0
    }

    func percentText(remainingPercent: Double) -> String {
        QuotaPercentagePresentation.text(remainingPercent, showUsed: displayMode == .used)
    }

    /// Percentage for ring rendering. Unlike `displayPercent(remainingPercent:)`
    /// this keeps the "no data" sentinel instead of clamping it into a real
    /// value, so `RingProgressView` can render its unknown state.
    func ringPercent(remainingPercent: Double) -> Double {
        !QuotaPercentagePresentation.isKnown(remainingPercent)
            ? RingProgressView.unknownPercent
            : displayPercent(remainingPercent: remainingPercent)
    }
}
