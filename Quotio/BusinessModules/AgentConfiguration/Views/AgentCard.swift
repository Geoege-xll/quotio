//
//  AgentCard.swift
//  Quotio - Individual CLI agent card component
//

import SwiftUI

struct AgentCard: View {
    let status: AgentStatus
    var viewModel: AgentSetupViewModel? = nil
    let onConfigure: () -> Void

    @State private var showUninstallAlert = false
    @State private var isLaunching = false

    private var isCheckingUpdate: Bool {
        viewModel?.isCheckingUpdates[status.agent] == true
    }

    private var updateMessage: String? {
        viewModel?.updateMessages[status.agent]
    }

    private var remoteVersion: String? {
        viewModel?.remoteVersions[status.agent]
    }

    private var hasNewerVersion: Bool {
        viewModel?.hasNewerVersion(for: status) ?? false
    }

    var body: some View {
        HStack(spacing: 16) {
            // Agent Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(status.agent.color.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: status.agent.systemIcon)
                    .font(.title2)
                    .foregroundStyle(status.agent.color)
            }

            // Agent Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(status.agent.displayName)
                        .font(.headline)
                        .fontWeight(.semibold)

                    StatusBadge(status: status)

                    if let version = status.version {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if status.installed {
                        InstallMethodBadge(method: status.installMethod)
                    }

                    if let message = updateMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(hasNewerVersion ? .orange : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(hasNewerVersion ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                Text(status.agent.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let path = status.binaryPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Actions (分两行呈现：上层核心配置与升级，下层 CLI 调用与生命周期工具)
            VStack(alignment: .trailing, spacing: 8) {
                // 上行：核心配置与版本升级 (Primary Actions)
                HStack(spacing: 8) {
                    if hasNewerVersion {
                        Button {
                            Task { await viewModel?.upgradeAgent(status) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.circle.fill")
                                Text("agents.upgrade".localized())
                            }
                        }
                        .buttonStyle(.quotioPrimaryMicroCapsule(height: 26, tint: .orange))
                        .accessibilityIdentifier("agents.upgrade.\(status.agent.id)")
                    }

                    Button {
                        onConfigure()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: status.configured ? "arrow.triangle.2.circlepath" : "gearshape")
                            Text(status.configured ? "agents.reconfigure".localized() : "agents.configure".localized())
                        }
                    }
                    .buttonStyle(.quotioPrimaryMicroCapsule(height: 26, tint: status.agent.color))
                    .accessibilityIdentifier("agents.configure.\(status.agent.id)")
                }

                // 下行：运行与生命周期工具条 (Lifecycle & Utility Actions)
                HStack(spacing: 6) {
                    // 打开 CLI (Open in CLI)
                    Button {
                        Task {
                            isLaunching = true
                            defer { isLaunching = false }
                            try? await TerminalLauncher.shared.launchAgent(agent: status.agent, binaryPath: status.binaryPath)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                            Text("agents.open".localized())
                        }
                    }
                    .buttonStyle(.quotioMicroCapsule(height: 24))
                    .help("agents.open.help".localized())
                    .accessibilityIdentifier("agents.open.\(status.agent.id)")

                    // 检测升级 (Check Updates)
                    QuotioCircularIconButton(
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .secondary,
                        tooltip: "agents.checkUpdate".localized(),
                        isLoading: isCheckingUpdate
                    ) {
                        Task {
                            await viewModel?.checkForUpdate(for: status)
                        }
                    }
                    .accessibilityIdentifier("agents.checkUpdate.\(status.agent.id)")

                    // 文档 (Docs)
                    if let docsURL = status.agent.docsURL {
                        QuotioCircularIconButton(
                            systemImage: "book",
                            tint: .secondary,
                            tooltip: "agents.viewDocs".localized()
                        ) {
                            NSWorkspace.shared.open(docsURL)
                        }
                    }

                    // 卸载 (Uninstall) - 二次确认弹窗
                    QuotioCircularIconButton(
                        systemImage: "trash",
                        tint: .red,
                        backgroundTint: .red,
                        tooltip: "agents.uninstall".localized()
                    ) {
                        showUninstallAlert = true
                    }
                    .accessibilityIdentifier("agents.uninstall.\(status.agent.id)")
                }
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 16)
        .confirmationDialog(
            String(format: "agents.uninstall.confirm.title".localized(), status.agent.displayName),
            isPresented: $showUninstallAlert,
            titleVisibility: .visible
        ) {
            Button("agents.uninstall".localized(), role: .destructive) {
                Task {
                    await viewModel?.uninstallAgent(status)
                }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text(String(format: "agents.uninstall.confirm.message".localized(), status.uninstallCommand))
        }
    }
}

// MARK: - Installation Method Badge

private struct InstallMethodBadge: View {
    let method: AgentInstallMethod

    var body: some View {
        if method != .unknown {
            Text(method.displayName)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(method.badgeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(method.badgeColor.opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.statusColor)
                .frame(width: 6, height: 6)

            Text(status.statusLocalizationKey.localized())
                .font(.caption)
                .foregroundStyle(status.statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.statusColor.opacity(0.1))
        .clipShape(Capsule())
        // 「已配置」指 Quotio 的代理接入；Pi 自身登录其他提供商并不等于已接入 CPA。
        .help(status.agent == .pi ? "agents.pi.statusHelp".localized() : status.statusLocalizationKey.localized())
    }
}

#Preview {
    VStack(spacing: 16) {
        AgentCard(
            status: AgentStatus(
                agent: .claudeCode,
                installed: true,
                configured: true,
                binaryPath: "/usr/local/bin/claude",
                version: "1.0.0",
                lastConfigured: Date()
            ),
            onConfigure: {}
        )

        AgentCard(
            status: AgentStatus(
                agent: .openCode,
                installed: true,
                configured: false,
                binaryPath: nil,
                version: nil,
                lastConfigured: nil
            ),
            onConfigure: {}
        )
    }
    .padding()
    .frame(width: 600)
}
