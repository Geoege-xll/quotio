//
//  AgentSessionsView.swift
//  Quotio - Unified Agent Management
//

import SwiftUI

/// 会话列表、筛选和详情保持在同一文件，便于追踪同一页面的状态传递。
// MARK: - Sessions View

struct AgentSessionsView: View {
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
            } else if viewModel.rootFilteredSessions.isEmpty {
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
            .disabled(viewModel.isDeletingSessions)
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
            .disabled(viewModel.isDeletingSessions)
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
                            .disabled(viewModel.isDeletingSessions)
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
