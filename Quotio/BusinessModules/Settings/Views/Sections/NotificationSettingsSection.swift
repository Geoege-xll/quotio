//
//  NotificationSettingsSection.swift
//  Quotio
//

// 通知设置独立分区，所有绑定仍直接作用于原 NotificationManager.shared。
// 开关、阈值与授权提示的视图结构保持原样，不创建新的通知管理器或持久化状态。

import SwiftUI
import AppKit

struct NotificationSettingsSection: View {
    private let notificationManager = NotificationManager.shared
    
    var body: some View {
        @Bindable var manager = notificationManager
        
        Section {
            Toggle("settings.notifications.enabled".localized(), isOn: Binding(
                get: { manager.notificationsEnabled },
                set: { manager.notificationsEnabled = $0 }
            ))
            
            if manager.notificationsEnabled {
                Toggle("settings.notifications.quotaLow".localized(), isOn: Binding(
                    get: { manager.notifyOnQuotaLow },
                    set: { manager.notifyOnQuotaLow = $0 }
                ))
                
                Toggle("settings.notifications.cooling".localized(), isOn: Binding(
                    get: { manager.notifyOnCooling },
                    set: { manager.notifyOnCooling = $0 }
                ))
                
                Toggle("settings.notifications.proxyCrash".localized(), isOn: Binding(
                    get: { manager.notifyOnProxyCrash },
                    set: { manager.notifyOnProxyCrash = $0 }
                ))
                
                Toggle("settings.notifications.upgradeAvailable".localized(), isOn: Binding(
                    get: { manager.notifyOnUpgradeAvailable },
                    set: { manager.notifyOnUpgradeAvailable = $0 }
                ))
                
                HStack {
                    Text("settings.notifications.threshold".localized())
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Picker("settings.notifications.threshold".localized(), selection: Binding(
                        get: { Int(manager.quotaAlertThreshold) },
                        set: { manager.quotaAlertThreshold = Double($0) }
                    )) {
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                        Text("50%").tag(50)
                    }
                    .pickerStyle(.menu)
                    // 隐藏 Picker 自带标签，但保留无障碍名称；宽度由百分比、
                    // 系统菜单箭头和内边距共同决定，不再用 80 点硬裁切导致省略号。
                    .labelsHidden()
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 100, alignment: .trailing)
                    .layoutPriority(1)
                }
            }
            
            if !manager.isAuthorized {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("settings.notifications.notAuthorized".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("settings.notifications".localized(), systemImage: "bell")
        } footer: {
            Text("settings.notifications.help".localized())
                .font(.caption)
        }
    }
}

