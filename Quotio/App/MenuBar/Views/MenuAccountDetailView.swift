import AppKit
import SwiftUI

/// 菜单栏各提供商共用的账号额度明细，只消费当前精确账号的已发布快照。
/// 不触发额度请求；历史速率只读本地真实观测，周期估算使用独立规则，不替换原额度语义。
/// 由一个原生子菜单项承载，额度桶增减时只更新原 SwiftUI 内容和高度，不替换正在跟踪的菜单项。
struct MenuAccountDetailView: View {
    let email: String
    let data: ProviderQuotaData?
    let provider: AIProvider
    var settings: MenuBarSettingsManager = .shared
    var account: QuotaHistoryAccount? = nil
    var history: QuotaHistoryService? = nil
    @State private var trends: [String: Double] = [:]
    private struct HistoryQuery: Equatable {
        let account: QuotaHistoryAccount?
        let revision: UInt64
        let date: Date?
    }

    private var displayEmail: String { email.masked(if: settings.hideSensitiveInfo) }

    /// 保留原 Antigravity 子菜单的模型排序；汇总桶及其他提供商继续使用原快照顺序。
    private var models: [ModelQuota] {
        guard let data else { return [] }
        if provider == .antigravity, !data.models.contains(where: { $0.name.hasPrefix("antigravity-") }) {
            return data.models.sorted { $0.name < $1.name }
        }
        return data.models
    }

    /// 没有可信周期／历史时保持首轮的紧凑行高，不能为尚不存在的消耗提示预留一整行空白。
    private func showsHistoryHint(_ model: ModelQuota, now: Date) -> Bool {
        guard let data, let point = QuotaHistoryPoint.make(model: model, quota: data) else { return false }
        return QuotaPace(point: point, now: now) != nil || trends[model.id] != nil
    }

    private func modelListHeight(now: Date) -> CGFloat {
        min(models.reduce(CGFloat.zero) { total, model in
            total + 34 + (showsHistoryHint(model, now: now) ? 30 : 0)
        }, 340)
    }

    var body: some View {
        TimelineView(QuotaPaceTimelineSchedule(points: models.compactMap { model in
            data.flatMap { QuotaHistoryPoint.make(model: model, quota: $0) }
        })) { timeline in
            content(now: timeline.date)
        }
        .task(id: HistoryQuery(account: account, revision: history?.revision ?? 0, date: data?.lastUpdated)) {
            await loadTrends()
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIconMono(provider: provider, size: 14)
                    .foregroundStyle(.secondary)
                Text(displayEmail)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayEmail)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)

            if let data {
                if data.isForbidden {
                    Label("status.error".localized(), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                }
                if data.models.isEmpty {
                    Text("dashboard.noQuotaData".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                } else {
                    // 单个自定义 NSMenuItem 超过屏幕高度时，原生菜单无法逐行滚动其中内容。
                    // 因此在原承载项内限制列表高度，保留全部额度桶，通过独立滚动访问尾部模型。
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(models) { model in
                                MenuModelDetailView(model: model,
                                    showRawName: provider == .antigravity && !model.name.hasPrefix("antigravity-"),
                                    settings: settings)
                                if showsHistoryHint(model, now: now), let point = QuotaHistoryPoint.make(model: model, quota: data) {
                                    QuotaPaceSummaryView(point: point, ratePerDay: trends[model.id],
                                        displayMode: settings.quotaDisplayMode, now: now)
                                        .padding(.horizontal, 12).padding(.bottom, 6)
                                }
                            }
                        }
                    }
                    .frame(height: modelListHeight(now: now))
                    .scrollContentBackground(.hidden)
                }
                HStack(spacing: 4) {
                    Text("menubar.lastUpdated".localized())
                    Text(data.lastUpdated.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            } else {
                // 删除／来源切换后的旧菜单项不复用打开时缓存；下次打开再移除此结构。
                Text("dashboard.noQuotaData".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("menubar.account.details")
    }

    /// 保留原查询 task、输入和取消边界；Timeline 只重绘内容，不重复读取历史库。
    private func loadTrends() async {
            trends = [:]
            guard let account, let data, let history else { return }
            do {
                let rates = try await history.dailyRates(account: account)
                guard !Task.isCancelled else { return }
                for model in models.prefix(128) {
                    guard let current = QuotaHistoryPoint.make(model: model, quota: data), current.resetAt == nil else { continue }
                    // 套餐／单位变化后不能沿用旧周期的平均值。
                    if rates[model.id]?.basis == current.basis {
                        trends[model.id] = rates[model.id]?.value
                    }
                }
            } catch is CancellationError { return }
            catch { /* 本地历史读取失败不影响当前额度及原菜单交互。 */ }
    }
}
