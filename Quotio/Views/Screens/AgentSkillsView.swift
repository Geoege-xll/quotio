//
//  AgentSkillsView.swift
//  Quotio - Unified Agent Management
//

import SwiftUI

/// 技能安装、发现和仓库管理的界面集中在此；共享弹窗由独立组件提供。
// MARK: - Skills View

struct AgentSkillsView: View {
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

                if let repository = viewModel.selectedRepo {
                    WorkspaceSkillRepositoryAddressButton(repository: repository)
                }
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
                    .lineLimit(1)
                    .truncationMode(.middle)

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
            return "按来源仓库展开技能；检测到内容差异后，可在对应仓库地址前更新。"
        case .discover:
            return "按 SKILL.md 官方规范拉取优质技能，一键部署并在多智能体中分发。"
        }
    }

    // MARK: - Installed Skills Content

    @ViewBuilder
    private var installedSkillsContent: some View {
        let groups = viewModel.installedSkillGroups
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
            } else if groups.isEmpty {
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
                    ForEach(groups) { group in
                        WorkspaceSkillRepositorySection(
                            group: group,
                            searchText: viewModel.skillSearchText,
                            hasUpdates: viewModel.installedSkills.contains {
                                viewModel.availableSkillUpdates.contains($0.directory) &&
                                $0.repoOwner?.localizedCaseInsensitiveCompare(group.repository?.owner ?? "") == .orderedSame &&
                                $0.repoName?.localizedCaseInsensitiveCompare(group.repository?.name ?? "") == .orderedSame
                            },
                            isUpdating: viewModel.updatingSkillRepositoryID == group.id,
                            isBusy: viewModel.isMutatingSkills,
                            onUpdate: { Task { await viewModel.updateAvailableSkills(in: group.id) } }
                        ) {
                            LazyVStack(spacing: 12) {
                                ForEach(group.skills) { skill in
                                    skillRow(skill: skill)
                                }
                            }
                        }
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

                        // 仓库来源已显示在折叠标题中；这里只展示可核实的技能目录提交时间。
                        if let sourceUpdatedAt = skill.sourceUpdatedAt, skill.isValidSourceUpdatedAt {
                            Text("更新于 \(sourceUpdatedAt.formatted(date: .abbreviated, time: .omitted))")
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
