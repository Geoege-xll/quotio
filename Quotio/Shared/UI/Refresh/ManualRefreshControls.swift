import SwiftUI
import Observation

/// 手动操作状态与后台服务忙碌状态分开。只有 perform 由用户操作调用时才显示
/// 进度圈；自动采集、账号后台轮询和 SQL 报表更新不能修改此状态。
@MainActor @Observable
final class ManualRefreshState {
    private(set) var isRefreshing = false

    func perform(_ action: @MainActor () async -> Void) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await action()
    }
}

/// 固定图标占位，避免手动刷新时图标与进度圈尺寸不同，引起工具栏跳动。
struct ManualRefreshButton: View {
    let helpKey: String
    let action: @MainActor () async -> Void
    @State private var refresh = ManualRefreshState()

    var body: some View {
        Button { Task { await refresh.perform(action) } } label: {
            Group {
                if refresh.isRefreshing { SmallProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }.frame(width: 18, height: 18)
        }
        .disabled(refresh.isRefreshing)
        .help(helpKey.localized())
        .accessibilityLabel(helpKey.localized())
        .accessibilityIdentifier("manualRefreshButton")
    }
}

/// 账号页只有这一处刷新入口：直接点击执行全量刷新，下拉保留按服务商刷新。
/// Menu 的 primaryAction 使用原生分离点击行为，无需新增第二个导航图标或内部 Tab。
struct AccountRefreshMenu: View {
    let providers: [AIProvider]
    let unavailableProviders: Set<AIProvider>
    let refreshAll: @MainActor () async -> Void
    let refreshProvider: @MainActor (AIProvider) async -> Void
    /// 全量刷新由 ViewModel 持有，菜单和账号页都能看到同一轮用户操作。
    /// 服务商局部操作仍由本控件持有，不让后台自动刷新驱动导航进度圈。
    var sharedRefresh: ManualRefreshState? = nil
    var isRefreshingOverride: Bool = false
    @State private var refresh = ManualRefreshState()

    private var isRefreshing: Bool {
        refresh.isRefreshing || sharedRefresh?.isRefreshing == true || isRefreshingOverride
    }

    @ViewBuilder
    var body: some View {
        if isRefreshing {
            Button {} label: {
                SmallProgressView()
                    .frame(width: 18, height: 18)
            }
            .disabled(true)
            .help("action.refresh".localized())
            .accessibilityLabel("action.refresh".localized())
            .accessibilityIdentifier("accounts.refresh")
        } else {
            Menu {
                Button("accounts.refresh.all".localized()) { Task { await refresh.perform(refreshAll) } }
                if !providers.isEmpty {
                    Divider()
                    ForEach(providers) { provider in
                        Button {
                            Task { await refresh.perform { await refreshProvider(provider) } }
                        } label: {
                            Label(provider.displayName, systemImage: "arrow.clockwise")
                        }
                        .disabled(unavailableProviders.contains(provider))
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 18, height: 18)
            } primaryAction: {
                Task { await refresh.perform(refreshAll) }
            }
            .help("action.refresh".localized())
            .accessibilityLabel("action.refresh".localized())
            .accessibilityIdentifier("accounts.refresh")
        }
    }
}
