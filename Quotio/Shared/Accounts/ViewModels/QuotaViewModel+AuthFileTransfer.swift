//
//  QuotaViewModel+AuthFileTransfer.swift
//  Quotio
//

import Foundation

/// 手动凭据传输在第一次挂起前固定当前 CPA 客户端和会话。即使文件对话框打开期间代理停止，
/// 导入和导出也只会结束本批，不能从用户未选择的本机认证目录读取或写入凭据。
extension QuotaViewModel {
    private struct AuthImportContext {
        let client: ManagementAPIClient
        let modeRevision: UInt64
        let runtimeSessionID: UUID
    }

    private func authImportContext() -> AuthImportContext? {
        guard !Task.isCancelled, canRefreshAccountQuotas, let apiClient else { return nil }
        return AuthImportContext(client: apiClient, modeRevision: modeManager.revision,
                                 runtimeSessionID: proxyManager.runtimeSessionID)
    }

    private func canContinueAuthImport(_ context: AuthImportContext) -> Bool {
        !Task.isCancelled && canRefreshAccountQuotas && modeManager.revision == context.modeRevision
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
        try await context.client.uploadAuthFile(name: name, content: content)
        guard canContinueAuthImport(context) else { throw CancellationError() }
    }

    private func refreshAuthImport(_ context: AuthImportContext) async {
        guard canContinueAuthImport(context) else { return }
        #if DEBUG
        if let hook = authImportRefreshHookForTesting { await hook(true); return }
        #endif
        // 新增同型号的第二个账号也会改变菜单来源。复用现有会话，批量成功后只刷新一次。
        await refreshAfterCPAAccountChange()
    }

    func uploadAuthFile(name: String, content: Data) async throws {
        guard let context = authImportContext() else { throw CancellationError() }
        try await writeAuthImport(name: name, content: content, context: context)
        await refreshAuthImport(context)
    }

    func importAuthFile(from url: URL) async throws {
        guard let context = authImportContext() else { throw CancellationError() }
        let content = try await readAuthImport(url)
        try await writeAuthImport(name: url.lastPathComponent, content: content, context: context)
        await refreshAuthImport(context)
    }

    /// 批量保留逐文件容错与一次刷新；来源失效时停止剩余文件，已经完成的写入不回滚。
    /// 不把旧批次的失败提示或刷新结果提交到新的模式／代理会话，用户可以在新会话重新导入。
    func importAuthFiles(from urls: [URL]) async {
        guard !urls.isEmpty, let context = authImportContext() else { return }
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
        guard let context = authImportContext() else { throw CancellationError() }
        return try await downloadAuthFile(name: name, context: context)
    }

    private func downloadAuthFile(name: String, context: AuthImportContext) async throws -> Data {
        let content = try await context.client.downloadAuthFile(name: name)
        guard canContinueAuthImport(context) else { throw CancellationError() }
        return content
    }

    func exportAuthFile(name: String, to url: URL) async throws {
        guard let context = authImportContext() else { throw CancellationError() }
        let content = try await downloadAuthFile(name: name, context: context)
        guard canContinueAuthImport(context) else { throw CancellationError() }
        // 用户选择的保存位置仍由原服务写入，与 CPA 的认证目录相互独立。
        try await directAuthService.writeDownloadedAuthFile(content, to: url)
    }

    func importVertexServiceAccount(url: URL) async {
        guard canRefreshAccountQuotas, let client = apiClient else {
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
