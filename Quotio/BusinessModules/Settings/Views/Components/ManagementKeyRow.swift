//
//  ManagementKeyRow.swift
//  Quotio
//

// 管理密钥展示与操作行，仍从原 QuotaViewModel 的代理管理器读取密钥。
// 脱敏、复制反馈 Task、重新生成确认和失败提示全部保留在原类型，
// 文件拆分不复制密钥状态、不改变生成流程或偏好来源。

import SwiftUI
import AppKit

// MARK: - Management Key Row

struct ManagementKeyRow: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var settings = MenuBarSettingsManager.shared
    @State private var regenerateError: String?
    @State private var showRegenerateConfirmation = false
    @State private var showCopyConfirmation = false
    
    private var displayKey: String {
        if settings.hideSensitiveInfo {
            let key = viewModel.proxyManager.managementKey
            return String(repeating: "•", count: 8) + "..." + key.suffix(4)
        }
        return viewModel.proxyManager.managementKey
    }
    
    var body: some View {
        LabeledContent("settings.managementKey".localized()) {
            HStack(spacing: 8) {
                Text(displayKey)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(viewModel.proxyManager.managementKey, forType: .string)
                    showCopyConfirmation = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopyConfirmation = false
                    }
                } label: {
                    Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(showCopyConfirmation ? .green : .primary)
                        .modifier(SymbolEffectTransitionModifier())
                }
                .buttonStyle(.borderless)
                .help("action.copy".localized())
                
                Button {
                    showRegenerateConfirmation = true
                } label: {
                    if viewModel.proxyManager.isRegeneratingKey {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.proxyManager.isRegeneratingKey)
                .help("settings.managementKey.regenerate".localized())
            }
        }
        .confirmationDialog(
            "settings.managementKey.regenerate.title".localized(),
            isPresented: $showRegenerateConfirmation,
            titleVisibility: .visible
        ) {
            Button("settings.managementKey.regenerate.confirm".localized(), role: .destructive) {
                Task {
                    regenerateError = nil
                    do {
                        try await viewModel.proxyManager.regenerateManagementKey()
                    } catch {
                        regenerateError = error.localizedDescription
                    }
                }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("settings.managementKey.regenerate.warning".localized())
        }
        .alert("Error".localized(), isPresented: .init(
            get: { regenerateError != nil },
            set: { if !$0 { regenerateError = nil } }
        )) {
            Button("OK".localized()) { regenerateError = nil }
        } message: {
            Text(regenerateError ?? "")
        }
    }
}

