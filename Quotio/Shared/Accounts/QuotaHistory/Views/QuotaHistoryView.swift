import Charts
import SwiftUI

/// 账号额度历史的共享原生窗口内容。时间范围和显示口径使用项目统一分段控件，不增加页面 Tab。
/// 所有曲线来自本地真实采样；缺失时段、充值和重置边界断开连线，预测只显示为明确标注的文本。
struct QuotaHistoryView: View {
    let account: QuotaHistoryAccount
    let accountName: String
    let onClose: () -> Void
    var settings: MenuBarSettingsManager = .shared
    let service: QuotaHistoryService
    @Environment(\.locale) private var locale
    @State private var model: QuotaHistoryScreenModel
    @State private var range: QuotaHistoryRange = .week
    @State private var metricID: String?
    @State private var hoveredDate: Date?
    @State private var confirmsClear = false
    @State private var clearError = false

    init(account: QuotaHistoryAccount, accountName: String, settings: MenuBarSettingsManager = .shared,
         service: QuotaHistoryService, onClose: @escaping () -> Void) {
        self.account = account; self.accountName = accountName; self.settings = settings
        self.service = service; self.onClose = onClose
        _model = State(initialValue: QuotaHistoryScreenModel(service: service))
    }

    private struct Query: Equatable {
        let account: QuotaHistoryAccount
        let metric: String?
        let range: QuotaHistoryRange
        let revision: UInt64
    }
    private struct PlotPoint: Identifiable {
        let point: QuotaHistoryPoint
        let value: Double
        let segment: Int
        var id: String { point.id }
    }

    private var plot: [PlotPoint] {
        model.points.map { item in
            PlotPoint(point: item.point, value: displayValue(item.point), segment: item.segment)
        }
    }

    private var selectedPoint: QuotaHistoryPoint? {
        guard let date = hoveredDate else { return model.points.last?.point }
        return model.points.min { abs($0.point.date.timeIntervalSince(date)) < abs($1.point.date.timeIntervalSince(date)) }?.point
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("quota.history.title".localized()).font(.title3.weight(.semibold))
                    Text(account.provider.displayName + " · " + accountName.masked(if: settings.hideSensitiveInfo))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("action.close".localized())
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    if !service.recordingEnabled {
                        Label("quota.history.paused".localized(), systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    if service.recordingError {
                        Label("quota.history.writeFailed".localized(), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let key = model.errorKey {
                        Label(key.localized(), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if model.isLoading {
                        HStack { Spacer(); SmallProgressView(); Spacer() }.frame(height: 220)
                    } else if model.points.isEmpty {
                        ContentUnavailableView("quota.history.empty".localized(), systemImage: "chart.xyaxis.line",
                            description: Text("quota.history.emptyHelp".localized()))
                    } else {
                        summary
                        historyChart
                        dailyRows
                    }
                    Text("quota.history.coverage".localized()).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Toggle("quota.history.recording".localized(), isOn: Binding(
                            get: { service.recordingEnabled }, set: { enabled in Task { await service.setRecordingEnabled(enabled) } }))
                            .disabled(service.isSuspended || service.isClearing)
                        Spacer()
                        Button("quota.history.clear".localized(), role: .destructive) { confirmsClear = true }
                            .disabled(service.isClearing || service.isSuspended)
                    }
                    if clearError { Text("quota.history.clearFailed".localized()).font(.caption).foregroundStyle(.orange) }
                }.padding(18)
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: Query(account: account, metric: metricID, range: range, revision: service.revision)) {
            hoveredDate = nil
            await model.load(account: account, metricID: metricID, range: range)
        }
        .confirmationDialog("quota.history.clear".localized(), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("quota.history.clear".localized(), role: .destructive) {
                Task {
                    do { try await service.clear(account: account); clearError = false }
                    catch is CancellationError { }
                    catch { clearError = true }
                }
            }
            Button("action.cancel".localized(), role: .cancel) { }
        } message: { Text("quota.history.clearHelp".localized()) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                QuotioCapsuleSegmentedControl(options: QuotaHistoryRange.allCases, selection: $range, size: .small) { option, selected in
                    QuotioSegmentItemView(title: option.titleKey.localized(), isSelected: selected, size: .small)
                }
                Spacer()
                QuotioCapsuleSegmentedControl(options: QuotaDisplayMode.allCases, selection: Binding(
                    get: { settings.quotaDisplayMode }, set: { settings.quotaDisplayMode = $0 }), size: .small) { option, selected in
                    QuotioSegmentItemView(title: option.localizationKey.localized(), isSelected: selected, size: .small)
                }
            }
            if !model.metrics.isEmpty {
                Picker("quota.history.metric".localized(), selection: Binding(
                    get: { model.metrics.contains(where: { $0.metricID == metricID }) ? metricID ?? "" : model.selectedMetricID ?? "" },
                    set: { metricID = $0 })) {
                    ForEach(model.metrics, id: \.metricID) { Text($0.metricName).tag($0.metricID) }
                }.pickerStyle(.menu)
            }
        }
    }

    private var summary: some View {
        TimelineView(QuotaPaceTimelineSchedule(points: model.latest.map { [$0] } ?? [])) { timeline in
        VStack(alignment: .leading, spacing: 5) {
            if let point = selectedPoint {
                HStack {
                    Text(formatted(point)).font(.title2.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(dateLabel(point.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let latest = model.latest {
                QuotaPaceSummaryView(point: latest, ratePerDay: model.dailyRate,
                    displayMode: settings.quotaDisplayMode, now: timeline.date)
            }
        }
        }
    }

    private var historyChart: some View {
        Chart {
            ForEach(plot) { item in
                LineMark(x: .value("Date", item.point.date), y: .value("Value", item.value), series: .value("Segment", item.segment))
                    .foregroundStyle(Color.accentColor).interpolationMethod(.linear)
                PointMark(x: .value("Date", item.point.date), y: .value("Value", item.value))
                    .foregroundStyle(Color.accentColor).symbolSize(10)
            }
            if let selectedPoint {
                RuleMark(x: .value("Date", selectedPoint.date)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: chartDomain)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            hoveredDate = proxy.value(atX: location.x - geometry[frame].origin.x, as: Date.self)
                        case .ended: hoveredDate = nil
                        }
                    }
            }
        }
        .frame(height: 240)
        .accessibilityLabel("quota.history.title".localized())
    }

    private var chartDomain: ClosedRange<Double> {
        if model.latest?.kind == .percentage { return 0...100 }
        let values = model.points.map(\.point.value), lower = values.min() ?? 0, upper = values.max() ?? 1
        let margin = max(1, (upper - lower) * 0.1)
        return max(0, lower - margin)...max(upper + margin, 1)
    }

    private var dailyRows: some View {
        VStack(spacing: 6) {
            // 逐条明细有界展示最近二十个真实观测，日期可与悬停读数直接核对。
            ForEach(Array(model.points.suffix(20).reversed())) { item in
                HStack {
                    Text(dateLabel(item.point.date)).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatted(item.point)).monospacedDigit()
                }.font(.caption)
            }
        }
    }

    private func displayValue(_ point: QuotaHistoryPoint) -> Double {
        point.kind == .percentage ? settings.quotaDisplayMode.displayValue(from: point.value) : point.value
    }
    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale))
    }
    private func formatted(_ point: QuotaHistoryPoint) -> String {
        if point.kind == .percentage { return String(format: "%.1f%%", displayValue(point)) }
        return point.unit?.format(point.value) ?? String(format: "%.1f", point.value)
    }
}
