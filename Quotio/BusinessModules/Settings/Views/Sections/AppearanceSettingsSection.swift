//
//  AppearanceSettingsSection.swift
//  Quotio
//

// 外观偏好独立分区，原 AppearanceManager.shared、绑定和选择控件保持不变。
// 文件拆分仅调整维护位置，不新增主题状态或修改外观偏好的持久化方式。

import SwiftUI
import AppKit

// MARK: - Appearance Settings Section

struct AppearanceSettingsSection: View {
    @State private var appearanceManager = AppearanceManager.shared
    
    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(
            get: { appearanceManager.appearanceMode },
            set: { appearanceManager.appearanceMode = $0 }
        )
    }
    
    var body: some View {
        Section {
            SettingsChoiceControl("settings.appearance.mode", options: AppearanceMode.allCases, selection: appearanceModeBinding) {
                $0.localizationKey.localized()
            }
        } header: {
            Label("settings.appearance.title".localized(), systemImage: "paintbrush")
        } footer: {
            Text("settings.appearance.help".localized())
                .font(.caption)
        }
    }
}

