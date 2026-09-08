import XCTest
@testable import Quotio

final class AgentBackupDeletionTests: XCTestCase {
    private var homeDirectory: URL!
    private var trashDirectory: URL!
    private var service: AgentConfigurationService!

    override func setUpWithError() throws {
        homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBackupTests-\(UUID().uuidString)")
        trashDirectory = homeDirectory.appendingPathComponent("test-trash")
        try FileManager.default.createDirectory(at: homeDirectory.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let trash = trashDirectory!
        // 用临时目录模拟可恢复删除，避免测试污染真实废纸篓。
        service = AgentConfigurationService(homeDirectory: homeDirectory, trashBackup: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: homeDirectory)
    }

    private func backup(_ timestamp: Int) throws -> AgentConfigurationService.BackupFile {
        let url = homeDirectory.appendingPathComponent(".claude/settings.json.backup.\(timestamp)")
        try Data("backup-\(timestamp)".utf8).write(to: url)
        return .init(path: url.path, timestamp: Date(timeIntervalSince1970: Double(timestamp)), agent: .claudeCode)
    }

    func testDeletionMovesOnlyChosenBackupAndPreservesCurrentSettings() async throws {
        let selected = try backup(100)
        let retained = try backup(200)
        let settings = homeDirectory.appendingPathComponent(".claude/settings.json")
        try Data("current-settings".utf8).write(to: settings)
        try await service.deleteBackup(selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "current-settings")
        XCTAssertEqual(try String(contentsOf: trashDirectory.appendingPathComponent("settings.json.backup.100"), encoding: .utf8), "backup-100")
        let remaining = await service.listBackups(agent: .claudeCode)
        XCTAssertEqual(remaining.map(\.id), [retained.id])
    }

    func testDeletionRejectsArbitraryFilesAndSymbolicLinks() async throws {
        let protected = homeDirectory.appendingPathComponent("protected.txt")
        try Data("keep".utf8).write(to: protected)
        let linked = homeDirectory.appendingPathComponent(".claude/settings.json.backup.100")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: protected)
        for path in [protected.path, linked.path] {
            do {
                try await service.deleteBackup(.init(path: path, timestamp: Date(timeIntervalSince1970: 100), agent: .claudeCode))
                XCTFail("伪造路径或符号链接应被拒绝")
            } catch {
                XCTAssertTrue(error is AgentConfigurationService.BackupDeletionError)
            }
        }
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
    }

    func testTrashFailureKeepsBackupAndPropagatesError() async throws {
        let selected = try backup(100)
        let failingService = AgentConfigurationService(homeDirectory: homeDirectory, trashBackup: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        do {
            try await failingService.deleteBackup(selected)
            XCTFail("删除失败不能被吞掉")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
    }

    @MainActor
    func testDeletingBackupRefreshesListWithoutDiscardingUnsavedModelEdits() async throws {
        let selected = try backup(100)
        let retained = try backup(200)
        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.selectedAgent = .claudeCode
        viewModel.currentConfiguration = AgentConfiguration(agent: .claudeCode, proxyURL: "", apiKey: "test-key")
        viewModel.updateDefaultModel("sonnet")
        viewModel.updateModelSlot(.opus, model: "unsaved-model")
        viewModel.updateModelDisplayName(.opus, name: "未保存的名称")
        viewModel.availableBackups = [selected, retained]
        await viewModel.deleteBackups([selected])
        XCTAssertEqual(viewModel.availableBackups.map(\.id), [retained.id])
        XCTAssertEqual(viewModel.currentConfiguration?.claudeModel, "sonnet")
        XCTAssertEqual(viewModel.currentConfiguration?.modelSlots[.opus], "unsaved-model")
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDisplayName(for: .opus), "未保存的名称")
        XCTAssertFalse(viewModel.isDeletingBackups)
        XCTAssertNil(viewModel.errorMessage)
    }
    func testDeletionRejectsSymlinkedConfigurationDirectory() async throws {
        let selected = try backup(100)
        let configDirectory = homeDirectory.appendingPathComponent(".claude")
        let externalDirectory = homeDirectory.appendingPathComponent("external")
        try FileManager.default.moveItem(at: configDirectory, to: externalDirectory)
        try FileManager.default.createSymbolicLink(at: configDirectory, withDestinationURL: externalDirectory)
        do {
            try await service.deleteBackup(selected)
            XCTFail("不应沿配置目录的符号链接删除文件")
        } catch {
            XCTAssertTrue(error is AgentConfigurationService.BackupDeletionError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent("settings.json.backup.100").path))
    }

    @MainActor
    func testPartialBatchFailureRefreshesRemainingBackupsAndReportsError() async throws {
        let first = try backup(100)
        let second = try backup(200)
        let trash = trashDirectory!
        let failingService = AgentConfigurationService(homeDirectory: homeDirectory, trashBackup: { url in
            if url.lastPathComponent.hasSuffix(".200") { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        let viewModel = AgentSetupViewModel(configurationService: failingService)
        viewModel.selectedAgent = .claudeCode
        viewModel.availableBackups = [first, second]
        await viewModel.deleteBackups([first, second])
        XCTAssertEqual(viewModel.availableBackups.map(\.id), [second.id])
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isDeletingBackups)
    }

}
