//
//  AgentSetupScreen.swift
//  Quotio - Main agent setup screen
//

import SwiftUI

struct AgentSetupScreen: View {
    @Environment(QuotaViewModel.self) private var quotaViewModel
    @State private var selectedAgentForConfig: CLIAgent?
    @State private var sheetPresentationID = UUID()
    @State private var hasLoadedOnce = false
    
    private var viewModel: AgentSetupViewModel {
        quotaViewModel.agentSetupViewModel
    }
    
    private var sortedAgents: [AgentStatus] {
        viewModel.agentStatuses.sorted { status1, status2 in
            if status1.installed != status2.installed {
                return status1.installed
            }
            return status1.agent.displayName < status2.agent.displayName
        }
    }
    
    private var installedAgents: [AgentStatus] {
        sortedAgents.filter { $0.installed }
    }
    
    private var notInstalledAgents: [AgentStatus] {
        sortedAgents.filter { !$0.installed }
    }
    
    var body: some View {
        Group {
            agentListView
        }
        .quotioPage()
        .navigationTitle("agents.title".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.refreshAgentStatuses(forceRefresh: true)
                        // 可用模型已迁入本页，导航刷新同时刷新目录，沿用原来的竞态保护。
                        await quotaViewModel.refreshDashboardModels()
                    }
                } label: {
                    if viewModel.isLoading {
                        SmallProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)
            }
        }
        .task {
            if !hasLoadedOnce {
                await viewModel.refreshAgentStatuses()
                hasLoadedOnce = true
            }
        }
        .sheet(item: $selectedAgentForConfig) { (agent: CLIAgent) in
            let sessionID = sheetPresentationID
            AgentConfigSheet(viewModel: viewModel, agent: agent, configurationSessionID: sessionID)
                .id(sessionID)
                .onDisappear {
                    viewModel.dismissConfiguration(sessionID: sessionID)
                }
        }
    }
    
    private var agentListView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    if !installedAgents.isEmpty { installedSection }
                    if !notInstalledAgents.isEmpty { notInstalledSection }
                    // 原目录组件整体迁移，保留展开、复制和键盘焦点恢复，不另造缩减版模型列表。
                    AvailableModelsSection {
                        scrollProxy.scrollTo("model-catalog-details", anchor: .bottom)
                    }
                }
                .padding(20)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("agents.subtitle".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                StatChip(
                    icon: "checkmark.circle.fill",
                    value: "\(installedAgents.count)",
                    label: "agents.installed".localized(),
                    color: .green
                )
                
                StatChip(
                    icon: "gearshape.fill",
                    value: "\(installedAgents.filter { $0.configured }.count)",
                    label: "agents.configured".localized(),
                    color: .blue
                )

                Button {
                    quotaViewModel.currentPage = .agentManagement
                } label: {
                    StatChip(
                        icon: "slider.horizontal.2.square.on.square",
                        value: "智能体管理",
                        label: "会话 · 技能 · 存储",
                        color: .purple
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
    
    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("agents.installed".localized())
                .font(.headline)
                .foregroundStyle(.primary)
            
            LazyVStack(spacing: 12) {
                ForEach(installedAgents) { status in
                    AgentCard(
                        status: status,
                        viewModel: viewModel,
                        onConfigure: {
                            // 客户端目录和配置只使用客户端 API key，不能以 v8 管理密钥代替。
                            let apiKey = quotaViewModel.apiKeys.first ?? ""
                            sheetPresentationID = viewModel.startConfiguration(for: status.agent, apiKey: apiKey)
                            selectedAgentForConfig = status.agent
                        }
                    )
                }
            }
        }
    }
    
    private var notInstalledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("agents.notInstalled".localized())
                .font(.headline)
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 8) {
                ForEach(notInstalledAgents) { status in
                    NotInstalledAgentCard(agent: status.agent, viewModel: viewModel)
                }
            }
        }
    }
}

private struct StatChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
        )
    }
}

private struct NotInstalledAgentCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let agent: CLIAgent
    var viewModel: AgentSetupViewModel? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: agent.systemIcon)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            Text(agent.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            QuotioCircularIconButton(
                systemImage: "arrow.down.circle",
                tint: .blue,
                tooltip: String(format: "安装 %@".localized(), agent.displayName)
            ) {
                Task {
                    await viewModel?.installAgent(agent)
                }
            }
            .accessibilityIdentifier("agents.install.\(agent.id)")

            if let docsURL = agent.docsURL {
                QuotioCircularIconButton(
                    systemImage: "arrow.up.right",
                    tint: .secondary,
                    tooltip: "agents.viewDocs".localized()
                ) {
                    NSWorkspace.shared.open(docsURL)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
        )
    }
}

#Preview {
    AgentSetupScreen()
        .environment(QuotaViewModel())
        .frame(width: 700, height: 600)
}
