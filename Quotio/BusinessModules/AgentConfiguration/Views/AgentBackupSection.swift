import SwiftUI

/// 管理备份选择、恢复和删除的局部界面状态，实际文件操作统一交给 ViewModel。
/// 删除模式与恢复模式明确区分，确认时冻结目标列表，避免目录变化引起误删。
struct AgentBackupSection: View {
    @Bindable var viewModel: AgentSetupViewModel
    @State private var showRestoreConfirm = false
    @State private var backupToRestore: AgentConfigurationService.BackupFile?
    @State private var isSelectingBackups = false
    @State private var selectedBackupIDs: Set<String> = []
    @State private var backupsToDelete: [AgentConfigurationService.BackupFile] = []
    @State private var showDeleteBackupsConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.restoreBackup".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(String(format: "agents.availableBackups".localized(), viewModel.availableBackups.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isSelectingBackups {
                    Button("action.cancel".localized()) {
                        isSelectingBackups = false
                        selectedBackupIDs.removeAll()
                    }
                    Button(role: .destructive) {
                        // 确认框使用本次选择的快照，目录刷新不会改变即将删除的目标。
                        backupsToDelete = viewModel.availableBackups.filter { selectedBackupIDs.contains($0.id) }
                        showDeleteBackupsConfirm = true
                    } label: {
                        Label(String(format: "agents.backups.deleteSelected".localized(), selectedBackupIDs.count), systemImage: "trash")
                            .foregroundStyle(QuotioTheme.Colors.danger)
                    }
                    .disabled(selectedBackupIDs.isEmpty)
                    .opacity(selectedBackupIDs.isEmpty ? 0.5 : 1)
                } else {
                    Button {
                        isSelectingBackups = true
                    } label: {
                        Label("agents.backups.delete".localized(), systemImage: "trash")
                    }
                }
            }
            .buttonStyle(.quotioMicroCapsule)
            .controlSize(.small)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    // 展示全部备份，避免旧备份被 prefix(5) 隐藏后无法选择删除。
                    ForEach(viewModel.availableBackups) { backup in
                        BackupButton(backup: backup, isSelecting: isSelectingBackups, isSelected: selectedBackupIDs.contains(backup.id)) {
                            if isSelectingBackups {
                                if !selectedBackupIDs.insert(backup.id).inserted {
                                    selectedBackupIDs.remove(backup.id)
                                }
                            } else {
                                backupToRestore = backup
                                showRestoreConfirm = true
                            }
                        }
                    }
                }
            }

            Text((isSelectingBackups ? "agents.backups.selectToDelete" : "agents.restoreBackup.info").localized())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .quotioInsetCard()
        .disabled(viewModel.isDeletingBackups)
        .opacity(viewModel.isDeletingBackups ? 0.5 : 1)
        .onChange(of: viewModel.availableBackups.map(\.id)) {
            selectedBackupIDs.formIntersection(Set(viewModel.availableBackups.map(\.id)))
        }
        .confirmationDialog("agents.backups.deleteConfirm".localized(), isPresented: $showDeleteBackupsConfirm, titleVisibility: .visible) {
            Button("agents.backups.moveToTrash".localized(), role: .destructive) {
                let selected = backupsToDelete
                Task {
                    await viewModel.deleteBackups(selected)
                    selectedBackupIDs.removeAll()
                    backupsToDelete = []
                    isSelectingBackups = false
                }
            }
            Button("action.cancel".localized(), role: .cancel) { backupsToDelete = [] }
        } message: {
            Text(String(format: "agents.backups.deleteConfirmMessage".localized(), backupsToDelete.count))
        }
        .alert("agents.restoreBackup.confirm.title".localized(), isPresented: $showRestoreConfirm) {
            Button("action.cancel".localized(), role: .cancel) {
                backupToRestore = nil
            }
            if let backup = backupToRestore {
                Button("agents.restoreAction".localized(), role: .destructive) {
                    Task { await viewModel.restoreFromBackup(backup) }
                }
            }
        } message: {
            Text("agents.restoreBackup.confirm.message".localized())
        }
    }

}

private struct BackupButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let backup: AgentConfigurationService.BackupFile
    var isSelecting = false
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isSelecting ? (isSelected ? "checkmark.circle.fill" : "circle") : "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(backup.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor : QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // 同一分钟可能有多个配置/认证备份，悬浮提示用文件名和秒级时间帮助区分。
        .help(URL(fileURLWithPath: backup.path).lastPathComponent + "\n" + backup.timestamp.formatted(date: .abbreviated, time: .standard))
    }
}
