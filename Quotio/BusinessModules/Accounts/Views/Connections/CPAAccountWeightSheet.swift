import SwiftUI

/// 仅编辑 CPA 文件账号的非秘密权重元数据。使用打开弹窗时冻结的管理客户端，
/// 服务切换或账号列表刷新不会让一次保存意外落到另一个 CPA 实例。
struct CPAAccountWeightSheet: View {
    @Environment(\.dismiss) private var dismiss
    let displayName: String
    let authFileName: String
    let client: ManagementAPIClient
    var onSaved: () -> Void = {}

    @State private var weightText = "1"
    @State private var savedWeight = 1
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.cpa.accountWeight".localized()).font(.title3.bold())
            Text(displayName).foregroundStyle(.secondary).lineLimit(2)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if hasLoaded {
                CPASettingsNumberRow(titleKey: "settings.cpa.accountWeight", text: $weightText,
                    helpKey: "settings.cpa.weightHelp")
                    .disabled(isSaving)
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
            let weight = try await client.fetchAuthFileWeight(name: authFileName)
            guard !Task.isCancelled else { return }
            savedWeight = weight; weightText = String(weight); hasLoaded = true
        } catch {
            // 失败结束加载并提供重试；真实值未取得前保持保存禁用，不能提交伪造的默认 1。
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard hasLoaded, !isLoading, !isSaving else { return }
        do {
            let weight = try CPAAccountWeight.parse(weightText)
            guard weight != savedWeight else { dismiss(); return }
            isSaving = true
            defer { isSaving = false }
            try await client.setAuthFileWeight(name: authFileName, weight: weight)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
