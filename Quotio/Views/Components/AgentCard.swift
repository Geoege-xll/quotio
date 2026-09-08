//
//  AgentCard.swift
//  Quotio - Individual CLI agent card component
//

import SwiftUI

struct AgentCard: View {
    let status: AgentStatus
    let onConfigure: () -> Void
    
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

                    // Pi 的版本来自包元数据或成功的版本探测，便于核对多种安装方式下实际选中的版本。
                    if status.agent == .pi, let version = status.version {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            
            // Actions
            HStack(spacing: 8) {
                if let docsURL = status.agent.docsURL {
                    Link(destination: docsURL) {
                        Image(systemName: "book")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("agents.viewDocs".localized())
                }
                
                Button {
                    onConfigure()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: status.configured ? "arrow.triangle.2.circlepath" : "gearshape")
                        Text(status.configured ? "agents.reconfigure".localized() : "agents.configure".localized())
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(status.agent.color)
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 16)
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .stroke(status.configured ? status.agent.color.opacity(0.35) : Color.clear, lineWidth: 1)
        )
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
