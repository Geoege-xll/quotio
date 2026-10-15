//
//  UsageDisplaySettingsSection.swift
//  Quotio
//

// 用量展示偏好独立分区，继续通过原菜单栏设置单例编辑汇总与模型聚合方式。
// 选择控件、绑定 setter、默认值和持久化键均保持原样，不在此创建统计状态。

import SwiftUI
import AppKit

// MARK: - Usage Display Settings Section

struct UsageDisplaySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    
    private var totalUsageModeBinding: Binding<TotalUsageMode> {
        Binding(
            get: { settings.totalUsageMode },
            set: { settings.totalUsageMode = $0 }
        )
    }
    
    private var modelAggregationModeBinding: Binding<ModelAggregationMode> {
        Binding(
            get: { settings.modelAggregationMode },
            set: { settings.modelAggregationMode = $0 }
        )
    }
    
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.usageDisplay.totalMode.title".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                SettingsChoiceControl("", options: TotalUsageMode.allCases, selection: totalUsageModeBinding) {
                    $0.localizationKey.localized()
                }
                
                Text("settings.usageDisplay.totalMode.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.usageDisplay.modelAggregation.title".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                SettingsChoiceControl("", options: ModelAggregationMode.allCases, selection: modelAggregationModeBinding) {
                    $0.localizationKey.localized()
                }
                
                Text("settings.usageDisplay.modelAggregation.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Label("settings.usageDisplay.title".localized(), systemImage: "chart.bar.doc.horizontal")
        } footer: {
            Text("settings.usageDisplay.description".localized())
                .font(.caption)
        }
    }
}
