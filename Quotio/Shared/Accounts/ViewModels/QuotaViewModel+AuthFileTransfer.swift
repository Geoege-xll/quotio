//
//  QuotaViewModel+AuthFileTransfer.swift
//  Quotio
//

import Foundation

/// 凭据上传、导入、下载与导出的原有入口，按原路径使用 CPA 客户端或主类注入的 DirectAuthFileService。
/// AuthImportContext 及来源校验与传输方法放在同一文件，保持嵌套名称与 private 边界。
/// JSON 上传和导入仍在第一次挂起前固定 client、模式世代与代理会话；途中失效时结束剩余传输。
/// 保留逐文件容错、成功后一次刷新及原错误发布时序，不重新选择目标、不重建授权服务。
/// 测试钩子和管理客户端指针仍存储在主类；这里仅调用原钩子，不增加状态或任务。
extension QuotaViewModel {
    /// 单次或批量传输都在第一次 await 前固定来源。client=nil 明确表示本地目录，
    /// 不能在中途重新读取 apiClient 并把同一批敏感凭据分流到另一位置。
    private struct AuthImportContext {
        let client: ManagementAPIClient?
        let modeRevision: UInt64
        let runtimeSessionID: UUID
    }

    private func authImportContext() -> AuthImportContext {
        AuthImportContext(client: apiClient, modeRevision: modeManager.revision,
            runtimeSessionID: proxyManager.runtimeSessionID)
    }

    private func canContinueAuthImport(_ context: AuthImportContext) -> Bool {
        !Task.isCancelled && modeManager.revision == context.modeRevision
            && proxyManager.runtimeSessionID == context.runtimeSessionID && apiClient === context.client
    }

    private func readAuthImport(_ url: URL) async throws -> Data {
        #if DEBUG
        if let hook = authImportReadHookForTesting { return try await hook(url) }
        #endif
        return try await directAuthService.readAuthFileForImport(from: url)
    }

    private func writeAuthImport(name: String, content: Data, context: AuthImportContext) async throws {
        guard canContinueAuthImport(context) else { throw CancellationError() }
        if let client = context.client {
            try await client.uploadAuthFile(name: name, content: content)
        } else {
            try await directAuthService.uploadAuthFile(name: name, content: content)
        }
        guard canContinueAuthImport(context) else { throw CancellationError() }
    }

    private func refreshAuthImport(_ context: AuthImportContext) async {
        guard canContinueAuthImport(context) else { return }
        #if DEBUG
        if let hook = authImportRefreshHookForTesting { await hook(context.client != nil); return }
        #endif
        if context.client != nil {
            // 新增同型号的第二个账号也会改变菜单来源；沿用原会话和成功后一次刷新的事务边界。
            await refreshAfterCPAAccountChange()
        }
        else { await loadDirectAuthFiles() }
    }

    func uploadAuthFile(name: String, content: Data) async throws {
        let context = authImportContext()
        try await writeAuthImport(name: name, content: content, context: context)
        await refreshAuthImport(context)
    }

    func importAuthFile(from url: URL) async throws {
        let context = authImportContext()
        let content = try await readAuthImport(url)
        try await writeAuthImport(name: url.lastPathComponent, content: content, context: context)
        await refreshAuthImport(context)
    }

    /// 批量保留逐文件容错与一次刷新；来源失效时停止剩余文件，已经完成的写入不回滚。
    /// 不把旧批次的失败提示或刷新结果提交到新的模式／代理会话，用户可以在新会话重新导入。
    func importAuthFiles(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let context = authImportContext()
        var errors: [String] = []
        var successCount = 0
        for url in urls {
            guard canContinueAuthImport(context) else { return }
            do {
                let content = try await readAuthImport(url)
                try await writeAuthImport(name: url.lastPathComponent, content: content, context: context)
                successCount += 1
            } catch {
                guard canContinueAuthImport(context), !(error is CancellationError) else { return }
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if successCount > 0 { await refreshAuthImport(context) }
        guard canContinueAuthImport(context) else { return }
        if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
    }

    func downloadAuthFile(name: String) async throws -> Data {
        if let client = apiClient {
            return try await client.downloadAuthFile(name: name)
        } else {
            return try await directAuthService.downloadAuthFile(name: name)
        }
    }

    func exportAuthFile(name: String, to url: URL) async throws {
        let content = try await downloadAuthFile(name: name)
        try await directAuthService.writeDownloadedAuthFile(content, to: url)
    }

    func importVertexServiceAccount(url: URL) async {
        guard let client = apiClient else {
            errorMessage = "Proxy not running"
            return
        }
        let source = refreshContext()
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(domain: "Quotio", code: 403, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
            }
            let data = try Data(contentsOf: url)
            url.stopAccessingSecurityScopedResource()
            
            try await client.uploadVertexServiceAccount(data: data)
            guard canUseRefreshSource(source), apiClient === client else { return }
            await refreshAfterCPAAccountChange()
            guard canUseRefreshSource(source), apiClient === client else { return }
            errorMessage = nil
        } catch {
            guard canUseRefreshSource(source), apiClient === client else { return }
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
