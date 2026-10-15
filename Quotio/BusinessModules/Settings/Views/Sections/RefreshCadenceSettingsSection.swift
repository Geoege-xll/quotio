//
//  RefreshCadenceSettingsSection.swift
//  Quotio
//

// 刷新周期设置分区，周期偏好仍由 RefreshSettingsManager.shared 唯一管理。
// 手动刷新按钮继续调用环境中的 QuotaViewModel；Task 保留在原按钮回调，
// 本文件不注册计时器，也不接管应用级刷新任务。

import SwiftUI
import AppKit

// MARK: - Refresh Cadence Settings Section

struct RefreshCadenceSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var refreshSettings = RefreshSettingsManager.shared
    
    private var cadenceBinding: Binding<RefreshCadence> {
        Binding(
            get: { refreshSettings.refreshCadence },
            set: { refreshSettings.refreshCadence = $0 }
        )
    }
    
    var body: some View {
        Section {
            Picker("settings.refresh.cadence".localized(), selection: cadenceBinding) {
                ForEach(RefreshCadence.allCases) { cadence in
                    Text(cadence.localizationKey.localized()).tag(cadence)
                }
            }
            
            if refreshSettings.refreshCadence == .manual {
                Button {
                    Task {
                        await viewModel.manualRefresh()
                    }
                } label: {
                    Label("settings.refresh.now".localized(), systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Label("settings.refresh".localized(), systemImage: "clock.arrow.2.circlepath")
        } footer: {
            Text("settings.refresh.help".localized())
                .font(.caption)
        }
    }
}

