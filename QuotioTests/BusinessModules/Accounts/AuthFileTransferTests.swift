import Foundation
import XCTest
@testable import QuotioPlus

@MainActor
final class AuthFileTransferTests: XCTestCase {
    func testDirectUploadRejectsUnsafeFileNames() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DirectAuthFileService(authDirectory: directory)
        let content = Data(#"{"type":"claude"}"#.utf8)
        let invalidNames = [
            "",
            " ",
            ".",
            "..",
            "../credentials.json",
            "nested/credentials.json",
            #"nested\credentials.json"#,
            "credentials.txt",
            " credentials.json",
            "credentials.json ",
        ]

        for name in invalidNames {
            do {
                try await service.uploadAuthFile(name: name, content: content)
                XCTFail("Expected \(name.debugDescription) to be rejected")
            } catch AuthFileError.invalidFileName {
                // Expected.
            } catch {
                XCTFail("Unexpected error for \(name.debugDescription): \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDirectUploadWritesPrivateFileAndRoundTripsContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DirectAuthFileService(authDirectory: directory)
        let content = Data(#"{"type":"claude","email":"person@example.com"}"#.utf8)

        try await service.uploadAuthFile(name: "claude-person@example.com.json", content: content)

        let fileURL = directory.appendingPathComponent("claude-person@example.com.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let downloadedContent = try await service.downloadAuthFile(name: fileURL.lastPathComponent)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(downloadedContent, content)
    }

    @MainActor
    func testImportedXAIAndDevinFilesRemainVisibleWhenCPAIsStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DirectAuthFileService(authDirectory: directory)
        let types = ["xai", " X-AI ", "grok", "devin", "claude", "github-copilot"]
        let expected: [AIProvider] = [.grok, .grok, .grok, .devin, .claude, .copilot]
        for (index, type) in types.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: ["type": type, "email": "fixture@example.invalid"])
            // 使用不含服务商前缀的名字，确保实际识别来自 JSON 而不是文件名猜测。
            try await service.uploadAuthFile(name: "fixture-\(index).json", content: data)
            let downloaded = try await service.downloadAuthFile(name: "fixture-\(index).json")
            XCTAssertEqual(downloaded, data, "映射修复不能重写已有凭据内容")
        }
        let files = await service.scanAllAuthFiles()
        XCTAssertEqual(files.count, types.count)
        for (index, provider) in expected.enumerated() {
            XCTAssertEqual(files.first { $0.filename == "fixture-\(index).json" }?.provider, provider)
            XCTAssertEqual(AIProvider.fromAuthProvider(types[index]), provider)
        }
    }

    func testImportRejectsJSONThatIsNotAnObject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("credentials.json")
        try Data(#"["not", "an", "object"]"#.utf8).write(to: sourceURL)
        let service = DirectAuthFileService(authDirectory: directory.appendingPathComponent("auth"))

        do {
            _ = try await service.readAuthFileForImport(from: sourceURL)
            XCTFail("Expected a top-level JSON array to be rejected")
        } catch AuthFileError.invalidJSON {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthFileEndpointEncodesQueryDelimiters() throws {
        XCTAssertEqual(
            try ManagementAPIClient.authFileEndpoint(
                "/credentials/download",
                name: "claude-user+tag@example.com&team=one.json"
            ),
            "/credentials/download?name=claude-user%2Btag%40example.com%26team%3Done.json"
        )
    }

    @MainActor
    func testDownloadEligibilityRequiresAnAuthFileName() {
        let authFileAccount = AccountRowData(
            id: "auth-file",
            provider: .claude,
            displayName: "person@example.com",
            authFileName: "claude-person@example.com.json",
            source: .direct,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: false
        )
        let customProviderAccount = AccountRowData(
            id: "custom-provider",
            provider: .glm,
            displayName: "GLM",
            source: .direct,
            status: "ready",
            statusMessage: nil,
            isDisabled: false,
            canDelete: true
        )

        XCTAssertTrue(authFileAccount.canDownloadAuthFile)
        XCTAssertFalse(customProviderAccount.canDownloadAuthFile)
    }
}
