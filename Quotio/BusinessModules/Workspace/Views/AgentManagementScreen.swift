//
//  AgentManagementScreen.swift
//  Quotio - Unified Agent Management (Sessions, Skills, Storage & Cache)
//  Conforming to macOS 26 & MASTER.md (外方内圆: Squircle Containers + Capsule Controls)
//

import SwiftUI

public struct AgentManagementScreen: View {
    @State private var viewModel = WorkspaceViewModel.shared
    // 实际 Sheet 的关闭动画晚于操作状态清空；等 onDismiss 后再展示后台读取错误，避免弹窗竞争。
    @State private var isDeletionSheetVisible = false
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        Group {
            switch viewModel.selectedTab {
            case .sessions:
                AgentSessionsView(viewModel: viewModel)
            case .skills:
                AgentSkillsView(viewModel: viewModel)
            case .storage:
                AgentStorageView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .quotioPage()
        .navigationTitle("nav.agentManagement".localized())
        .toolbar {
            toolbarContent
        }
        .task {
            await viewModel.loadInitialDataIfNeeded()
        }
        .sheet(item: Binding(
            get: { viewModel.sessionDeletionProgress },
            set: { if $0 == nil { viewModel.dismissSessionDeletionProgress() } }
        ), onDismiss: { isDeletionSheetVisible = false }) { _ in
            // 用稳定操作 ID 驱动一次展示，内容观察 ViewModel；数量变化不重新创建删除任务。
            WorkspaceSessionDeletionProgressSheet(viewModel: viewModel)
                .onAppear { isDeletionSheetVisible = true }
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(QuotioTheme.Colors.success)
                        .font(.system(size: 13, weight: .semibold))
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color(red: 20/255, green: 24/255, blue: 36/255).opacity(0.95))
                        .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.32, dampingFraction: 0.76), value: toast)
            }
        }
        .alert("错误", isPresented: Binding(
            get: { viewModel.errorMessage != nil && viewModel.sessionDeletionProgress == nil && !isDeletionSheetVisible },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Toolbar Content

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            topSegmentedControl
        }

        ToolbarItemGroup(placement: .primaryAction) {
            topRightActions
        }
    }

    private var topSegmentedControl: some View {
        QuotioCapsuleSegmentedControl(
            options: WorkspaceTab.allCases,
            selection: $viewModel.selectedTab,
            size: .small,
            isEqualWidth: false
        ) { tab, isSelected in
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                Text(tab.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))

                let count = tabBadgeCount(for: tab)
                if !count.isEmpty {
                    Text(count)
                        .font(.system(size: 9.5, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                        )
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var topRightActions: some View {
        switch viewModel.selectedTab {
        case .sessions:
            Button {
                Task { await viewModel.refreshSessions() }
            } label: {
                if viewModel.isLoadingSessions { SmallProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }
            .help("刷新会话")
            .disabled(viewModel.isLoadingSessions || viewModel.isDeletingSessions)

        case .skills:
            Button {
                Task { await viewModel.refreshSkills() }
            } label: {
                // 与账户管理的刷新按钮一致：加载期间用菊花替换整枚图标，不挤动导航布局。
                if viewModel.isLoadingSkills { SmallProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }
            .help("刷新技能")
            .disabled(viewModel.isLoadingSkills || viewModel.isMutatingSkills)

            Button {
                viewModel.showAddRepoSheet = true
            } label: {
                Label("添加仓库源", systemImage: "plus")
            }
            .help("添加 GitHub 仓库源 (SQLite 存储)")

            Button {
                Task { await viewModel.exportSkillsBackup() }
            } label: {
                if viewModel.isExportingSkills { SmallProgressView() }
                else { Label("导出备份包", systemImage: "square.and.arrow.up") }
            }
            .help("导出全部技能为 .zip 归档文件")
            .disabled(viewModel.isMutatingSkills || viewModel.installedSkills.isEmpty)

            Button {
                Task { await viewModel.checkForSkillUpdates() }
            } label: {
                if viewModel.isCheckingSkillUpdates { SmallProgressView() }
                else { Label("检测更新", systemImage: "arrow.triangle.2.circlepath") }
            }
            .help("检测技能更新")
            .disabled(viewModel.isMutatingSkills || viewModel.isLoadingSkills || viewModel.installedSkills.isEmpty)

        case .storage:
            Button {
                Task { await viewModel.clearAllCaches() }
            } label: {
                if viewModel.cacheCleaningTarget == "all" { SmallProgressView() }
                else { Image(systemName: "trash") }
            }
            .help("清空全部智能体缓存")
            .disabled((viewModel.storageReport?.totalCacheBytes ?? 0) == 0 || viewModel.isCleaningStorage)

            Button {
                Task { await viewModel.analyzeStorage() }
            } label: {
                if viewModel.isAnalyzingStorage { SmallProgressView() }
                else { Label("重新度量", systemImage: "gauge") }
            }
            .help("重新分析磁盘与缓存占用")
            .disabled(viewModel.isAnalyzingStorage)
        }
    }

    private func tabBadgeCount(for tab: WorkspaceTab) -> String {
        switch tab {
        case .sessions:
            return viewModel.sessions.isEmpty ? "" : "\(viewModel.sessions.count)"
        case .skills:
            return viewModel.installedSkills.isEmpty ? "" : "\(viewModel.installedSkills.count)"
        case .storage:
            return ""
        }
    }
}

