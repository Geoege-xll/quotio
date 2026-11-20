//
//  ProxyRequiredView.swift
//  Quotio - Unified "Proxy Not Running" view component
//

import SwiftUI

/// 代理不可用时复用同一个空态，将安装或重启引导至路由中心。
struct ProxyRequiredView: View {
    let title: String
    let description: String?
    let icon: String
    let onOpenRoutingCenter: () -> Void
    
    init(
        title: String? = nil,
        description: String? = nil,
        icon: String = "network.slash",
        onOpenRoutingCenter: @escaping () -> Void
    ) {
        self.title = title ?? "empty.proxyNotRunning".localized()
        self.description = description
        self.icon = icon
        self.onOpenRoutingCenter = onOpenRoutingCenter
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Icon with animated gradient background
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.15), .purple.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            // Text content
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            }
            
            Button(action: onOpenRoutingCenter) {
                Label("runtime.openRoutingCenter".localized(), systemImage: "arrow.triangle.branch")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview {
    ProxyRequiredView(
        description: "Start the proxy to manage API keys"
    ) {
        // 预览仅显示空态和导航操作。
    }
    .frame(width: 500, height: 400)
}
