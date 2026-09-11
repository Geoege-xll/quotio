//
//  AgentManagementScreen.swift
//  Quotio - Unified Agent Management (Sessions, Skills, Storage & Cache)
//  Conforming to macOS 26 & MASTER.md (外方内圆: Squircle Containers + Capsule Controls)
//

import SwiftUI

public struct AgentManagementScreen: View {
    @State private var viewModel = WorkspaceViewModel.shared
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
            get: { viewModel.errorMessage != nil },
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
                HStack(spacing: 4) {
                    if viewModel.isLoadingSessions {
                        ProgressView().controlSize(.mini)
                    }
                    Label("刷新会话", systemImage: "arrow.clockwise")
                }
            }
            .help("刷新会话")
            .disabled(viewModel.isLoadingSessions)

        case .skills:
            Button {
                viewModel.showAddRepoSheet = true
            } label: {
                Label("添加仓库源", systemImage: "plus")
            }
            .help("添加 GitHub 仓库源 (SQLite 存储)")

            Button {
                Task { await viewModel.exportSkillsBackup() }
            } label: {
                HStack(spacing: 4) {
                    if viewModel.isExportingSkills {
                        ProgressView().controlSize(.mini)
                    }
                    Label("导出备份包", systemImage: "square.and.arrow.up")
                }
            }
            .help("导出全部技能为 .zip 归档文件")
            .disabled(viewModel.isMutatingSkills || viewModel.installedSkills.isEmpty)

            Button {
                Task { await viewModel.updateAllSkills() }
            } label: {
                HStack(spacing: 4) {
                    if viewModel.isUpdatingAllSkills {
                        ProgressView().controlSize(.mini)
                    }
                    Label("一键全部更新", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .help("更新所有已安装技能")
            .disabled(viewModel.isMutatingSkills || viewModel.installedSkills.isEmpty)

        case .storage:
            Button {
                Task { await viewModel.analyzeStorage() }
            } label: {
                HStack(spacing: 4) {
                    if viewModel.isAnalyzingStorage {
                        ProgressView().controlSize(.mini)
                    }
                    Label("重新度量", systemImage: "gauge")
                }
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

// MARK: - Backwards Compatibility Alias
public typealias WorkspaceScreen = AgentManagementScreen

// MARK: - Sessions View

private struct AgentSessionsView: View {
    @Bindable var viewModel: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Level-2 Agent Filter Bar & Mode Controls
            agentFilterBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(QuotioTheme.Colors.sidebarBorder(for: colorScheme))
                        .frame(height: 0.5)
                }

            Group {
                if let selected = viewModel.selectedSession {
                    GeometryReader { geo in
                        let totalWidth = geo.size.width
                        // 左右 2:3 固定比例（左侧 40%，右侧 60%），左侧窄右侧宽，无中间分割线且不可手动调整宽度
                        let leftWidth = max(220, min(360, totalWidth * 0.40))
                        let rightWidth = max(0, totalWidth - leftWidth)

                        HStack(spacing: 0) {
                            sessionListContent(isSplit: true)
                                .frame(width: leftWidth)

                            sessionDetailView(session: selected)
                                .frame(width: rightWidth)
                        }
                    }
                } else {
                    sessionListContent(isSplit: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.74), value: viewModel.selectedSession != nil)
        .onChange(of: viewModel.selectedAgentFilter) { _, newFilter in
            if let current = viewModel.selectedSession, current.agent != newFilter {
                viewModel.closeSelectedSession()
            }
        }
    }

    // MARK: - Agent Filter Bar

    private var agentFilterBar: some View {
        // 顶部分段选择 (Capsule Segmented Control): [ Claude Code | Codex | OpenCode | Pi | Antigravity ]
        ScrollView(.horizontal, showsIndicators: false) {
            QuotioCapsuleSegmentedControl(
                options: WorkspaceAgent.allCases,
                selection: Binding(
                    get: { viewModel.selectedAgentFilter },
                    set: { newAgent in
                        Task { await viewModel.selectAgentFilter(newAgent) }
                    }
                ),
                size: .small,
                optionTint: { agent in
                    agent.color
                },
                isEqualWidth: false
            ) { agent, isSelected in
                HStack(spacing: 5) {
                    Image(systemName: agent.systemIcon)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    Text(agent.displayName)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))

                    let count = agentSessionCount(for: agent)
                    if !count.isEmpty {
                        Text(count)
                            .font(.system(size: 9.5, weight: .bold))
                            .monospacedDigit()
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isSelected ? agent.color.opacity(0.18) : Color.primary.opacity(0.06))
                            )
                            .foregroundStyle(isSelected ? agent.color : Color.secondary)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private func agentSessionCount(for agent: WorkspaceAgent) -> String {
        let count = viewModel.sessions.filter { $0.agent == agent }.count
        return count > 0 ? "\(count)" : ""
    }

    private func sessionListContent(isSplit: Bool) -> some View {
        VStack(spacing: 0) {
            // Search Bar & List Controls Header
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    QuotioCapsuleTextField(
                        "搜索会话标题、项目路径...",
                        text: $viewModel.sessionSearchText,
                        systemImage: "magnifyingglass"
                    )

                    QuotioCircularIconButton(
                        systemImage: viewModel.isGroupedView ? "folder.fill" : "list.bullet",
                        tint: viewModel.isGroupedView ? .accentColor : .secondary
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                            viewModel.isGroupedView.toggle()
                        }
                    }
                    .help(viewModel.isGroupedView ? "当前：按项目分组（点击切换为平铺列表）" : "当前：平铺列表（点击切换为按项目分组）")

                    QuotioCircularIconButton(
                        systemImage: viewModel.batchDeleteMode ? "checkmark.circle.fill" : "checkmark.circle",
                        tint: viewModel.batchDeleteMode ? .accentColor : .secondary
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                            viewModel.batchDeleteMode.toggle()
                            if !viewModel.batchDeleteMode {
                                viewModel.selectedSessionIDs.removeAll()
                            }
                        }
                    }
                    .help("批量选择管理")
                }

                // Batch Action Bar
                if viewModel.batchDeleteMode {
                    HStack(spacing: 10) {
                        Text("已选择 \(viewModel.selectedSessionIDs.count) 个会话")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Spacer()

                        if !viewModel.selectedSessionIDs.isEmpty {
                            Button {
                                Task { await viewModel.deleteSelectedBatchSessions() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                    Text("删除选中")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(QuotioTheme.Colors.danger))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isDeletingSessions)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                    .overlay(
                        Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(10)
            .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(QuotioTheme.Colors.sidebarBorder(for: colorScheme))
                    .frame(height: 0.5)
            }

            // Session Items List
            if viewModel.isLoadingSessions && viewModel.sessions.isEmpty {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: "bubble.left.and.text.bubble.right.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(spacing: 4) {
                        Text("正在扫描各智能体会话...")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("正在索引历史会话与 Subagent 子任务")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    ProgressView().controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if viewModel.filteredSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("未发现符合条件的会话")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("你可以打开终端使用 Claude / Codex / OpenCode / Antigravity 发起对话")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if viewModel.isGroupedView {
                            ForEach(viewModel.projectGroups, id: \.id) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    // Project Group Header
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(group.projectName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.primary)

                                        Spacer()

                                        Text("\(group.sessions.count)")
                                            .font(.system(size: 10, weight: .bold))
                                            .monospacedDigit()
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(QuotioTheme.Colors.cardTag(for: colorScheme))
                                            )
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 2)

                                    ForEach(group.sessions) { session in
                                        sessionItemContainer(session: session, isSplit: isSplit)
                                    }
                                }
                            }
                        } else {
                            ForEach(viewModel.rootFilteredSessions) { session in
                                sessionItemContainer(session: session, isSplit: isSplit)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(QuotioTheme.Colors.canvasBackground(for: colorScheme))
    }

    // MARK: - Session Item Container with Hierarchical Subagents

    @ViewBuilder
    private func sessionItemContainer(session: WorkspaceSession, isSplit: Bool) -> some View {
        let subagents = viewModel.descendantRows(for: session)
        let isExpanded = viewModel.isSubagentExpanded(session.id)

        VStack(alignment: .leading, spacing: 4) {
            sessionRowCard(session: session, subagentCount: subagents.count, isSplit: isSplit)

            if !subagents.isEmpty && isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    // 复用已定稿的子任务行，只补齐原先不可达的孙级及更深层级。
                    ForEach(subagents, id: \.session.id) { row in
                        subagentRowCard(subagent: row.session, parent: session, isSplit: isSplit)
                            .padding(.leading, CGFloat(min(row.depth - 1, 6)) * 12)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Session Row Card

    private func sessionRowCard(session: WorkspaceSession, subagentCount: Int = 0, isSplit: Bool = false) -> some View {
        let isSelected = viewModel.selectedSession?.id == session.id

        return Button {
            Task { await viewModel.selectSession(session) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                // Top Row: Title (Left) + Time (Top Right)
                HStack(alignment: .center, spacing: 6) {
                    if viewModel.batchDeleteMode {
                        Toggle("", isOn: Binding(
                            get: { viewModel.selectedSessionIDs.contains(session.id) },
                            set: { selected in
                                if selected { viewModel.selectedSessionIDs.insert(session.id) }
                                else { viewModel.selectedSessionIDs.remove(session.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }

                    Text(session.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    Text(relativeDate(session.lastActiveAt))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .fixedSize()
                }

                // Bottom Row: Agent + Project (Left) + Subagent Expand Button (Bottom Right)
                HStack(alignment: .center, spacing: 5) {
                    Text(session.agent.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(session.agent.color)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text(session.projectName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    if subagentCount > 0 {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                                viewModel.toggleSubagentExpansion(session.id)
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text("\(subagentCount)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .monospacedDigit()
                                Image(systemName: viewModel.isSubagentExpanded(session.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 7.5, weight: .bold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? Color.white.opacity(0.22)
                                        : (viewModel.isSubagentExpanded(session.id)
                                            ? Color.accentColor.opacity(0.18)
                                            : QuotioTheme.Colors.cardTag(for: colorScheme))
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isSelected
                                        ? Color.white.opacity(0.32)
                                        : (viewModel.isSubagentExpanded(session.id)
                                            ? Color.accentColor.opacity(0.4)
                                            : QuotioTheme.Colors.sidebarBorder(for: colorScheme)),
                                    lineWidth: 0.5
                                )
                            )
                            .foregroundStyle(
                                isSelected
                                    ? Color.white
                                    : (viewModel.isSubagentExpanded(session.id) ? Color.accentColor : Color.secondary)
                            )
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .contentShape(Capsule())
                        .help(viewModel.isSubagentExpanded(session.id) ? "收起 \(subagentCount) 个子任务" : "展开 \(subagentCount) 个子任务")
                    } else if !isSplit {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .fill(isSelected ? Color.accentColor : QuotioTheme.Colors.cardBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.8) : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                    lineWidth: 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
        .contextMenu {
            Button {
                Task { await viewModel.resumeSession(session) }
            } label: {
                Label("在终端中继续", systemImage: "terminal.fill")
            }

            Button {
                viewModel.copyResumeCommand(session: session)
            } label: {
                Label("复制恢复命令", systemImage: "doc.on.doc")
            }

            Button {
                viewModel.revealInFinder(session: session)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                Task { await viewModel.deleteSession(session) }
            } label: {
                Label("删除会话", systemImage: "trash")
            }
        }
    }

    // MARK: - Subagent Row Card (Indented Child)

    private func subagentRowCard(subagent: WorkspaceSession, parent: WorkspaceSession, isSplit: Bool) -> some View {
        let isSelected = viewModel.selectedSession?.id == subagent.id

        return Button {
            Task { await viewModel.selectSession(subagent) }
        } label: {
            HStack(spacing: 8) {
                // Branch connector icon
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : subagent.agent.color)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(subagent.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)

                        Spacer()

                        Text(relativeDate(subagent.lastActiveAt))
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    }

                    HStack(spacing: 5) {
                        Text("子任务")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isSelected ? Color.white.opacity(0.2) : subagent.agent.color.opacity(0.12))
                            )
                            .foregroundStyle(isSelected ? Color.white : subagent.agent.color)

                        if let summary = subagent.summary, !summary.isEmpty, summary != subagent.title {
                            Text(summary)
                                .font(.system(size: 10))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .fill(isSelected ? Color.accentColor : QuotioTheme.Colors.cardInset(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.8) : QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(0.6),
                        lineWidth: 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await viewModel.resumeSession(subagent) }
            } label: {
                Label("在独立终端恢复此子任务", systemImage: "terminal.fill")
            }

            Button {
                viewModel.copyResumeCommand(session: subagent)
            } label: {
                Label("复制恢复命令", systemImage: "doc.on.doc")
            }

            Button {
                viewModel.revealInFinder(session: subagent)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                Task { await viewModel.deleteSession(subagent) }
            } label: {
                Label("删除子任务", systemImage: "trash")
            }
        }
    }

    // MARK: - Session Detail View

    private func sessionDetailView(session: WorkspaceSession) -> some View {
        VStack(spacing: 0) {
            // Header Surface Card
            VStack(alignment: .leading, spacing: 8) {
                // Top Row: Agent & Project Badges on Left, Pure Icon Micro-Buttons on Right
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        // Agent Capsule Badge
                        HStack(spacing: 4) {
                            Circle().fill(session.agent.color).frame(width: 5.5, height: 5.5)
                            Text(session.agent.displayName)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(session.agent.color)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(session.agent.color.opacity(colorScheme == .dark ? 0.20 : 0.12))
                        )
                        .fixedSize()

                        // Project Badge (with lineLimit & truncationMode to protect right buttons)
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text(session.projectName)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(QuotioTheme.Colors.cardTag(for: colorScheme))
                        )
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)

                    // Action Controls - Unified 26pt Circular Icon Buttons
                    HStack(spacing: 6) {
                        QuotioCircularIconButton(
                            systemImage: "terminal.fill",
                            tint: .accentColor
                        ) {
                            Task { await viewModel.resumeSelectedSession() }
                        }
                        .help("在独立终端中继续此会话")

                        QuotioCircularIconButton(
                            systemImage: "doc.on.doc",
                            tint: .secondary
                        ) {
                            viewModel.copyResumeCommand(session: session)
                        }
                        .help("复制终端恢复命令行")

                        QuotioCircularMenu(
                            systemImage: "ellipsis",
                            tint: .secondary
                        ) {
                            Button {
                                viewModel.revealInFinder(session: session)
                            } label: {
                                Label("在访达中显示", systemImage: "folder")
                            }

                            Divider()

                            Button(role: .destructive) {
                                Task { await viewModel.deleteSession(session) }
                            } label: {
                                Label("删除此会话", systemImage: "trash")
                            }
                        }
                        .help("更多操作")

                        QuotioCircularIconButton(systemImage: "xmark") {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.74)) {
                                viewModel.closeSelectedSession()
                            }
                        }
                        .help("关闭详情")
                    }
                }

                // Full-width Session Title (with vertical spacing from top bar, extending all the way to the right)
                Text(session.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)

                if let dir = session.projectDirectory {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(dir)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                            .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                }
            }
            .padding(12)
            .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(QuotioTheme.Colors.sidebarBorder(for: colorScheme))
                    .frame(height: 0.5)
            }

            // Message Stream
            if viewModel.isLoadingMessages {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("正在解析历史消息...").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.selectedSessionMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("暂无历史消息文本记录")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(viewModel.selectedSessionMessages) { message in
                            messageBubbleCard(message: message)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubbleCard(message: WorkspaceSessionMessage) -> some View {
        switch message.role {
        case .user:
            userMessageBubble(message)
        case .assistant:
            assistantMessageBubble(message)
        case .tool, .system:
            systemOrToolMessageBubble(message)
        }
    }

    private func userMessageBubble(_ message: WorkspaceSessionMessage) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 64)

            VStack(alignment: .trailing, spacing: 3) {
                Text(message.content)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                            .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.45 : 0.30), lineWidth: 0.8)
                    )
                    .contextMenu {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            viewModel.toastMessage = "已复制消息内容"
                        } label: {
                            Label("复制内容", systemImage: "doc.on.doc")
                        }
                    }

                if let ts = message.timestamp {
                    Text(ts, style: .time)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)
                }
            }
        }
    }

    private func assistantMessageBubble(_ message: WorkspaceSessionMessage) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 7) {
                    if let tools = message.toolCalls, !tools.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(tools, id: \.self) { tool in
                                HStack(spacing: 3) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .font(.system(size: 9))
                                    Text(tool)
                                        .font(.system(size: 10, design: .monospaced))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(QuotioTheme.Colors.cardTag(for: colorScheme)))
                                .overlay(
                                    Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text(message.content)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                        .fill(QuotioTheme.Colors.cardBackground(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                        .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.04),
                    radius: 4,
                    x: 0,
                    y: 1.5
                )
                .contextMenu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        viewModel.toastMessage = "已复制消息内容"
                    } label: {
                        Label("复制内容", systemImage: "doc.on.doc")
                    }
                }

                HStack(spacing: 6) {
                    if let ts = message.timestamp {
                        Text(ts, style: .time)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        viewModel.toastMessage = "已复制消息内容"
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("复制消息")
                }
            }

            Spacer(minLength: 64)
        }
    }

    private func systemOrToolMessageBubble(_ message: WorkspaceSessionMessage) -> some View {
        HStack {
            Spacer(minLength: 24)

            HStack(spacing: 5) {
                Image(systemName: message.role.icon)
                    .font(.system(size: 9.5))

                Text(message.content)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme)))
            .overlay(
                Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
            .foregroundStyle(.secondary)

            Spacer(minLength: 24)
        }
        .padding(.vertical, 3)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Skills View

private struct AgentSkillsView: View {
    @Bindable var viewModel: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSkillForSheet: WorkspaceSkill?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: SSOT Hero Overview Card
                ssotHeroCard

                // Section 2: Skills Sub-Tabs & Content (已纳管技能 ↔ 从 GitHub 发现)
                skillsSubTabSection
            }
            .padding(24)
        }
        .sheet(item: $selectedSkillForSheet) { skill in
            SkillDetailSheet(skill: skill)
        }
        .sheet(isPresented: $viewModel.showAddRepoSheet) {
            AddRepoSheet(viewModel: viewModel)
        }
    }

    // MARK: - SSOT Hero Card

    private var ssotHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("智能体技能管理中心")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)

                        Text("~/.quotio/skills/")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme)))
                            .overlay(Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5))
                            .foregroundStyle(.secondary)
                    }

                    Text("技能统一保存在标准 SSOT 目录，通过系统软链接按需挂载至各智能体，操作前自动快照备份。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // Stat Wells (支持点击快速跳转对应 Tab)
            HStack(spacing: 12) {
                statWell(
                    title: "已纳管技能",
                    value: "\(viewModel.installedSkills.count)",
                    unit: "个",
                    icon: "folder.badge.gearshape",
                    isSelected: viewModel.selectedSkillSubTab == .installed
                ) {
                    Task { await viewModel.selectSkillSubTab(.installed) }
                }

                statWell(
                    title: "支持智能体",
                    value: "\(WorkspaceAgent.allCases.count)",
                    unit: "类",
                    icon: "terminal",
                    isSelected: false,
                    action: nil
                )

                statWell(
                    title: "仓库源 (SQLite)",
                    value: "\(viewModel.repos.count)",
                    unit: "源",
                    icon: "cylinder.split.1x2",
                    isSelected: viewModel.selectedSkillSubTab == .discover
                ) {
                    Task { await viewModel.selectSkillSubTab(.discover) }
                }
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 18)
    }

    private func statWell(
        title: String,
        value: String,
        unit: String,
        icon: String,
        isSelected: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.accentColor.opacity(0.85))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 3) {
                        Text(value)
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text(unit)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08) : QuotioTheme.Colors.cardInset(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: - Unmanaged Local Skills Alert

    private var unmanagedSkillsAlert: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(QuotioTheme.Colors.warning)
                Text("发现 \(viewModel.unmanagedSkills.count) 个未受管本地技能")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(QuotioTheme.Colors.warning)
                Spacer()
                Button {
                    Task { await viewModel.importAllUnmanagedSkills() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 11))
                        Text("一键全部纳管 (\(viewModel.unmanagedSkills.count))")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .buttonStyle(.quotioPrimaryMicroCapsule(height: 26))
            }

            Text("检测到在各智能体独立目录中手动存放的技能。点击“纳管到统一库”可迁移至 ~/.quotio/skills/ 并在原路径建立受管链接；同名内容冲突会保留原文件并提示。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(viewModel.unmanagedSkills) { unmanaged in
                    HStack(spacing: 10) {
                        Image(systemName: unmanaged.agent.systemIcon)
                            .foregroundStyle(unmanaged.agent.color)
                            .font(.system(size: 14))

                        Text(unmanaged.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("来源: \(unmanaged.agent.displayName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            Task { await viewModel.importUnmanagedSkill(unmanaged) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 10))
                                Text("纳管到统一库")
                            }
                        }
                        .buttonStyle(.quotioMicroCapsule)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                            .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .fill(QuotioTheme.Colors.warning.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.warning.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Skills Sub-Tabs & Content Section

    private var skillsSubTabSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Bar: 分段选择器 + 对应的右侧操作区
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    subTabSegmentedControl
                    Spacer(minLength: 12)
                    subTabHeaderActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    subTabSegmentedControl
                    subTabHeaderActions
                }
            }

            // 动态说明文案
            Text(subTabSubtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            // 选项卡对应的内容区
            switch viewModel.selectedSkillSubTab {
            case .installed:
                installedSkillsContent
                    .disabled(viewModel.isMutatingSkills)
            case .discover:
                discoverSkillsContent
            }
        }
    }

    private var subTabSegmentedControl: some View {
        QuotioCapsuleSegmentedControl(
            WorkspaceSkillSubTab.allCases,
            selection: Binding(
                get: { viewModel.selectedSkillSubTab },
                set: { newTab in
                    Task { await viewModel.selectSkillSubTab(newTab) }
                }
            ),
            size: .medium,
            isEqualWidth: false,
            icon: { $0.icon },
            badge: { tab in
                switch tab {
                case .installed:
                    return "\(viewModel.installedSkills.count)"
                case .discover:
                    return viewModel.discoverableSkills.isEmpty ? nil : "\(viewModel.discoverableSkills.count)"
                }
            },
            title: { $0.title }
        )
    }

    @ViewBuilder
    private var subTabHeaderActions: some View {
        switch viewModel.selectedSkillSubTab {
        case .installed:
            QuotioCapsuleTextField(
                "筛选已纳管技能...",
                text: $viewModel.skillSearchText,
                systemImage: "magnifyingglass"
            )
            .frame(width: 220)
        case .discover:
            HStack(spacing: 8) {
                QuotioCapsuleTextField(
                    "搜索 GitHub 技能...",
                    text: $viewModel.skillSearchText,
                    systemImage: "magnifyingglass"
                )
                .frame(width: 180)

                repoDropdownMenu
            }
        }
    }

    private var repoDropdownMenu: some View {
        Menu {
            Button {
                viewModel.showAddRepoSheet = true
            } label: {
                Label("添加自定义仓库源...", systemImage: "plus")
            }

            Divider()

            ForEach(viewModel.repos) { repo in
                Button {
                    viewModel.selectedRepo = repo
                    Task { await viewModel.fetchDiscoverableSkills(repo: repo) }
                } label: {
                    HStack {
                        Text("\(repo.owner)/\(repo.name)")
                        if viewModel.selectedRepo?.id == repo.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)

                Text(viewModel.selectedRepo.map { "\($0.owner)/\($0.name)" } ?? "选择仓库源")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
            )
            .overlay(
                Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
    }

    private var subTabSubtitle: String {
        switch viewModel.selectedSkillSubTab {
        case .installed:
            return "点击智能体胶囊即可实时挂载/解除软链接，状态即刻生效。"
        case .discover:
            return "按 SKILL.md 官方规范拉取优质技能，一键部署并在多智能体中分发。"
        }
    }

    // MARK: - Installed Skills Content

    @ViewBuilder
    private var installedSkillsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Unmanaged Local Skills Alert (if any)
            if !viewModel.unmanagedSkills.isEmpty {
                unmanagedSkillsAlert
            }

            if viewModel.isLoadingSkills && viewModel.installedSkills.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("正在扫描已安装技能与智能体软链接...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .quotioCard(cornerRadius: QuotioTheme.Radius.lg)
            } else if viewModel.installedSkills.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("暂未安装技能")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await viewModel.selectSkillSubTab(.discover) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 11))
                            Text("前往「从 GitHub 发现」一键安装")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.quotioPrimaryMicroCapsule(height: 28))
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .quotioCard(cornerRadius: QuotioTheme.Radius.lg)
            } else if viewModel.filteredInstalledSkills.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("未找到与“\(viewModel.skillSearchText)”匹配的已纳管技能")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("清空搜索") {
                        viewModel.skillSearchText = ""
                    }
                    .buttonStyle(.quotioMicroCapsule(height: 24))
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .quotioCard(cornerRadius: QuotioTheme.Radius.lg)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.filteredInstalledSkills) { skill in
                        skillRow(skill: skill)
                    }
                }
            }
        }
    }

    private func skillRow(skill: WorkspaceSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Section: Info & Action Buttons
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)

                        // GitHub Repo badge if linked
                        if let owner = skill.repoOwner, let repo = skill.repoName {
                            HStack(spacing: 3) {
                                Image(systemName: "link")
                                    .font(.system(size: 8.5))
                                Text("\(owner)/\(repo)")
                                    .font(.system(size: 10.5))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.blue.opacity(colorScheme == .dark ? 0.20 : 0.10)))
                            .foregroundStyle(Color.blue)
                        }

                        // Updated timestamp (仅在获取到真实有效更新时间时展示，排查掉 0001 年 / 1970 年等占位值)
                        if let updatedAt = skill.updatedAt, skill.isValidUpdatedAt {
                            Text("更新于 \(updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    } else {
                        Text("暂无详细功能描述")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Quick Action Buttons
                HStack(spacing: 8) {
                    let allEnabled = WorkspaceAgent.allCases.allSatisfy { skill.enabledAgents.contains($0) }
                    Button {
                        Task {
                            await viewModel.bulkToggleSkillAll(skill: skill, enable: !allEnabled)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: allEnabled ? "xmark.circle" : "checkmark.circle")
                                .font(.system(size: 10.5))
                            Text(allEnabled ? "全部停用" : "全部启用")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.quotioMicroCapsule(height: 26))
                    .help(allEnabled ? "解除此技能在所有智能体中的软链接" : "向所有智能体分发此技能软链接")

                    Button(role: .destructive) {
                        Task { await viewModel.uninstallSkill(skill: skill) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.red.opacity(colorScheme == .dark ? 0.20 : 0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("卸载此技能并清理软链接 (自动生成备份快照)")
                }
            }

            Divider()
                .overlay(QuotioTheme.Colors.sidebarBorder(for: colorScheme))

            // Symlink Distribution Controls
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text("分发软链接至智能体:")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("(点击智能体胶囊建立或解除软链接挂载)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }

                HStack(spacing: 8) {
                    ForEach(WorkspaceAgent.allCases) { agent in
                        let isEnabled = skill.enabledAgents.contains(agent)

                        Button {
                            Task {
                                await viewModel.toggleSkillAgent(skill: skill, agent: agent, enable: !isEnabled)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: agent.systemIcon)
                                    .font(.system(size: 11))

                                Text(agent.displayName)
                                    .font(.system(size: 11, weight: isEnabled ? .semibold : .medium))

                                Image(systemName: isEnabled ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.system(size: 10, weight: isEnabled ? .bold : .regular))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 27)
                            .background(
                                Capsule().fill(
                                    isEnabled
                                        ? agent.color.opacity(colorScheme == .dark ? 0.24 : 0.14)
                                        : QuotioTheme.Colors.cardInset(for: colorScheme)
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isEnabled
                                        ? agent.color.opacity(0.50)
                                        : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                                    lineWidth: 0.8
                                )
                            )
                            .foregroundStyle(isEnabled ? agent.color : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isEnabled ? "已挂载至 \(agent.displayName)，点击解除软链接" : "未挂载至 \(agent.displayName)，点击建立软链接")
                    }

                    Spacer()
                }
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 16)
    }

    // MARK: - Discover Skills Content

    @ViewBuilder
    private var discoverSkillsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.isDiscoveringSkills {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在查询 GitHub 仓库目录树与规范...").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 32)
                .quotioCard(cornerRadius: QuotioTheme.Radius.lg)
            } else if viewModel.discoverableSkills.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("该仓库源暂未解析到符合 SKILL.md 规范的技能目录。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let repo = viewModel.selectedRepo {
                        Button {
                            Task { await viewModel.fetchDiscoverableSkills(repo: repo) }
                        } label: {
                            Label("重试加载", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.quotioMicroCapsule(height: 26))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .quotioCard(cornerRadius: QuotioTheme.Radius.lg)
            } else if viewModel.filteredDiscoverableSkills.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("未找到与“\(viewModel.skillSearchText)”匹配的 GitHub 技能")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("清空搜索") {
                        viewModel.skillSearchText = ""
                    }
                    .buttonStyle(.quotioMicroCapsule(height: 24))
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .quotioCard(cornerRadius: QuotioTheme.Radius.lg)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 14)], spacing: 14) {
                    ForEach(viewModel.filteredDiscoverableSkills) { skill in
                        discoverableSkillCard(skill: skill)
                    }
                }
            }
        }
    }

    private func discoverableSkillCard(skill: DiscoverableSkill) -> some View {
        // 本地同名目录不等于同一来源；标签与服务的来源冲突判断保持一致。
        let isAlreadyInstalled = viewModel.installedSkills.contains {
            $0.directory == skill.directory && $0.repoOwner == skill.repoOwner &&
            $0.repoName == skill.repoName && $0.repositoryRelativePath == skill.repositoryRelativePath
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(skill.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isAlreadyInstalled {
                    Text("已安装")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(QuotioTheme.Colors.success.opacity(0.18))
                        )
                        .foregroundStyle(QuotioTheme.Colors.success)
                }
            }

            HStack(spacing: 6) {
                Text(skill.directory)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    Task {
                        await viewModel.installSkill(skill, targetAgents: Set(WorkspaceAgent.allCases))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isAlreadyInstalled ? "arrow.clockwise" : "arrow.down.circle.fill")
                            .font(.system(size: 10.5))
                        Text(isAlreadyInstalled ? "重新安装" : "一键安装到全部")
                    }
                }
                .buttonStyle(isAlreadyInstalled ? .quotioMicroCapsule : .quotioMicroCapsule)
                .disabled(viewModel.isMutatingSkills)
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.md, padding: 14)
    }
}

