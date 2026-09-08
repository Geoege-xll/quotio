// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 参考 ProxyStatsView 的摘要与分布布局（bdb83bbe）；修改为客户端 Token 口径并补足完整分布与无障碍读取。
import SwiftUI

/// 饼图与明细表复用完整排名。仅饼图把第六名之后合并为「其他」，
/// 合并值仍参加扇区和图例，避免参考代码直接 prefix(6) 导致图形漏计。
struct UsageStatisticsInsights: View {
    let presentation: UsageStatisticsPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 直接接收页面内容宽度，避免先按最小内容宽度布局、再反向测量造成卡片留白。
    let contentWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedModels: Set<String> = []

    var body: some View {
        let models = presentation.models
        let total = presentation.totals.totalTokens
        let sparklines = sparklineMap(models: models)
        Group {
            if contentWidth >= 980 {
                HStack(alignment: .top, spacing: 16) {
                    distribution(models: models, total: total)
                        .frame(width: min(max(contentWidth * 0.34, 320), 380))
                    modelTable(models: models, total: total, sparklines: sparklines)
                        .frame(maxWidth: .infinity).layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    distribution(models: models, total: total)
                    modelTable(models: models, total: total, sparklines: sparklines)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func distribution(models: [UsageStatisticsModel], total: Int) -> some View {
        let slices = makeSlices(models: models)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("usage.replica.modelDistribution".localized()).font(.headline.weight(.bold))
                Spacer()
                Text("usage.tokens".localized()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            if total > 0 {
                // 环形图只有最多六个扇区，使用固定几何绘制并独立放置比例标签，
                // 避免 SectorMark.annotation 的锚点测量反复触发布局事务。
                UsageDistributionDonut(slices: slices, total: total)
                .frame(height: 225)
                .overlay {
                    VStack(spacing: 2) {
                        Text(total.formattedCompact).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("Tokens").font(.caption2).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            } else {
                Text("usage.replica.noTokens".localized())
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 225)
            }
            VStack(spacing: 7) {
                ForEach(slices) { slice in
                    HStack(spacing: 6) {
                        Circle().fill(slice.color).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(slice.name).font(.caption).lineLimit(1).truncationMode(.middle).help(slice.name)
                        Spacer(minLength: 4)
                        Text(slice.tokens.formattedCompact).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.primary)
                        Text(share(slice.tokens, total: total)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    // 圆环本身不重复播报；图例显式提供完整数值，避免缩写丢失「其他」分组的精确用量。
                    .accessibilityLabel(slice.name)
                    .accessibilityValue(slice.tokens.formatted() + " Tokens · " + share(slice.tokens, total: total))
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .top)
        .modifier(UsageAnalyticsSurface())
    }

    /// 明细不再嵌套固定高度的滚动视图，所有模型与展开内容统一随页面滚动。
    /// 名称、Token 和占比采用固定列宽，趋势图独占剩余宽度；窄屏保留两行回退，
    /// 但不再用 Spacer 或固定图宽把可用于趋势的空间变成留白。
    private func modelTable(models: [UsageStatisticsModel], total: Int, sparklines: [String: [UsageStatisticsDay]]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("usage.modelDetails".localized()).font(.headline.weight(.semibold))
            if tableWidth >= 560 {
                HStack(spacing: 12) {
                    Text("usage.model".localized()).frame(width: modelColumnWidth, alignment: .leading)
                    Text("Tokens").frame(width: tokenColumnWidth, alignment: .trailing)
                    Text("usage.replica.share".localized()).frame(width: shareColumnWidth, alignment: .trailing)
                    Text("usage.replica.trend".localized()).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(models) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        modelRow(model, total: total, points: sparklines[model.id] ?? [])
                        if expandedModels.contains(model.id) {
                            modelDetails(model)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(UsageAnalyticsSurface())
    }

    private var tableWidth: CGFloat {
        if contentWidth >= 980 {
            return max(0, contentWidth - min(max(contentWidth * 0.34, 320), 380) - 16 - 32)
        }
        return max(0, contentWidth - 32)
    }

    // 表头和数据行共享列宽，窗口变宽时只把新增空间交给折线图，避免数值列漂移。
    private let modelColumnWidth: CGFloat = 200
    private let tokenColumnWidth: CGFloat = 88
    private let shareColumnWidth: CGFloat = 64

    private func modelRow(_ model: UsageStatisticsModel, total: Int, points: [UsageStatisticsDay]) -> some View {
        let expanded = expandedModels.contains(model.id)
        let color = modelColor(model.id)
        return Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.72)) {
                if expanded { expandedModels.remove(model.id) } else { expandedModels.insert(model.id) }
            }
        } label: {
            Group {
                if tableWidth >= 560 {
                    HStack(spacing: 12) {
                        modelIdentity(model, expanded: expanded, color: color)
                            .frame(width: modelColumnWidth, alignment: .leading)
                        modelMetrics(model, total: total, points: points, color: color, compact: false)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        modelIdentity(model, expanded: expanded, color: color)
                            .frame(width: modelColumnWidth, alignment: .leading)
                        HStack(spacing: 12) {
                            modelMetrics(model, total: total, points: points, color: color, compact: true)
                        }
                    }
                }
            }
            .monospacedDigit()
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(UsageModelRowButtonStyle(expanded: expanded))
        .accessibilityLabel(modelName(model) + " · " + providerName(model))
        .accessibilityValue(model.totals.totalTokens.formatted() + " Tokens · " + share(model.totals.totalTokens, total: total))
        .accessibilityHint((expanded ? "usage.replica.collapseDetails" : "usage.replica.expandDetails").localized())
    }

    private func modelIdentity(_ model: UsageStatisticsModel, expanded: Bool, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(modelName(model)).font(.callout.weight(.semibold))
                    .lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
                Text(providerName(model)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(modelName(model) + " · " + providerName(model))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func modelMetrics(_ model: UsageStatisticsModel, total: Int, points: [UsageStatisticsDay], color: Color, compact: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            // 紧凑布局没有表头，单位放在数值上方，避免拼接单位后撑大固定列。
            if compact { Text("Tokens").font(.caption2).foregroundStyle(.secondary) }
            Text(model.totals.totalTokens.formattedCompact)
                .font(.callout.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1)
                .help(model.totals.totalTokens.formatted() + " Tokens")
        }
        .frame(width: tokenColumnWidth, alignment: .trailing)
        VStack(alignment: .trailing, spacing: 2) {
            if compact { Text("usage.replica.share".localized()).font(.caption2).foregroundStyle(.secondary) }
            Text(share(model.totals.totalTokens, total: total))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: shareColumnWidth, alignment: .trailing)
        sparkline(points, color: color)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
    }

    private func modelDetails(_ model: UsageStatisticsModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(modelName(model)).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                pill("usage.inputTokens", value: model.totals.inputTokens)
                pill("usage.outputTokens", value: model.totals.outputTokens)
                pill("usage.cachedTokens", value: model.totals.cachedTokens)
                pill("usage.reasoningTokens", value: model.totals.reasoningTokens)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotioInsetCard()
    }

    /// 指标使用同一套 Token 语义色；数值本身保持主文字色，避免浅色模式下彩色小字难以辨认。
    private func pill(_ key: String, value: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(UsageStatisticsPalette.metric(key)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(key.localized()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(value.formatted()).font(.caption.weight(.semibold)).monospacedDigit()
                    .textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func sparkline(_ points: [UsageStatisticsDay], color: Color) -> some View {
        // 26pt 的行内趋势没有坐标轴或交互，不需要为每个模型创建完整 Charts 布局图。
        UsageStatisticsSparkline(points: points, color: color).equatable()
    }

    private func sparklineMap(models: [UsageStatisticsModel]) -> [String: [UsageStatisticsDay]] {
        // 一次按 provider/model 分组后生成趋势，避免每次绘制每一行都全表扫描。
        let grouped = Dictionary(grouping: presentation.buckets) { "\($0.provider.utf8.count):\($0.provider)\($0.model)" }
        return Dictionary(uniqueKeysWithValues: models.map { model in
            let days = Dictionary(grouping: grouped[model.id] ?? [], by: \.day)
                .map { UsageStatisticsDay(day: $0.key, totals: UsageTotals(buckets: $0.value)) }
                .sorted { $0.day < $1.day }
            return (model.id, days)
        })
    }

    private func makeSlices(models: [UsageStatisticsModel]) -> [UsageDistributionSlice] {
        UsageDistributionData.slices(models: models).map { slice in
            let name: String
            if slice.isOther {
                name = "usage.replica.other".localized()
            } else {
                let model = slice.model.isEmpty ? "usage.unknownModel".localized() : slice.model
                let provider = slice.provider.isEmpty ? "usage.unknownProvider".localized() : slice.provider
                name = model + " · " + provider
            }
            return UsageDistributionSlice(id: slice.id, name: name, tokens: slice.tokens,
                                          color: slice.isOther ? .gray : modelColor(slice.id))
        }
    }

    private func modelName(_ model: UsageStatisticsModel) -> String { model.model.isEmpty ? "usage.unknownModel".localized() : model.model }
    private func providerName(_ model: UsageStatisticsModel) -> String { model.provider.isEmpty ? "usage.unknownProvider".localized() : model.provider }
    private func share(_ tokens: Int, total: Int) -> String { total > 0 ? (Double(tokens) / Double(total)).formatted(.percent.precision(.fractionLength(1))) : "—" }
    private func modelColor(_ id: String) -> Color {
        // 稳定摘要保证筛选和排序切换不会让同一模型随名次变化而换色。
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let palette: [Color] = [QuotioTheme.Colors.info, QuotioTheme.Colors.codexGreen,
                                QuotioTheme.Colors.claudeOrange, QuotioTheme.Colors.opencodeBlue,
                                QuotioTheme.Colors.warning, QuotioTheme.Colors.success]
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private struct UsageDistributionSlice: Identifiable {
    let id: String
    let name: String
    let tokens: Int
    let color: Color
}

/// 扇区与比例标签都只依赖既定画布，不通过 Charts annotation 反向测量锚点。
/// 扇区总量和「其他」分组沿用原投影；图例保留完整可访问名称和数值。
private struct UsageDistributionDonut: View {
    let slices: [UsageDistributionSlice]
    let total: Int
    @Environment(\.colorScheme) private var colorScheme

    private struct Segment: Identifiable {
        let slice: UsageDistributionSlice
        let start: Double
        let end: Double
        var id: String { slice.id }
    }

    private var segments: [Segment] {
        guard total > 0 else { return [] }
        var start = 0.0
        return slices.map { slice in
            let end = min(1, start + Double(slice.tokens) / Double(total))
            defer { start = end }
            return Segment(slice: slice, start: start, end: end)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            let thickness = radius * 0.45
            let middleRadius = radius - thickness / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                ForEach(segments) { segment in
                    UsageDistributionArc(start: segment.start, end: segment.end, hasGap: slices.count > 1)
                        .stroke(segment.slice.color, style: StrokeStyle(lineWidth: thickness, lineCap: .butt))
                    // 比例阈值直接使用原始数量，避免累计角度相减让恰好 10% 的扇区跌到阈值以下。
                    if Double(segment.slice.tokens) / Double(total) >= 0.1 {
                        let angle = ((segment.start + segment.end) / 2 * 360 - 90) * .pi / 180
                        Text((Double(segment.slice.tokens) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.primary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(QuotioTheme.Colors.cardBackground(for: colorScheme), in: Capsule())
                            .position(x: center.x + middleRadius * cos(angle), y: center.y + middleRadius * sin(angle))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
}

private struct UsageDistributionArc: Shape {
    let start: Double
    let end: Double
    let hasGap: Bool

    func path(in rect: CGRect) -> Path {
        let outerRadius = min(rect.width, rect.height) / 2
        // 极小扇区按自身宽度缩小间隔，不能因统一间隔产生反向或接近整圈的假扇区。
        let gap = hasGap ? min(0.75, (end - start) * 360 / 4) : 0
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: outerRadius * 0.775,
                    startAngle: .degrees(start * 360 - 90 + gap),
                    endAngle: .degrees(end * 360 - 90 - gap), clockwise: false)
        return path
    }
}

/// 小趋势图用单次 Canvas 绘制有界折线，模型行悬停与展开不再驱动多套 Charts 锚点布局。
struct UsageStatisticsSparkline: View, Equatable {
    let points: [UsageStatisticsDay]
    let color: Color

    var body: some View {
        let sampled = UsageTrendPlotData.sampled(points, maximumPoints: 64)
        Canvas { context, size in
            guard let first = sampled.first, let last = sampled.last else { return }
            let plot = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            guard plot.width > 0, plot.height > 0 else { return }
            let span = last.day.timeIntervalSince(first.day)
            let maximum = Double(max(1, sampled.map { $0.totals.totalTokens }.max() ?? 0))
            func position(_ day: UsageStatisticsDay) -> CGPoint {
                let fraction = span > 0 ? day.day.timeIntervalSince(first.day) / span : 0.5
                return CGPoint(x: plot.minX + plot.width * fraction,
                               y: plot.maxY - plot.height * Double(day.totals.totalTokens) / maximum)
            }
            if sampled.count == 1 {
                let point = position(first)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.75, y: point.y - 1.75, width: 3.5, height: 3.5)), with: .color(color))
            } else {
                var path = Path()
                path.move(to: position(first))
                for day in sampled.dropFirst() { path.addLine(to: position(day)) }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 模型行属于可交互的胶囊控件；展开明细另用内嵌槽，不再靠分割线表达层次。
private struct UsageModelRowButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered || expanded
                        ? QuotioTheme.Colors.cardElevated(for: colorScheme)
                        : QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            .overlay {
                Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.72), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// 分布图的纯数据投影与 SwiftUI 色彩、翻译解耦，能够直接验证扇区的数值守恒。
/// 明细仍展示原始全部模型；饼图仅包含正数 Token，零值绝不通过占位权重制造假扇区。
nonisolated struct UsageDistributionData: Identifiable, Equatable {
    let id: String
    let model: String
    let provider: String
    let tokens: Int
    let isOther: Bool

    static func slices(models: [UsageStatisticsModel]) -> [Self] {
        let positive = models.filter { $0.totals.totalTokens > 0 }
        var result = positive.prefix(5).map {
            Self(id: $0.id, model: $0.model, provider: $0.provider, tokens: $0.totals.totalTokens, isOther: false)
        }
        let remaining = positive.dropFirst(5)
        if !remaining.isEmpty {
            result.append(Self(id: "usage-other", model: "", provider: "",
                               tokens: remaining.reduce(0) { $0 + $1.totals.totalTokens }, isOther: true))
        }
        return result
    }
}
