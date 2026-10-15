//
//  QuotaDisplaySettingsSection.swift
//  Quotio
//

// 额度展示偏好分区，继续复用原菜单栏设置单例及既有分段选择控件。
// @State 的宿主与绑定 setter 保持在本类型中，不改变额度显示方式和已有偏好键。

import SwiftUI
import AppKit

// MARK: - Quota Display Settings Section

struct QuotaDisplaySettingsSection: View {
    @Environment(QuotaHistoryService.self) private var history
    @State private var settings = MenuBarSettingsManager.shared
    
    private var displayModeBinding: Binding<QuotaDisplayMode> {
        Binding(
            get: { settings.quotaDisplayMode },
            set: { settings.quotaDisplayMode = $0 }
        )
    }
    
    private var displayStyleBinding: Binding<QuotaDisplayStyle> {
        Binding(
            get: { settings.quotaDisplayStyle },
            set: { settings.quotaDisplayStyle = $0 }
        )
    }
    
    var body: some View {
        Section {
            SettingsChoiceControl("settings.quota.displayMode", options: [QuotaDisplayMode.used, .remaining], selection: displayModeBinding) {
                ($0 == .used ? "settings.quota.displayMode.used" : "settings.quota.displayMode.remaining").localized()
            }
            
            SettingsChoiceControl("settings.quota.displayStyle", options: QuotaDisplayStyle.allCases, selection: displayStyleBinding) {
                $0.localizationKey.localized()
            }
            Toggle("quota.history.recording".localized(), isOn: Binding(
                get: { history.recordingEnabled },
                set: { enabled in Task { await history.setRecordingEnabled(enabled) } }))
                .disabled(history.isSuspended || history.isClearing)
        } header: {
            Label("settings.quota.display".localized(), systemImage: "percent")
        } footer: {
            Text("settings.quota.display.help".localized())
                .font(.caption)
        }
    }
}

