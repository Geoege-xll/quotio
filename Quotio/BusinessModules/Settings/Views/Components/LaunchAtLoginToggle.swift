//
//  LaunchAtLoginToggle.swift
//  Quotio
//

// 登录启动开关独立组件，继续使用原 LaunchAtLoginManager.shared。
// 权限错误、应用位置提示与 onAppear 状态读取保持在原视图中，
// 不接管系统登录项生命周期，也不改变原有设置写入与跳转行为。

import SwiftUI
import AppKit

// MARK: - Launch at Login Toggle

/// Reusable toggle component for Launch at Login functionality
/// Uses LaunchAtLoginManager for proper SMAppService handling
struct LaunchAtLoginToggle: View {
    private let launchManager = LaunchAtLoginManager.shared
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showLocationWarning = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("settings.launchAtLogin".localized(), isOn: Binding(
                get: { launchManager.isEnabled },
                set: { newValue in
                    do {
                        try launchManager.setEnabled(newValue)
                        
                        // Show warning if app is not in /Applications when enabling
                        if newValue && !launchManager.isInValidLocation {
                            showLocationWarning = true
                        } else {
                            showLocationWarning = false
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            ))
            
            // Show location warning inline
            if showLocationWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("launchAtLogin.warning.notInApplications".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
            }
        }
        .onAppear {
            // Refresh status when view appears to sync with System Settings
            launchManager.refreshStatus()
        }
        .alert("launchAtLogin.error.title".localized(), isPresented: $showError) {
            Button("OK".localized()) { showError = false }
            Button("launchAtLogin.openSystemSettings".localized()) {
                launchManager.openSystemSettings()
                showError = false
            }
        } message: {
            Text(errorMessage)
        }
    }
}

