import Foundation
import XCTest
@testable import QuotioPlus

/// 只验证纯路径／服务名及临时文件，明确用 UTF-8 字节比较 NFC，避免 Swift String 的规范等价掩盖错误。
final class ClaudeConfigDirectoryTests: XCTestCase {
    func testDefaultAndExplicitDefaultDirectoryUseDifferentKeychainServices() {
        XCTAssertEqual(ClaudeCredentialOwnership.keychainService(environment: [:]), "Claude Code-credentials")
        XCTAssertEqual(ClaudeCredentialOwnership.keychainService(environment: ["CLAUDE_CONFIG_DIR": ""]), "Claude Code-credentials")
        XCTAssertEqual(ClaudeCredentialOwnership.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-work"]),
                       "Claude Code-credentials-87169a1d")
        let explicit = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
        XCTAssertNotEqual(ClaudeCredentialOwnership.keychainService(environment: ["CLAUDE_CONFIG_DIR": explicit]), "Claude Code-credentials")
    }

    func testClaudeNFCMatchesEquivalentUnicodeButKeepsLiteralSeparatorsAndCase() {
        let decomposed = "/tmp/cafe\u{301}//profile/"
        let composed = decomposed.precomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(decomposed.utf8), Array(composed.utf8))
        XCTAssertEqual(Array(ClaudeCredentialOwnership.configDirectory(environment: ["CLAUDE_CONFIG_DIR": decomposed]).utf8), Array(composed.utf8))
        let service = ClaudeCredentialOwnership.keychainService(environment: ["CLAUDE_CONFIG_DIR": decomposed])
        XCTAssertEqual(service, ClaudeCredentialOwnership.keychainService(environment: ["CLAUDE_CONFIG_DIR": composed]))
        for different in ["/tmp/café/profile/", "/tmp/café//profile", "/tmp/Café//profile/"] {
            XCTAssertNotEqual(service, ClaudeCredentialOwnership.keychainService(environment: ["CLAUDE_CONFIG_DIR": different]))
        }
    }

    func testTildeExpansionRetainsTrailingAndDoubleSeparators() {
        let raw = "~//cafe\u{301}/"
        let expected = FileManager.default.homeDirectoryForCurrentUser.path + "//café/"
        XCTAssertEqual(Array(ClaudeCredentialOwnership.configDirectory(environment: ["CLAUDE_CONFIG_DIR": raw]).utf8), Array(expected.utf8))
    }

    func testCommonPathExpansionForOtherClientsDoesNotApplyClaudeNFC() {
        let raw = "/tmp/cafe\u{301}/Codex-Grok-gh"
        XCTAssertEqual(Array(MonitorIdentity.expand(raw).utf8), Array(raw.utf8))
        XCTAssertNotEqual(Array(MonitorIdentity.expand(raw).utf8), Array(raw.precomposedStringWithCanonicalMapping.utf8))
    }

    func testNFCNativeFileStillKeepsRefreshReadOnlyAndSymlinkProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-nfc-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.path + "/cafe\u{301}//profile/"
        let environment = ["CLAUDE_CONFIG_DIR": raw]
        let native = URL(fileURLWithPath: ClaudeCredentialOwnership.configDirectory(environment: environment))
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let file = native.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"fixture","refreshToken":"never-refresh","email":"fixture@example.invalid"}}"#.utf8).write(to: file)
        XCTAssertEqual(ClaudeQuotaCredential.load(path: file.path, environment: environment)?.allowsRefresh, false)
        let link = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(ClaudeQuotaCredential.load(path: link.path, environment: environment))
    }
}
