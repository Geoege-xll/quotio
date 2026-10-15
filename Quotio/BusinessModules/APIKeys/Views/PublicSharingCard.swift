import SwiftUI

/// 公开分享入口独立持有弹窗状态，页面迁移不会改变共享隧道管理器及其现有配置。
/// 继续使用页面注入的配额视图模型，为隧道设置保留原有服务操作环境。
struct PublicSharingCard: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var showTunnelSheet = false

    private var tunnelManager: TunnelManager { TunnelManager.shared }

    // 分享状态、地址复制及设置弹窗沿用原实现，不改变隧道服务的生命周期。

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.18), Color.purple.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)

                    Image(systemName: "globe")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("tunnel.section.title".localized())
                            .font(.headline)

                        TunnelStatusBadge(status: tunnelManager.tunnelState.status, compact: true)
                    }

                    if tunnelManager.tunnelState.isActive, let url = tunnelManager.tunnelState.publicURL {
                        Text(url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .monospaced()
                    } else {
                        Text("tunnel.section.description".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if tunnelManager.tunnelState.isActive {
                    Button {
                        tunnelManager.copyURLToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("action.copy".localized())
                }

                Button {
                    showTunnelSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .quotioCard()
        .sheet(isPresented: $showTunnelSheet) {
            TunnelSheet()
                .environment(viewModel)
        }
    }
}
