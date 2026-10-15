//
//  MenuNetworkInfoView.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏代理连接信息与原运行状态快照。
/// 运行状态和端口仍通过原闭包在视图读取时获取；复制反馈状态及其任务继续归原视图持有。
// MARK: - Network Info View (Proxy + Tunnel Combined)

/// 菜单代理行的只读呈现状态。通过读取闭包在 body 内取值，让运行中、启停中和端口
/// 都跟随实际服务更新；闭包也允许用隔离状态验证菜单，不启动真实服务或访问钥匙串。
struct MenuProxyState {
    let port: UInt16
    let isRunning: Bool
    var isStarting = false
    var isStopping = false

    var isBusy: Bool { isStarting || isStopping }
    var actionKey: String {
        if isStopping { return "runtime.stopping" }
        if isStarting { return "runtime.starting" }
        return isRunning ? "action.stopProxy" : "action.startProxy"
    }
}

struct MenuNetworkInfoView: View {
    let proxyState: () -> MenuProxyState
    let onProxyToggle: () -> Void
    let onCopyProxyURL: () -> Void
    let onTunnelToggle: () -> Void
    let onCopyTunnelURL: () -> Void

    private let tunnelManager = TunnelManager.shared
    private var tunnelStatus: CloudflareTunnelStatus { tunnelManager.tunnelState.status }
    private var tunnelURL: String? { tunnelManager.tunnelState.publicURL }

    @State private var didCopyProxy = false
    @State private var didCopyTunnel = false

    private enum CopyTarget {
        case proxy
        case tunnel
    }

    var body: some View {
        // 这里读取代理的可观察属性，使原 NSMenuItem 中的图标、提示和禁用状态原位更新。
        let proxy = proxyState()
        let isProxyRunning = proxy.isRunning
        let proxyURL = "http://127.0.0.1:\(proxy.port)"
        VStack(spacing: 8) {
            // Proxy Row
            HStack(spacing: 8) {
                Circle()
                    .fill(isProxyRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)

                Text("providers.source.proxy".localized())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                if isProxyRunning {
                    Text(proxyURL)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("menubar.proxy.endpoint")

                    copyButton(
                        isCopied: didCopyProxy,
                        helpText: "action.copy".localized()
                    ) {
                        onCopyProxyURL()
                        triggerCopyState(.proxy)
                    }
                }

                Spacer()

                Button(action: onProxyToggle) {
                    if proxy.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isProxyRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(isProxyRunning ? .red : .green)
                    }
                }
                .buttonStyle(.plain)
                .disabled(proxy.isBusy)
                .help(proxy.actionKey.localized())
                .accessibilityLabel(proxy.actionKey.localized())
                .accessibilityIdentifier("menubar.proxy.toggle")
            }

            // Tunnel Row (only show when proxy is running)
            if isProxyRunning {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tunnelStatus == .active ? Color.blue : Color.gray)
                        .frame(width: 6, height: 6)

                    Text(tunnelStatus == .active ? "tunnel.action.stop".localized() : "tunnel.action.start".localized())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    if tunnelStatus == .active, let url = tunnelURL {
                        Text(url.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        copyButton(
                            isCopied: didCopyTunnel,
                            helpText: "action.copy".localized()
                        ) {
                            onCopyTunnelURL()
                            triggerCopyState(.tunnel)
                        }
                    } else if tunnelStatus == .starting {
                        Text("status.starting".localized())
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button(action: onTunnelToggle) {
                        Image(systemName: tunnelStatus == .active || tunnelStatus == .starting ? "stop.fill" : "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(tunnelStatus == .active ? .red : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(tunnelStatus == .starting || tunnelStatus == .stopping)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func triggerCopyState(_ target: CopyTarget) {
        setCopied(target, value: true)

        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                setCopied(target, value: false)
            }
        }
    }

    private func setCopied(_ target: CopyTarget, value: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch target {
            case .proxy:
                didCopyProxy = value
            case .tunnel:
                didCopyTunnel = value
            }
        }
    }

    @ViewBuilder
    private func copyButton(isCopied: Bool, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(isCopied ? .green : .secondary)
                .scaleEffect(isCopied ? 1.05 : 1)
                .animation(.easeInOut(duration: 0.2), value: isCopied)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
