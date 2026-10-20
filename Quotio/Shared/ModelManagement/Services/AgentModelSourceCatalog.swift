import Foundation

/// 将 CPA 当前启用凭据的模型注册信息投影到实时目录，既不补型号，也不改变路由。
/// 只有原配置 VM 确认同一 CPA 后才调用；管理认证仍由注入的 v8 客户端负责，
/// 不向用户配置的外部服务发送管理密钥，也不新增状态、缓存或后台任务。
nonisolated enum AgentModelSourceCatalog {
    struct Registration: Sendable {
        let credentialID: String
        let platform: String
        let account: String?
        let models: [AuthFileModelInfo]
    }

    @concurrent
    static func enrich(_ selection: AgentModelCatalogService.Selection, client: ManagementAPIClient) async throws
        -> AgentModelCatalogService.Selection {
        let allFiles = try await client.fetchAuthFiles()
        let files = allFiles.filter { !$0.disabled && !$0.unavailable }
        var registrations: [Registration] = []
        var complete = true
        // 复用调用者的结构化任务；每批至多四个读取，不为每次刷新建立后台消费者或无限并发。
        for start in stride(from: 0, to: files.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(files[start..<min(start + 4, files.count)])
            let results = try await withThrowingTaskGroup(of: Registration?.self) { group in
                for file in batch {
                    // v8 的 name 参数同时接受 ID 和文件名。不同账号可能同名，因此优先传原始 ID；
                    // 缺 ID 的兼容回退或 ID 与其他文件名碰撞时不能证明精确来源，整轮不冒充完整快照。
                    // 此处只使用 API 原始列表，不把目录去重生成的本地合成 ID 发送给后端。
                    let matches = allFiles.filter { $0.id == file.id || $0.name == file.id }
                    guard !file.id.isEmpty, matches.count == 1 else { complete = false; continue }
                    group.addTask {
                        do {
                            let models = try await client.fetchAuthFileModels(name: file.id)
                            return Registration(credentialID: file.id, platform: file.provider,
                                account: [file.email, file.label, file.account].compactMap { $0 }
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty },
                                models: models)
                        } catch is CancellationError { throw CancellationError() }
                        catch { return nil }
                    }
                }
                var output: [Registration?] = []
                for try await result in group { output.append(result) }
                return output
            }
            complete = complete && results.allSatisfy { $0 != nil }
            registrations += results.compactMap { $0 }
        }
        return projecting(selection, registrations: registrations, complete: complete)
    }

    /// 精确匹配注册 ID，不按 owned_by、模型名称或账号邮箱推断支持关系。
    /// 查询部分失败时保持目录原有归属，不能凭不完整的账号集合声称已确认固定账号或账号池。
    static func projecting(_ selection: AgentModelCatalogService.Selection, registrations: [Registration], complete: Bool)
        -> AgentModelCatalogService.Selection {
        func project(_ model: AvailableModel) -> AvailableModel {
            var result = model
            let matches = registrations.filter { $0.models.contains { $0.id == model.id } }
            guard !matches.isEmpty, complete else { return result }
            let platforms = Array(Set(matches.map(\.platform).filter { !$0.isEmpty })).sorted()
            let identities = Set(matches.map(\.credentialID))
            let accounts = Set(matches.compactMap(\.account))
            let single = identities.count == 1 && accounts.count == 1 && platforms.count == 1
            result.displaySource = .init(platforms: platforms, account: single ? accounts.first : nil,
                                         isAccountPool: identities.count > 1)
            // 相同 ID 的来源名称不一致时保持目录已有名称，不任意挑一个账号的标题。
            let names = Set(matches.flatMap(\.models).filter { $0.id == model.id }.compactMap(\.displayName)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if names.count == 1, let name = names.first { result = replacingName(result, with: name) }
            return result
        }
        return .init(catalog: selection.catalog.map(project), candidates: selection.candidates.map(project))
    }

    private static func replacingName(_ model: AvailableModel, with name: String) -> AvailableModel {
        .init(id: model.id, name: name, provider: model.provider, isDefault: model.isDefault,
              displayPlatform: model.displayPlatform, displaySource: model.displaySource, contextWindow: model.contextWindow)
    }
}
