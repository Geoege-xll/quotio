//
//  LocalProxyServerSection.swift
//  Quotio
//

// 本地代理设置及其网络访问子分区；NetworkAccessSection 仍只接收现有 Binding。
// 端口、监听开关的暂存状态和初次加载抑制继续属于 LocalProxyServerSection，
// 单例管理器、偏好写入时机与原页面组合关系均保持不变。

import SwiftUI
import AppKit

// MARK: - Local Proxy Server Section

struct LocalProxyServerSection: View {
    /// 新设置页将管理密钥移到隐私与安全；默认值保留旧调用点的完整展示行为。
    var showsManagementKey = true
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @AppStorage("autoStartTunnel") private var autoStartTunnel = false
    @AppStorage("autoRestartTunnel") private var autoRestartTunnel = false
    // 局域网开关先保存在视图状态；管理器确认密钥和监听地址写入成功后才更新 UserDefaults。
    // 直接用 @AppStorage 会先写偏好，导致管理器把本次切换误判成“值未变化”而跳过配置更新。
    @State private var allowNetworkAccess = false
    @State private var portText: String = ""
    @State private var isLoadingConfig = false  // Prevents onChange from firing during initial load
    
    var body: some View {
        Group {
        Section {
            HStack {
                Text("settings.port".localized())
                Spacer()
                TextField("settings.port".localized(), text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: portText) { _, newValue in
                        guard !isLoadingConfig else { return }
                        if let port = UInt16(newValue), port > 0 {
                            viewModel.proxyManager.port = port
                        }
                    }
            }
            
            LabeledContent("settings.status".localized()) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(viewModel.proxyManager.proxyStatus.running ? "status.running".localized() : "status.stopped".localized())
                }
            }
            
            LabeledContent("settings.endpoint".localized()) {
                Text(viewModel.proxyManager.proxyStatus.endpoint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            
            if showsManagementKey { ManagementKeyRow() }
            
            Toggle("settings.autoStartProxy".localized(), isOn: $autoStartProxy)
            
            Toggle("settings.autoStartTunnel".localized(), isOn: $autoStartTunnel)
                .disabled(!viewModel.tunnelManager.installation.isInstalled)
            
            Toggle("settings.autoRestartTunnel".localized(), isOn: $autoRestartTunnel)
                .disabled(!viewModel.tunnelManager.installation.isInstalled)
                

                

        } header: {
            Label("settings.proxyServer".localized(), systemImage: "server.rack")
        } footer: {
            Text("settings.restartProxy".localized())
                .font(.caption)
        }
            NetworkAccessSection(allowNetworkAccess: $allowNetworkAccess)
                .onChange(of: allowNetworkAccess) { _, newValue in
                    guard !isLoadingConfig else { return }
                    viewModel.proxyManager.allowNetworkAccess = newValue
                    // 配置不可写时管理器会保留原偏好；把开关回退到真实访问模式。
                    if viewModel.proxyManager.allowNetworkAccess != newValue {
                        allowNetworkAccess = viewModel.proxyManager.allowNetworkAccess
                    }
                }
        }
        .onAppear {
            isLoadingConfig = true
            portText = String(viewModel.proxyManager.port)
            allowNetworkAccess = viewModel.proxyManager.allowNetworkAccess
            // Delay clearing the flag to allow onChange to be suppressed
            DispatchQueue.main.async {
                isLoadingConfig = false
            }
        }
    }
}

struct NetworkAccessSection: View {
    @Binding var allowNetworkAccess: Bool
    
    var body: some View {
        Section {
            Toggle("settings.allowNetworkAccess".localized(), isOn: $allowNetworkAccess)
            
            LabeledContent("settings.bindAddress".localized()) {
                Text(allowNetworkAccess ? "0.0.0.0 (All Interfaces)" : "127.0.0.1 (Localhost)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(allowNetworkAccess ? .orange : .secondary)
            }
            
            if allowNetworkAccess {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("settings.networkAccessWarning".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("settings.networkAccess".localized(), systemImage: "network")
        } footer: {
            Text("settings.networkAccessFooter".localized())
                .font(.caption)
        }
    }
}

