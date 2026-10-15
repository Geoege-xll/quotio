//
//  PrivacySettingsSection.swift
//  Quotio
//

// 隐私设置独立分区，脱敏与遥测开关仍作用于各自原有单例。
// 保留原 @State 宿主与绑定写入关系，不改变偏好键、默认值及跨页面观察行为。

import SwiftUI
import AppKit

// MARK: - Privacy Settings Section

struct PrivacySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    @State private var telemetrySettings = TelemetrySettings.shared
    
    private var hideSensitiveBinding: Binding<Bool> {
        Binding(
            get: { settings.hideSensitiveInfo },
            set: { settings.hideSensitiveInfo = $0 }
        )
    }

    private var shareAnonymousUsageBinding: Binding<Bool> {
        Binding(
            get: { telemetrySettings.shareAnonymousUsage },
            set: { telemetrySettings.shareAnonymousUsage = $0 }
        )
    }
    
    var body: some View {
        Section {
            Toggle("settings.privacy.hideSensitive".localized(), isOn: hideSensitiveBinding)
            Toggle("settings.privacy.shareAnonymousUsage".localized(), isOn: shareAnonymousUsageBinding)
        } header: {
            Label("settings.privacy".localized(), systemImage: "eye.slash")
        } footer: {
            Text("settings.privacy.help".localized())
                .font(.caption)
        }
    }
}

