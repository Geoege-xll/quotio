import SwiftUI

/// 仅编辑 CPA 文件账号的非秘密调度元数据（权重与优先级）。使用打开弹窗时冻结的管理客户端，
/// 服务切换或账号列表刷新不会让一次保存意外落到另一个 CPA 实例。
struct CPAAccountWeightSheet: View {
    @Environment(\.dismiss) private var dismiss
    let displayName: String
    let authFileName: String
    let client: ManagementAPIClient
    var onSaved: () -> Void = {}

    @State private var weightText = "1"
    @State private var priorityText = "0"
    @State private var savedWeight = 1
    @State private var savedPriority = 0
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.cpa.accountRouting".localized()).font(.title3.bold())
            Text(displayName).foregroundStyle(.secondary).lineLimit(2)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if hasLoaded {
                VStack(spacing: 12) {
                    CPASettingsNumberRow(titleKey: "settings.cpa.accountPriority", text: $priorityText,
                        helpKey: "settings.cpa.priorityHelp")
                        .disabled(isSaving)
                    CPASettingsNumberRow(titleKey: "settings.cpa.accountWeight", text: $weightText,
                        helpKey: "settings.cpa.weightHelp")
                        .disabled(isSaving)
                }
            } else {
                Button("action.retry".localized()) { Task { await load() } }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("action.cancel".localized()) { dismiss() }.disabled(isSaving)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("action.save".localized()) { Task { await save() } }
                    .buttonStyle(.quotioPrimaryCapsule)
                    .disabled(!hasLoaded || isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24).frame(width: 420)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            let routing = try await client.fetchAuthFileRouting(name: authFileName)
            guard !Task.isCancelled else { return }
            savedWeight = routing.weight; weightText = String(routing.weight)
            savedPriority = routing.priority; priorityText = String(routing.priority)
            hasLoaded = true
        } catch {
            // 失败结束加载并提供重试；真实值未取得前保持保存禁用，不能提交伪造的默认值。
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard hasLoaded, !isLoading, !isSaving else { return }
        do {
            let weight = try CPAAccountWeight.parse(weightText)
            let priority = try CPAAccountPriority.parse(priorityText)
            guard weight != savedWeight || priority != savedPriority else { dismiss(); return }
            isSaving = true
            defer { isSaving = false }
            try await client.setAuthFileRouting(name: authFileName, weight: weight, priority: priority)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
