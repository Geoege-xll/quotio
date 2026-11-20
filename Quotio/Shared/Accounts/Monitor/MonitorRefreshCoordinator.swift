import Foundation

/// 本地代理只在用户明确删除 IDE 导入记录时，清理旧监控账号的磁盘镜像；
/// 仍复用同步世代，避免删除前开始的旧刷新回写同一个账号。
actor MonitorRefreshCoordinator {
    nonisolated let revision = MonitorStateRevision()
    private let metadata: MonitorMetadataStore
    private let snapshots: MonitorSnapshotStore

    init(metadata: MonitorMetadataStore = .shared, snapshots: MonitorSnapshotStore = MonitorSnapshotStore()) {
        self.metadata = metadata
        self.snapshots = snapshots
    }

    /// 只删除对应的 Cursor／Trae 快照与旧禁用标记，其他账号及钥匙串凭据不参与这次操作。
    func forgetSnapshotAccount(provider: AIProvider, accountKey: String, revision expected: UInt64? = nil,
                               mutationAccountID: String? = nil) async {
        let accountID = MonitorAccount.make(provider: provider, accountKey: accountKey, source: .localIDE).id
        let mutationID = mutationAccountID ?? accountID
        let generation = expected ?? revision.advance(accountID: mutationID)
        await snapshots.removeAccount(provider: provider, accountKey: accountKey, revision: generation,
            state: revision, mutationAccountID: mutationID)
        guard await metadata.disabledAccountIDs().contains(accountID),
              revision.isCurrent(generation, accountID: mutationID) else { return }
        try? await metadata.setDisabled(false, accountIDs: [accountID], revision: generation, state: revision,
            mutationAccountID: mutationID)
    }
}
