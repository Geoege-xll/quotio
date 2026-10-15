import Foundation
import Observation

/// 历史窗口只持有自己的查询状态；选项改变或窗口关闭时，旧查询不能覆盖新指标。
/// 采样、清理和数据库连接仍归共享历史服务，不随打开窗口创建第二套采集任务。
@MainActor @Observable
final class QuotaHistoryScreenModel {
    private(set) var metrics: [QuotaHistoryPoint] = []
    private(set) var points: [QuotaHistoryChartPoint] = []
    private(set) var dailyRate: Double?
    private(set) var selectedMetricID: String?
    private(set) var isLoading = false
    private(set) var errorKey: String?
    @ObservationIgnored private let service: QuotaHistoryService
    private var requestID = UUID()

    init(service: QuotaHistoryService) { self.service = service }

    func load(account: QuotaHistoryAccount, metricID: String?, range: QuotaHistoryRange) async {
        let request = UUID()
        requestID = request
        isLoading = true
        errorKey = nil
        points = []
        dailyRate = nil
        defer { if requestID == request { isLoading = false } }
        do {
            let catalog = try await service.metrics(account: account)
            guard requestID == request, !Task.isCancelled else { return }
            let selected = catalog.first(where: { $0.metricID == metricID }) ?? catalog.first
            let samples: [QuotaHistoryChartPoint]
            var rate: Double?
            if let selected {
                samples = try await service.points(account: account, metricID: selected.metricID, range: range)
                let rates = try await service.dailyRates(account: account)
                if rates[selected.metricID]?.basis == selected.basis { rate = rates[selected.metricID]?.value }
            } else { samples = [] }
            guard requestID == request, !Task.isCancelled else { return }
            metrics = catalog
            selectedMetricID = selected?.metricID
            // 单位或数值类型变更后不可共用纵轴；额度基线不同的同单位样本则由图表分段展示。
            points = samples.filter { $0.point.kind == selected?.kind && $0.point.unit == selected?.unit }
            dailyRate = rate
        } catch is CancellationError { }
        catch {
            guard requestID == request, !Task.isCancelled else { return }
            metrics = []; selectedMetricID = nil
            if case QuotaHistoryError.busy = error { errorKey = "quota.history.maintenance" }
            else { errorKey = "quota.history.readFailed" }
        }
    }

    var latest: QuotaHistoryPoint? { metrics.first { $0.metricID == selectedMetricID } }
}
