//
//  MenuBarSettingsSection.swift
//  Quotio
//

// 菜单栏与 Dock 设置独立分区，保留原 MenuBarSettingsManager.shared 与环境模型。
// 双入口同时隐藏的保护、系统激活策略及缩减固定项的确认流程保持原样，
// 所有 @State、@AppStorage 和设置绑定仍由本视图持有，不新增状态副本。

import SwiftUI
import AppKit

// MARK: - Menu Bar Settings Section

struct MenuBarSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let settings = MenuBarSettingsManager.shared
    @AppStorage("showInDock") private var showInDock = true
    @State private var showTruncationAlert = false
    @State private var pendingMaxItems: Int?
    
    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarIcon },
            set: { newValue in
                // Prevent disabling both dock and menu bar icon (user would have no way to access app)
                if !newValue && !showInDock {
                    // Re-enable dock if user tries to disable menu bar icon while dock is already disabled
                    showInDock = true
                    // activation policy will be set by showInDockBinding automatically
                }
                settings.showMenuBarIcon = newValue
            }
        )
    }

    private var showInDockBinding: Binding<Bool> {
        Binding(
            get: { showInDock },
            set: { newValue in
                // Prevent disabling both dock and menu bar icon (user would have no way to access app)
                if !newValue && !settings.showMenuBarIcon {
                    // Re-enable menu bar icon if user tries to disable dock while menu bar is already disabled
                    settings.showMenuBarIcon = true
                }

                // Update the value
                showInDock = newValue

                // This is the ONLY place where activation policy is changed based on user settings
                // - true: dock icon always visible, even when window is closed
                // - false: dock icon never visible
                NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            }
        )
    }
    
    private var showQuotaBinding: Binding<Bool> {
        Binding(
            get: { settings.showQuotaInMenuBar },
            set: { settings.showQuotaInMenuBar = $0 }
        )
    }

    private var stackPairedQuotaMetricsBinding: Binding<Bool> {
        Binding(
            get: { settings.stackPairedQuotaMetrics },
            set: { settings.stackPairedQuotaMetrics = $0 }
        )
    }
    
    private var maxItemsBinding: Binding<Int> {
        Binding(
            get: { settings.menuBarMaxItems },
            set: { newValue in
                let clamped = min(max(newValue, MenuBarSettingsManager.minMenuBarItems), MenuBarSettingsManager.maxMenuBarItems)

                // Check if reducing max items would truncate current selection
                if clamped < settings.menuBarMaxItems && settings.selectedItems.count > clamped {
                    pendingMaxItems = clamped
                    showTruncationAlert = true
                } else {
                    settings.menuBarMaxItems = clamped
                    viewModel.syncMenuBarSelection()
                }
            }
        )
    }
    
    var body: some View {
        Section {
            Toggle("settings.showInDock".localized(), isOn: showInDockBinding)
            
            Toggle("settings.menubar.showIcon".localized(), isOn: showMenuBarIconBinding)
            
            if settings.showMenuBarIcon {
                Toggle("settings.menubar.showQuota".localized(), isOn: showQuotaBinding)
                
                if settings.showQuotaInMenuBar {
                    Toggle(
                        "settings.menubar.stackPairedQuotaMetrics".localized(),
                        isOn: stackPairedQuotaMetricsBinding
                    )

                    HStack {
                        Text("settings.menubar.maxItems".localized())
                        Spacer()
                        Text("\(settings.menuBarMaxItems)")
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Stepper(
                            "",
                            value: maxItemsBinding,
                            in: MenuBarSettingsManager.minMenuBarItems...MenuBarSettingsManager.maxMenuBarItems,
                            step: 1
                        )
                        .labelsHidden()
                    }
                }
            }
        } header: {
            Label("settings.navigation.menuBar.title".localized(), systemImage: "menubar.rectangle")
        } footer: {
            Text(String(
                format: "settings.menubar.help".localized(),
                settings.menuBarMaxItems
            ))
            .font(.caption)
        }
        .alert("menubar.truncation.title".localized(), isPresented: $showTruncationAlert) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingMaxItems = nil
            }
            Button("action.ok".localized(), role: .destructive) {
                if let newMax = pendingMaxItems {
                    settings.menuBarMaxItems = newMax
                    viewModel.syncMenuBarSelection()
                    pendingMaxItems = nil
                }
            }
        } message: {
            if let newMax = pendingMaxItems {
                Text(String(
                    format: "menubar.truncation.message".localized(),
                    settings.selectedItems.count,
                    newMax
                ))
            }
        }
    }
}

