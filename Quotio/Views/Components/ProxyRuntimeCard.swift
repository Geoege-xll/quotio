import SwiftUI

/// 本地代理的固定运行入口。进程生命周期和下载在服务层执行，卡片只呈现真实状态。
struct ProxyRuntimeCard: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var copyFeedback: String?

    private var manager: CLIProxyManager { viewModel.proxyManager }
    private var isBusy: Bool { manager.isStarting || manager.isStopping || manager.isDownloading }
    private var statusKey: String {
        if manager.isDownloading { return "runtime.installing" }
        if manager.isStopping { return "runtime.stopping" }
        if manager.isStarting { return "runtime.starting" }
        if !manager.isBinaryInstalled { return "dashboard.cliNotInstalled" }
        return manager.proxyStatus.running ? "runtime.running" : "runtime.stopped"
    }

    // 恢复原有完整运行卡：启停、地址、刷新与诊断操作直接保留在仪表盘顶部。
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部：服务器标识 + 状态胶囊与带图标的操作按钮
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    title
                    Spacer(minLength: 12)
                    runtimeControls
                }
                VStack(alignment: .leading, spacing: 12) {
                    title
                    runtimeControls
                }
            }

            // 地址栏：本地代理端点
            VStack(alignment: .leading, spacing: 6) {
                Text("runtime.localAddress".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(manager.baseURL)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    Button {
                        copy(manager.baseURL)
                    } label: {
                        Label("action.copy".localized(), systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // 底部操作区：刷新状态与复制 API 端点
            ViewThatFits(in: .horizontal) {
                HStack {
                    refreshControls
                    Spacer(minLength: 12)
                    copyAPIButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    refreshControls
                    copyAPIButton
                }
            }
            .buttonStyle(.borderless)

            if manager.isDownloading {
                ProgressView(value: manager.downloadProgress)
                    .accessibilityLabel("runtime.installing".localized())
            }

            if let error = manager.lastError ?? viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("logs.browser.open".localized()) {
                    // 复用设置内的日志目的地，主侧栏不再常驻诊断项。
                    viewModel.currentPage = .logs
                }
                .buttonStyle(.link)
            }

            if let copyFeedback {
                Text(copyFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .quotioCard()
    }

    private var refreshControls: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.refreshDashboard() }
            } label: {
                Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .disabled(isBusy || viewModel.isRefreshingDashboard || !manager.proxyStatus.running)

            if viewModel.isRefreshingDashboard {
                ProgressView().controlSize(.small)
                Text("runtime.refreshing".localized()).font(.caption)
            } else if let time = viewModel.dashboardRefreshTime {
                Text(String(format: "runtime.refreshed".localized(), time.formatted(date: .omitted, time: .standard)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var copyAPIButton: some View {
        Button {
            copy(manager.baseURL + "/v1")
        } label: {
            Label("runtime.copyAPI".localized(), systemImage: "doc.on.doc")
                .font(.caption)
        }
    }

    private var title: some View {
        HStack(spacing: 12) {
            // 服务器专属微质感 Squircle 底座
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.15, green: 0.40, blue: 0.95),
                                Color(red: 0.10, green: 0.65, blue: 0.85)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: Color.blue.opacity(0.25), radius: 4, x: 0, y: 2)

                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("runtime.title".localized())
                    .font(.headline)

                HStack(spacing: 5) {
                    Text((manager.allowNetworkAccess ? "runtime.network" : "runtime.localOnly").localized())
                    if let pid = manager.processIdentifier {
                        Text("· PID \(pid)")
                    } else if manager.proxyStatus.running {
                        Text("runtime.unknownPID".localized())
                    }
                    if manager.proxyStatus.running {
                        Text("· " + "runtime.running".localized())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var runtimeControls: some View {
        HStack(spacing: 10) {
            if isBusy {
                ProgressView().controlSize(.small)
            }

            // 状态指示胶囊
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.proxyStatus.running ? Color.green : Color.secondary.opacity(0.7))
                    .frame(width: 7, height: 7)

                Text(statusKey.localized())
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(manager.proxyStatus.running ? .green : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                manager.proxyStatus.running ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12),
                in: Capsule()
            )

            // 带醒目操作图标的启停控制按钮
            Button {
                Task {
                    if manager.isBinaryInstalled {
                        await viewModel.toggleProxy()
                    } else {
                        await viewModel.installDashboardProxy()
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if !manager.isBinaryInstalled {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("dashboard.installCLI".localized())
                    } else if manager.proxyStatus.running {
                        Image(systemName: "stop.fill")
                        Text("runtime.stop".localized())
                    } else {
                        Image(systemName: "play.fill")
                        Text("runtime.start".localized())
                    }
                }
                .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(
                !manager.isBinaryInstalled ? .blue :
                manager.proxyStatus.running ? Color(red: 0.88, green: 0.25, blue: 0.25) : .blue
            )
            .disabled(isBusy)
        }
    }

    /// 剪贴板写入也检查结果，避免系统拒绝时仍显示“已复制”。
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        let succeeded = NSPasteboard.general.setString(value, forType: .string)
        copyFeedback = (succeeded ? "availableModels.copied" : "runtime.copyFailed").localized()
    }
}
