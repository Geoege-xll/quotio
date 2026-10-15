//
//  SettingsScreen.swift
//  Quotio
//

import SwiftUI
import AppKit

/// 设置根页面只负责导航装配；独立设置分区与弹窗分别在 Sections、Components、Sheets 维护。
/// NavigationPath、搜索文本和模式定位请求继续由此页面持有，不随组件归位转移。
/// 设置内部只建立一个系统导航栈；系统负责 Push、返回按钮、标题与键盘导航。
/// 应用模式只在根页面编辑，返回根页面的定位操作不写入任何业务配置。
struct SettingsScreen: View {
    var opensLogs = false
    @State private var path = NavigationPath()
    @State private var search = ""
    @State private var modeFocusRequest = UUID()

    // 跨统计业务的维护装配由 App 提供，设置页只保存目的地构造入口，不反向读取 App 协调器或统计 VM。
    // 使用延迟闭包，保留首次进入目的地时才配置服务的原时机；不能在本页 init／body 提前创建维护服务。
    // 只在这个低频导航边界擦除视图类型，使 SettingsScreen 保留原非泛型名称，导航状态仍由本页持有。
    private let storageDataDestination: () -> AnyView

    init<StorageDestination: View>(opensLogs: Bool = false,
                                  @ViewBuilder storageDataDestination: @escaping () -> StorageDestination) {
        self.opensLogs = opensLogs
        self.storageDataDestination = { AnyView(storageDataDestination()) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsOverviewScreen(search: $search, modeFocusRequest: modeFocusRequest)
                .navigationDestination(for: SettingsDestination.self) { destination in
                    SettingsCategoryScreen(destination: destination, onShowMode: showMode)
                }
                .navigationDestination(for: SettingsAuxiliaryPage.self) { page in
                    switch page {
                    case .aliases: SettingsModelAliasesScreen()
                    case .agents: AgentSetupScreen()
                    case .logs: LogsScreen()
                    case .about: AboutScreen()
                    case .upstreamUpdates: UpstreamUpdatesScreen()
                    case .storageData: storageDataDestination()
                    }
                }
        }
        .modifier(SettingsPageBackground())
        .onAppear {
            // 异常快捷入口复用设置导航栈，不创建没有返回按钮的独立日志页。
            if opensLogs && path.isEmpty {
                path.append(SettingsDestination(category: .maintenance))
                path.append(SettingsAuxiliaryPage.logs)
            }
        }
    }

    private func showMode() {
        search = ""
        path = NavigationPath()
        modeFocusRequest = UUID()
    }
}

