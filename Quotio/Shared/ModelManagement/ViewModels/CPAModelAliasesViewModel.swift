import Foundation
import Observation

/// 两个界面入口共用此状态与服务，不将别名策略保存到 UserDefaults 或 agent 私有配置中。
@MainActor @Observable
final class CPAModelAliasesViewModel {
    var sources: [CPAModelAliasSource] = []
    var aliases: [CPAModelAlias] = []
    var unavailableChannels: [String] = []
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    private var revision = ""
    private var service: CPAModelAliasService?
    private var generation = UUID()

    func load(client: ManagementAPIClient?) async {
        guard !isSaving else { return }
        let request = UUID()
        generation = request
        guard let client else {
            service = nil
            sources = []; aliases = []; revision = ""
            errorMessage = "cpaAliases.startProxy".localized()
            isLoading = false
            return
        }
        let service = CPAModelAliasService(client: client)
        self.service = service
        isLoading = true
        errorMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let snapshot = try await service.load()
            guard generation == request, !Task.isCancelled else { return }
            apply(snapshot)
        } catch is CancellationError { }
        catch {
            guard generation == request else { return }
            sources = []; aliases = []; revision = ""
            errorMessage = error.localizedDescription
        }
    }

    func create(sourceID: String, alias: String, effort: String) async -> Bool {
        guard !isLoading, !isSaving, let service,
              let source = sources.first(where: { $0.id == sourceID }) else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await service.create(source: source, alias: alias, effort: effort, expectedRevision: revision)
            apply(try await service.load())
            return true
        } catch {
            // 部分保存或目录刷新失败后清除旧版本号，必须重新加载，不能继续对旧快照写入。
            revision = ""
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ entry: CPAModelAlias) async {
        guard !isLoading, !isSaving, let service else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await service.delete(entry, expectedRevision: revision)
            apply(try await service.load())
        } catch {
            revision = ""
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ snapshot: CPAModelAliasSnapshot) {
        revision = snapshot.revision
        sources = snapshot.sources
        aliases = snapshot.aliases
        unavailableChannels = snapshot.unavailableChannels
    }
}