// MARK: - Storage & Cache View

private struct AgentStorageView: View {
    @Bindable var viewModel: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let report = viewModel.storageReport {
                storageContent(report: report)
                    .transition(.opacity)
            } else {
                storageLoadingLayer
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.storageReport != nil)
    }

    private func storageContent(report: WorkspaceStorageReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Top Storage Overview Card
                storageOverviewCard(report: report)

                // Per-Agent Breakdown Section
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("各智能体占用明细与专属清理")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.primary)
                            Text("会话历史、补全缓存与诊断日志分布概览")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(report.items) { item in
                            agentStorageCard(item: item)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Loading Layer

    private var storageLoadingLayer: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.xl, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.18), Color.purple.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.xl, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.5)
                    )

                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("正在分析智能体存储与缓存...")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                Text("正在快速度量各智能体的历史会话、模型补全缓存与诊断日志分布")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 4)

            // Agent Chips Indicators
            HStack(spacing: 8) {
                ForEach(WorkspaceAgent.allCases) { agent in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(agent.color)
                            .frame(width: 7, height: 7)
                        Text(agent.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule()
                            .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Overview Card

    private func storageOverviewCard(report: WorkspaceStorageReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 编码智能体总磁盘占用")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(formatBytes(report.totalBytes))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("覆盖 Claude Code、Codex、OpenCode、Pi、Antigravity 及 Quotio 网关")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Actions: One-click Cache Clean + 30-day Pruning (上下布局，空间利用更合理)
                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        Task { await viewModel.clearAllCaches() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 10))
                            Text("清空缓存 (\(formatBytes(report.totalCacheBytes)))")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.quotioPrimaryMicroCapsule(height: 26))
                    .disabled(report.totalCacheBytes == 0 || viewModel.isCleaningStorage)

                    if report.oldSessionsCount > 0 {
                        Button {
                            Task { await viewModel.cleanOldSessions(days: 30) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                Text("清理旧会话 (\(formatBytes(report.oldSessionsBytes)))")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .buttonStyle(.quotioMicroCapsule(height: 26))
                        .disabled(viewModel.isCleaningStorage)
                    }
                }
            }

            // Proportional Multi-Agent Continuous Bar
            VStack(spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(report.items) { item in
                            if report.totalBytes > 0 && item.totalBytes > 0 {
                                let width = max(4, geo.size.width * CGFloat(item.totalBytes) / CGFloat(report.totalBytes))
                                Rectangle()
                                    .fill(item.agent.color)
                                    .frame(width: width)
                                    .help("\(item.agent.displayName): \(formatBytes(item.totalBytes))")
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 12)
                .background(
                    Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                )

                // Legend: 默认标准启动窗口下自适应 2 行，拉宽窗口自动伸展为 1 行
                QuotioLegendFlowLayout(spacing: 16, lineSpacing: 8) {
                    ForEach(report.items) { item in
                        HStack(spacing: 5) {
                            Circle().fill(item.agent.color).frame(width: 7, height: 7)
                            Text(item.agent.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(formatBytes(item.totalBytes))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.xl, padding: 20)
    }

    // MARK: - Agent Storage Card

    private func agentStorageCard(item: AgentStorageUsage) -> some View {
        VStack(spacing: 12) {
            // Tier 1: Agent Squircle Icon + Name & Path + Total Size
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                        .fill(item.agent.color.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    Image(systemName: item.agent.systemIcon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(item.agent.color)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.agent.displayName)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(.primary)

                        Text(agentStoragePathHint(for: item.agent))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                            )
                    }

                    Text("历史会话、模型补全与诊断日志")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Total size
                Text(formatBytes(item.totalBytes))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            // Tier 2: Capsule metric chips on left, Action Button on right
            HStack(spacing: 8) {
                metricTag(
                    icon: "bubble.left.fill",
                    label: "会话",
                    size: formatBytes(item.sessionBytes),
                    count: item.sessionCount > 0 ? "\(item.sessionCount) 个" : nil
                )

                metricTag(
                    icon: "bolt.fill",
                    label: "缓存",
                    size: formatBytes(item.cacheBytes),
                    count: nil,
                    isHighlighted: item.cacheBytes > 0
                )

                metricTag(
                    icon: "doc.text.fill",
                    label: "日志",
                    size: formatBytes(item.logBytes),
                    count: nil
                )

                Spacer()

                if item.cacheBytes > 0 {
                    Button {
                        Task { await viewModel.clearAgentCaches(item.agent) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("清空缓存")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.quotioMicroCapsule(height: 24))
                    .disabled(viewModel.isCleaningStorage)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("缓存已空")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.04))
                    )
                }
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 14)
    }

    private func agentStoragePathHint(for agent: WorkspaceAgent) -> String {
        switch agent {
        case .claude: return "~/.claude"
        case .codex: return "~/.codex"
        case .opencode: return "~/.opencode"
        case .pi: return "~/.pi"
        case .agy: return "~/.gemini"
        }
    }

    private func metricTag(icon: String, label: String, size: String, count: String? = nil, isHighlighted: Bool = false) -> some View {
        HStack(spacing: 4.5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)

            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text(size)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            if let count {
                Text("(\(count))")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            Capsule()
                .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Legend Flow Layout

private struct QuotioLegendFlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxLineWidth = max(maxLineWidth, currentX - spacing)
        }

        let totalHeight = currentY + lineHeight
        let actualWidth = proposal.width ?? maxLineWidth
        return (CGSize(width: actualWidth, height: totalHeight), positions)
    }
}

// MARK: - Modals & Sheets

private struct SkillDetailSheet: View {
    let skill: WorkspaceSkill
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var fileContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("~/.quotio/skills/\(skill.directory)/SKILL.md")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.quotioSecondaryCapsule)
            }

            Divider()
                .overlay(QuotioTheme.Colors.sidebarBorder(for: colorScheme))

            ScrollView {
                Text(fileContent.isEmpty ? "正在读取 SKILL.md 文档内容..." : fileContent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .background(QuotioTheme.Colors.canvasBackground(for: colorScheme))
        .task {
            let path = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent(".quotio/skills/\(skill.directory)/SKILL.md")
            fileContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "未找到 SKILL.md 文件"
        }
    }
}

private struct AddRepoSheet: View {
    @Bindable var viewModel: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("添加 GitHub 技能仓库源")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                Text("输入开源仓库（例如: anthropics/skills 或完整 GitHub 链接）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            QuotioCapsuleTextField(
                "例如: anthropics/skills",
                text: $viewModel.newRepoURL,
                systemImage: "network",
                monospaced: true
            )

            HStack(spacing: 12) {
                Button("取消") {
                    viewModel.showAddRepoSheet = false
                }
                .buttonStyle(.quotioSecondaryCapsule)

                Button {
                    Task { await viewModel.addRepo(url: viewModel.newRepoURL) }
                } label: {
                    Text("添加并拉取")
                }
                .buttonStyle(.quotioPrimaryCapsule)
                .disabled(viewModel.newRepoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(QuotioTheme.Colors.canvasBackground(for: colorScheme))
    }
}
