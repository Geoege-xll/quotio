import SwiftUI
import Charts

/// 图例只改变本图的可见系列，不改变共享筛选、排行指标，也不重新查询数据库。
/// 悬停状态仍留在独立覆盖层，避免鼠标移动反复重建最多 240 × 4 个折线标记。
struct CPAUsageTrendChart: View {
    let points: [CPAUsageTrendPoint]
    let hourly: Bool
    let metric: CPAUsageChartMetric
    @State private var visibleTokens = Set(CPAUsageTrendSeries.tokenSeries)

    private var series: [CPAUsageTrendSeries] {
        metric == .requests ? [.requests] : CPAUsageTrendSeries.tokenSeries.filter { visibleTokens.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("usage.dashboard.trend".localized()).font(.subheadline.weight(.semibold))
                Spacer()
                Text(metric.titleKey.localized()).font(.caption).foregroundStyle(.secondary)
            }
            if metric == .tokens {
                // 复用自适应布局，窄窗口或较长翻译自动换行；图例可用键盘切换。
                CPAUsageAdaptiveGrid(maximumColumns: 4, minimumColumnWidth: 115, spacing: 8) {
                    ForEach(CPAUsageTrendSeries.tokenSeries) { item in
                        legend(item)
                    }
                }
            }
            if points.isEmpty {
                ContentUnavailableView("usage.empty.title".localized(), systemImage: "chart.xyaxis.line",
                    description: Text("usage.records.empty".localized())).frame(height: 190)
            } else {
                CPAUsageTrendPlot(points: points, series: series, hourly: hourly)
                    .frame(height: 190)
            }
            VStack(alignment: .leading, spacing: 4) {
                if metric == .tokens {
                    Text("usage.dashboard.tokenTrendNote".localized())
                }
                Text("usage.dashboard.trendNote".localized())
            }
            .font(.caption2).foregroundStyle(.secondary)
        }.quotioCard()
    }

    private func legend(_ item: CPAUsageTrendSeries) -> some View {
        let selected = visibleTokens.contains(item)
        return Button {
            // 至少保留一条曲线；保留固定系列顺序，不让颜色和绘制顺序随点击变化。
            if selected { visibleTokens.remove(item) }
            else { visibleTokens.insert(item) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? item.color : .secondary)
                    .accessibilityHidden(true)
                CPATrendLineSample(series: item).frame(width: 20, height: 8)
                    .opacity(selected ? 1 : 0.4).accessibilityHidden(true)
                Text(item.titleKey.localized()).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selected && visibleTokens.count == 1)
        .accessibilityLabel(item.titleKey.localized())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("cpaTrendSeries-" + item.rawValue)
    }
}

/// 颜色使用系统自适应色，并配合不同虚线节奏；关闭其他系列后纵轴按可见值缩放，
/// 输出较输入小几个数量级时也能单独看清走势，不引入容易误读的双纵轴。
private extension CPAUsageTrendSeries {
    var color: Color {
        switch self {
        case .total, .requests: .blue
        case .input: .orange
        case .output: .purple
        case .cached: .teal
        }
    }

    var stroke: StrokeStyle {
        let dash: [CGFloat]
        switch self {
        case .total, .requests: dash = []
        case .input: dash = [7, 3]
        case .output: dash = [2, 3]
        case .cached: dash = [7, 3, 2, 3]
        }
        return StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash)
    }
}

private struct CPATrendLineSample: View {
    let series: CPAUsageTrendSeries
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 4))
            path.addLine(to: CGPoint(x: 20, y: 4))
        }.stroke(series.color, style: series.stroke)
    }
}

/// 图形本体仅依赖有界采样点和可见系列；提示内容不参与坐标范围与布局计算。
struct CPAUsageTrendPlot: View {
    let points: [CPAUsageTrendPoint]
    let series: [CPAUsageTrendSeries]
    let hourly: Bool

    var body: some View {
        let maximum = max(1, series.flatMap { item in points.map { item.value(in: $0) } }.max() ?? 0)
        Chart {
            ForEach(series) { item in
                ForEach(points) { point in
                    // 显式指定系列身份，防止同一时间桶内的四种值被连成一条折返线。
                    LineMark(x: .value("Time", point.date), y: .value(item.titleKey.localized(), item.value(in: point)),
                             series: .value("Series", item.rawValue))
                        .foregroundStyle(item.color).lineStyle(item.stroke)
                        .symbol(.circle).symbolSize(points.count == 1 ? 20 : 0)
                        .accessibilityLabel(item.titleKey.localized() + " · "
                            + point.date.formatted(date: .abbreviated, time: hourly ? .shortened : .omitted))
                        .accessibilityValue(item.value(in: point).formatted())
                }
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...maximum)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { mark in
                AxisGridLine()
                AxisValueLabel { if let count = mark.as(Int.self) { Text(count.formattedCompact).monospacedDigit() } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartOverlay { proxy in
            CPAUsageTrendHover(points: points, series: series, hourly: hourly, proxy: proxy)
        }
        .transaction { $0.animation = nil }
    }
}

/// 一次悬停显示该时间桶的所有可见分量，使用完整数字，便于比较接近或相互重叠的曲线。
/// 只在命中不同数据点时写状态；不向 ChartContent 动态插入 RuleMark 或 annotation。
private struct CPAUsageTrendHover: View {
    let points: [CPAUsageTrendPoint]
    let series: [CPAUsageTrendSeries]
    let hourly: Bool
    let proxy: ChartProxy
    @State private var selectedDate: Date?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let anchor = proxy.plotFrame else { clearSelection(); return }
                            let plot = geometry[anchor]
                            guard plot.contains(location),
                                  let date = proxy.value(atX: location.x - plot.minX, as: Date.self) else {
                                clearSelection(); return
                            }
                            let nearest = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.date
                            if selectedDate != nearest { selectedDate = nearest }
                        case .ended: clearSelection()
                        }
                    }
                if let selectedDate, let point = points.first(where: { $0.date == selectedDate }) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(point.date.formatted(date: .abbreviated, time: hourly ? .shortened : .omitted))
                        ForEach(series) { item in
                            HStack(spacing: 8) {
                                CPATrendLineSample(series: item).frame(width: 20, height: 8)
                                Text(item.titleKey.localized())
                                Spacer(minLength: 12)
                                Text(item.value(in: point).formatted()).monospacedDigit()
                            }
                        }
                    }
                    .font(.caption).padding(8).fixedSize()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 44).padding(.top, 4)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func clearSelection() {
        if selectedDate != nil { selectedDate = nil }
    }
}
