//
//  OperatingModeSection.swift
//  Quotio
//

// 运行模式设置独立分区，继续由原 OperatingModeSection 持有模式选择与确认弹窗状态。
// 模式管理器仍使用同一单例；停止代理及重新初始化的调用和 Task 保持在原视图中。

import SwiftUI
import AppKit

// MARK: - Operating Mode Section

struct OperatingModeSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = OperatingModeManager.shared
    @State private var showModeChangeConfirmation = false
    @State private var pendingMode: OperatingMode?
    
    var body: some View {
        Section {
            // 复用原有模式卡片的图标、徽标和选中效果，两个弹性列各占一半可用宽度。
            // 点击仍进入原来的确认与切换流程，不因布局调整直接写入运行模式。
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(OperatingMode.allCases) { mode in
                    OperatingModeCard(
                        mode: mode,
                        isSelected: modeManager.currentMode == mode,
                        onSelect: { handleModeSelection(mode) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.navigation.mode.features".localized())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(modeManager.currentMode.features, id: \.self) { feature in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(QuotioTheme.Colors.codexGreen)
                                .padding(.top, 1)
                            Text(feature)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } header: {
            Label("settings.appMode".localized(), systemImage: "switch.2")
        } footer: {
            footerText
        }
        .alert("settings.appMode.switchConfirmTitle".localized(), isPresented: $showModeChangeConfirmation) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingMode = nil
            }
            Button("action.switch".localized()) {
                if let mode = pendingMode {
                    switchToMode(mode)
                }
                pendingMode = nil
            }
        } message: {
            Text("settings.appMode.switchConfirmMessage".localized())
        }
    }
    
    @ViewBuilder
    private var footerText: some View {
        switch modeManager.currentMode {
        case .monitor:
            Label("settings.appMode.quotaOnlyNote".localized(), systemImage: "info.circle")
                .font(.caption)
        case .localProxy:
            EmptyView()
        }
    }
    
    private func handleModeSelection(_ mode: OperatingMode) {
        guard mode != modeManager.currentMode else { return }
        
        // Confirm when switching FROM local proxy mode (stops the local proxy)
        if modeManager.currentMode == .localProxy && mode == .monitor {
            pendingMode = mode
            showModeChangeConfirmation = true
        } else {
            // Switch immediately for other transitions
            switchToMode(mode)
        }
    }
    
    private func switchToMode(_ mode: OperatingMode) {
        modeManager.switchMode(to: mode) {
            viewModel.stopProxy()
        }
        
        // Re-initialize based on new mode
        Task {
            await viewModel.initialize()
        }
    }
}

