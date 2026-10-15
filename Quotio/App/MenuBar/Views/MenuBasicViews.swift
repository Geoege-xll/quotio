//
//  MenuBasicViews.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏的标题、空状态和底部操作视图。
/// 完整保留原布局、按钮回调和可用状态；仅被 builder 调用的顶层视图改为模块内可见，按钮辅助类型仍私有。
// MARK: - SwiftUI Menu Components

// MARK: Header View

struct MenuHeaderView: View {
    let isLoading: Bool
    
    var body: some View {
        HStack {
            Text("Quotio")
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
            
            if isLoading {
                // 复用项目已有的原生小进度组件，避免缩放 ProgressView 产生浮点尺寸约束警告。
                SmallProgressView(size: 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: Empty State View

struct MenuEmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("menubar.noData".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
    }
}

// MARK: - Menu Actions View

struct MenuActionsView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    var body: some View {
        VStack(spacing: 0) {
            MenuBarActionButton(
                icon: "arrow.clockwise",
                title: "action.refresh".localized(),
                // 只显示这一轮用户操作；后台额度刷新仍可提交手动等待请求。
                // 状态由 ViewModel 持有，菜单重建也不会允许第二份并发用户刷新。
                isLoading: viewModel.manualAccountRefreshState.isRefreshing
            ) {
                Task { await viewModel.manualRefresh() }
            }
            .disabled(viewModel.manualAccountRefreshState.isRefreshing)
            
            MenuBarActionButton(
                icon: "macwindow",
                title: "action.openApp".localized()
            ) {
                MenuActionHandler.openMainWindow()
            }
            
            Divider()
                .padding(.vertical, 4)
            
            MenuBarActionButton(
                icon: "xmark.circle",
                title: "action.quit".localized()
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Menu Bar Action Button

private struct MenuBarActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                
                Text(title)
                    .font(.system(size: 13))
                
                Spacer()
                
                if isLoading {
                    SmallProgressView(size: 12)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovered = $0 }
    }
}
