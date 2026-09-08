import SwiftUI
import AppKit

/// Sheet 只用临时标识区分编辑任务，不把密钥放入导航路径或持久化恢复状态。
private struct APIKeyEditorRequest: Identifiable {
    let id = UUID()
    let original: String?
}

/// API 密钥属于业务管理页面，复用项目卡片与操作控件，而不是设置页的 Form/List。
/// 新增和编辑通过系统 Sheet 承载，服务端写入仍走现有的成功确认及防重入逻辑。
struct APIKeysScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var editor: APIKeyEditorRequest?
    @State private var pendingDeletion: String?
    @State private var showsDeletion = false
    @State private var operationError: String?
    @State private var copyFeedback: String?

    private var keys: [String] {
        var seen = Set<String>()
        return viewModel.apiKeys.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !viewModel.proxyManager.proxyStatus.running {
                    ProxyRequiredView(description: "apiKeys.proxyRequired".localized()) {
                        await viewModel.startProxy()
                    }
                    .frame(minHeight: 240)
                } else {
                    pageHeader
                    if let operationError {
                        Label(operationError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    keyCard
                    if let copyFeedback {
                        Text(copyFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }

                // 公开分享属于 API 访问管理，放在密钥内容之后；服务未启动时仍可进入设置。
                // 卡片与页面共同滚动，避免固定底栏挤占密钥列表的可用空间。
                PublicSharingCard()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .quotioPage()
        .navigationTitle("nav.apiKeys".localized())
        .sheet(item: $editor) { request in
            APIKeyEditorSheet(original: request.original)
        }
        .task(id: viewModel.proxyManager.proxyStatus.running) {
            if viewModel.proxyManager.proxyStatus.running { await viewModel.fetchAPIKeys() }
        }
        .confirmationDialog("apiKeys.manager.deleteTitle".localized(), isPresented: $showsDeletion) {
            Button("action.delete".localized(), role: .destructive) { deletePendingKey() }
            Button("action.cancel".localized(), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("apiKeys.manager.deleteHelp".localized())
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("nav.apiKeys".localized()).font(.title2.weight(.semibold))
                    Spacer(minLength: 20)
                    addButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("nav.apiKeys".localized()).font(.title2.weight(.semibold))
                    addButton
                }
            }
            Text("apiKeys.manager.purpose".localized())
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addButton: some View {
        Button {
            operationError = nil
            editor = APIKeyEditorRequest(original: nil)
        } label: {
            Label("apiKeys.add".localized(), systemImage: "plus")
        }
        .buttonStyle(.quotioPrimaryCapsule)
        .fixedSize()
        .disabled(viewModel.isMutatingAPIKeys)
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Label("apiKeys.list".localized(), systemImage: "key.horizontal")
                    .font(.headline)
                Spacer()
                if viewModel.isMutatingAPIKeys { ProgressView().controlSize(.small) }
                Text(keys.count, format: .number)
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
            }
            if keys.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("apiKeys.empty".localized()).font(.headline)
                    Text("apiKeys.emptyDescription".localized())
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(keys, id: \.self) { key in
                        APIKeyCardRow(key: key, onCopy: { copy(key) }, onEdit: {
                            operationError = nil
                            editor = APIKeyEditorRequest(original: key)
                        }, onDelete: {
                            pendingDeletion = key
                            showsDeletion = true
                        })
                        .disabled(viewModel.isMutatingAPIKeys)
                    }
                }
            }
        }
        .quotioCard()
    }

    private func deletePendingKey() {
        guard let key = pendingDeletion else { return }
        pendingDeletion = nil
        operationError = nil
        Task {
            if !(await viewModel.deleteAPIKey(key)) {
                operationError = viewModel.errorMessage ?? "apiKeys.manager.failed".localized()
            }
        }
    }

    private func copy(_ key: String) {
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.setString(key, forType: .string)
        copyFeedback = (success ? "availableModels.copied" : "runtime.copyFailed").localized()
    }
}

/// 操作区保持自然固定宽度，密钥占用剩余空间；窄窗口切换两行，不挤压操作按钮。
private struct APIKeyCardRow: View {
    let key: String
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity.frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                HStack { Spacer(); actions }
            }
        }
        .quotioInsetCard(padding: 12)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal").foregroundStyle(.secondary)
                .frame(width: 24)
            Text(maskedKey)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("apiKeys.sheet.masked".localized())
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onCopy) {
                Label("action.copy".localized(), systemImage: "doc.on.doc")
            }
            .buttonStyle(.quotioMicroCapsule)
            Button(action: onEdit) {
                Label("apiKeys.edit".localized(), systemImage: "pencil")
            }
            .buttonStyle(.quotioMicroCapsule)
            QuotioCircularIconButton(systemImage: "trash", tint: .red, backgroundTint: .red) {
                onDelete()
            }
            .help("action.delete".localized())
            .accessibilityLabel("action.delete".localized())
        }
        .fixedSize()
    }

    private var maskedKey: String {
        // 短密钥完全隐藏，长密钥保留不重叠的识别前后缀；悬停也不泄露完整值。
        guard key.count > 14 else { return String(repeating: "•", count: 8) }
        return String(key.prefix(6)) + "••••••••" + String(key.suffix(4))
    }
}

