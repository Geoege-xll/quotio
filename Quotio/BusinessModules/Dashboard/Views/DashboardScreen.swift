//
//  DashboardScreen.swift
//  Quotio
//

import SwiftUI
import UniformTypeIdentifiers

struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("hideGettingStarted") private var hideGettingStarted: Bool = false

    @State private var selectedProvider: AIProvider?
    @State private var isImporterPresented = false
    /// 快捷配置与客户端页使用同一只读呈现契约，避免首次 sheet 捕获另一个 State 中的旧会话。
    /// 此页面仍只持有自身呈现状态，配置草稿和保存事务继续归原 AgentSetupViewModel。
    @State private var configurationPresentation: AgentConfigurationPresentation?


    private var showGettingStarted: Bool {
        guard !hideGettingStarted else { return false }
        return !isSetupComplete
    }

    private var isSetupComplete: Bool {
        viewModel.proxyManager.isBinaryInstalled &&
        viewModel.proxyManager.proxyStatus.running &&
        !viewModel.authFiles.isEmpty &&
        viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured })
    }


    var body: some View {
        ScrollView {
            // 停机和缺少内核时都保留运行卡，安装、重试和诊断入口始终可达。
            VStack(alignment: .leading, spacing: 12) {
                ProxyRuntimeCard()
                RoutingCenterView()

                if showGettingStarted {
                    gettingStartedSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .quotioPage()
        .navigationTitle("nav.dashboard".localized())
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider) {
                selectedProvider = nil
                viewModel.cancelOAuth()
                Task { await viewModel.refreshData() }
            }
            .environment(viewModel)
        }
        .sheet(item: $configurationPresentation) { presentation in
            AgentConfigSheet(viewModel: viewModel.agentSetupViewModel, agent: presentation.agent, configurationSessionID: presentation.id)
                .id(presentation.id)
                .onDisappear {
                    viewModel.agentSetupViewModel.dismissConfiguration(sessionID: presentation.id)
                    Task { await viewModel.agentSetupViewModel.refreshAgentStatuses() }
                }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await viewModel.importVertexServiceAccount(url: url)
                    await viewModel.refreshData()
                }
            }
        }
        .task {
            await viewModel.agentSetupViewModel.refreshAgentStatuses()
        }
    }

    // MARK: - Getting Started Section

    private var gettingStartedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("dashboard.gettingStarted".localized(), systemImage: "sparkles")
                    .font(.headline)

                Spacer()

                Button {
                    withAnimation { hideGettingStarted = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("action.dismiss".localized())
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(gettingStartedSteps) { step in
                    GettingStartedStepRow(
                        step: step,
                        onAction: { handleStepAction(step) }
                    )

                    if step.id != gettingStartedSteps.last?.id {
                        Divider()
                    }
                }
            }
        }
        .quotioCard()
    }

    private var gettingStartedSteps: [GettingStartedStep] {
        [
            GettingStartedStep(
                id: "provider",
                icon: "person.2.badge.key",
                title: "onboarding.addProvider".localized(),
                description: "onboarding.addProviderDesc".localized(),
                isCompleted: !viewModel.authFiles.isEmpty,
                actionLabel: viewModel.authFiles.isEmpty ? "providers.addProvider".localized() : nil
            ),
            GettingStartedStep(
                id: "agent",
                icon: "terminal",
                title: "onboarding.configureAgent".localized(),
                description: "onboarding.configureAgentDesc".localized(),
                isCompleted: viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured }),
                actionLabel: viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured }) ? nil : "agents.configure".localized()
            )
        ]
    }

    private func handleStepAction(_ step: GettingStartedStep) {
        switch step.id {
        case "provider":
            showProviderPicker()
        case "agent":
            showAgentPicker()
        default:
            break
        }
    }

    private func showProviderPicker() {
        let alert = NSAlert()
        alert.messageText = "providers.addProvider".localized()
        alert.informativeText = "onboarding.addProviderDesc".localized()

        let providers = AIProvider.allCases.filter(\.supportsLocalProxySetup)
        for provider in providers {
            alert.addButton(withTitle: provider.displayName)
        }
        alert.addButton(withTitle: "action.cancel".localized())

        let response = alert.runModal()
        let index = response.rawValue - 1000

        if index >= 0 && index < providers.count {
            let provider = providers[index]
            if provider == .vertex {
                isImporterPresented = true
            } else {
                viewModel.cancelOAuth()
                selectedProvider = provider
            }
        }
    }

    private func showAgentPicker() {
        let installedAgents = viewModel.agentSetupViewModel.agentStatuses.filter { $0.installed }
        guard let firstAgent = installedAgents.first else { return }

        // 客户端目录和配置只使用客户端 API key，不能以 v8 管理密钥代替。
        let apiKey = viewModel.apiKeys.first ?? ""
        let sessionID = viewModel.agentSetupViewModel.startConfiguration(for: firstAgent.agent, apiKey: apiKey)
        configurationPresentation = AgentConfigurationPresentation(id: sessionID, agent: firstAgent.agent)
    }


}

// MARK: - Getting Started Step

struct GettingStartedStep: Identifiable {
    let id: String
    let icon: String
    let title: String
    let description: String
    let isCompleted: Bool
    let actionLabel: String?
}

struct GettingStartedStepRow: View {
    let step: GettingStartedStep
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(step.isCompleted ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)

                if step.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title)
                        .font(.headline)

                    if step.isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                Text(step.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let actionLabel = step.actionLabel {
                Button(actionLabel) {
                    onAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}