/// 新增和编辑共用一个有独立生命周期的草稿弹窗，避免后台刷新覆盖用户输入。
/// Sheet 使用系统呈现，内容复用已有客户端配置弹窗的标题、嵌入卡片和胶囊按钮。
private struct APIKeyEditorSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private let original: String?
    @State private var value: String
    @State private var showsSecret = false
    @State private var isSaving = false
    @State private var showsDiscard = false
    @State private var operationError: String?

    init(original: String?) {
        self.original = original
        _value = State(initialValue: original ?? "")
    }

    private var isEditing: Bool { original != nil }
    private var isDirty: Bool { value != (original ?? "") }
    private var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Bool {
        !trimmedValue.isEmpty && trimmedValue != original && viewModel.apiKeys.contains(trimmedValue)
    }
    private var isBusy: Bool { isSaving || viewModel.isMutatingAPIKeys }
    private var canSave: Bool {
        !trimmedValue.isEmpty && trimmedValue != original && !duplicate && !isBusy
            && viewModel.proxyManager.proxyStatus.running
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputCard
                    if isEditing {
                        Label("apiKeys.manager.editHelp".localized(), systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !viewModel.proxyManager.proxyStatus.running {
                        errorLabel("apiKeys.manager.disconnected".localized())
                    } else if let operationError {
                        errorLabel(operationError)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            footer
        }
        .frame(width: 520, height: 420)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        // 有草稿或正在写入时阻止系统绕过确认直接关闭；显式关闭入口统一走 requestDismiss。
        .interactiveDismissDisabled(isDirty || isBusy)
        .onExitCommand { requestDismiss() }
        .confirmationDialog("apiKeys.manager.discardTitle".localized(), isPresented: $showsDiscard) {
            Button("apiKeys.manager.discard".localized(), role: .destructive) { dismiss() }
            Button("action.cancel".localized(), role: .cancel) { }
        } message: {
            Text("apiKeys.manager.discardHelp".localized())
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isEditing ? "key.horizontal" : "key.horizontal.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md))
            VStack(alignment: .leading, spacing: 5) {
                Text((isEditing ? "apiKeys.edit" : "apiKeys.add").localized()).font(.headline)
                Text("apiKeys.manager.purpose".localized())
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            QuotioCircularIconButton(systemImage: "xmark") { requestDismiss() }
                .accessibilityLabel("action.cancel".localized())
                .disabled(isBusy)
        }
        .padding(20)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("apiKeys.sheet.value".localized()).font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                Group {
                    if showsSecret {
                        QuotioCapsuleTextField("apiKeys.placeholder".localized(), text: $value,
                            systemImage: "key", monospaced: true, autofocus: true)
                    } else {
                        QuotioCapsuleSecureField("apiKeys.placeholder".localized(), text: $value,
                            systemImage: "key", autofocus: true)
                    }
                }
                .onSubmit { save() }
                QuotioCircularIconButton(systemImage: showsSecret ? "eye.slash" : "eye") {
                    showsSecret.toggle()
                }
                .accessibilityLabel((showsSecret ? "apiKeys.sheet.hide" : "apiKeys.sheet.show").localized())
                .help((showsSecret ? "apiKeys.sheet.hide" : "apiKeys.sheet.show").localized())
            }
            if duplicate { errorLabel("apiKeys.manager.invalid".localized()) }
            Button {
                // 生成只替换当前草稿，不调用 CPA；保持安全显示状态，由用户主动展开查看。
                let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                value = "sk-" + String((0..<32).map { _ in characters.randomElement()! })
                operationError = nil
            } label: {
                Label("apiKeys.generate".localized(), systemImage: "wand.and.stars")
            }
            .buttonStyle(.quotioMicroCapsule)
            Text("apiKeys.sheet.generateHelp".localized())
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .quotioInsetCard()
        .disabled(isBusy)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("action.cancel".localized()) { requestDismiss() }
                .buttonStyle(.quotioSecondaryCapsule)
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button((isEditing ? "action.save" : "apiKeys.add").localized()) { save() }
                .buttonStyle(.quotioPrimaryCapsule)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
        }
        .padding(20)
    }

    private func requestDismiss() {
        guard !isBusy else { return }
        if isDirty { showsDiscard = true }
        else { dismiss() }
    }

    private func save() {
        guard canSave else { return }
        // 在启动异步任务前锁住本地操作，补足连续 Return 或双击的任务调度间隙。
        isSaving = true
        operationError = nil
        let submittedValue = trimmedValue
        Task {
            let success: Bool
            if let original {
                success = await viewModel.updateAPIKey(old: original, new: submittedValue)
            } else {
                success = await viewModel.addAPIKey(submittedValue)
            }
            isSaving = false
            if success { dismiss() }
            else { operationError = viewModel.errorMessage ?? "apiKeys.manager.failed".localized() }
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
