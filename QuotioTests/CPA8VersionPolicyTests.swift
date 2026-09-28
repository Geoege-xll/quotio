import XCTest
import Yams
@testable import QuotioPlus

final class CPA8VersionPolicyTests: XCTestCase {
    func testOnlyCPA8ReleasesCanBeActivated() {
        // 官方仍同时发布 7.x；版本过滤必须解析主版本，不能误收 7.x 或 80.x。
        for accepted in ["8.0.0", "v8.0.3", "8.2.1-1"] {
            XCTAssertTrue(ProxyVersionInfo(version: accepted, sha256: "").isSupportedMajorVersion)
        }
        for rejected in ["7.3.20", "v7.3.21", "80.0.0", "8beta", ""] {
            XCTAssertFalse(ProxyVersionInfo(version: rejected, sha256: "").isSupportedMajorVersion)
        }
    }

    func testVersionDeclarationAloneCannotSkipOfficialConfigMigration() {
        // 混合文件可被 CPA 8 读取，但仍须通过官方 v8 写入接口完成布局迁移。
        let mixed: [String: Any] = [
            "config-version": 8, "server": ["port": 8317], "management": ["secret-key": "test"],
            "api-keys": ["legacy-client-key"]
        ]
        XCTAssertFalse(CPAConfigLayout.isMigratedV8(mixed))

        let migrated: [String: Any] = [
            "config-version": 8, "server": ["port": 8317], "management": ["secret-key": "test"],
            "access": ["api-keys": ["client-key"]], "api-keys": ["claude": [["keys": [["api-key": "fake"]]]]],
            "quota-exceeded": ["switch-project": true]
        ]
        XCTAssertTrue(CPAConfigLayout.isMigratedV8(migrated))
    }

    func testV8SettingUpdatePreservesUnrelatedCommentsAndSections() throws {
        let original = """
        # 用户写的全局说明
        config-version: 8
        server:
          host: "127.0.0.1"
          port: 8317
        # 自定义凭据说明
        management:
          secret-key: "test-key"
        access:
          api-keys: ["client-key"]

        """
        let updated = try CPAConfigLayout.updating(original, path: ["server", "port"], value: 8318)
        XCTAssertTrue(updated.contains("# 用户写的全局说明"))
        XCTAssertTrue(updated.contains("# 自定义凭据说明"))
        XCTAssertTrue(updated.contains("port: 8318"))
        XCTAssertEqual(try CPAConfigLayout.updating(updated, path: ["server", "port"], value: 8318), updated)

        let withRequests = try CPAConfigLayout.updating(updated, path: ["requests", "proxy-url"], value: "")
        XCTAssertTrue(withRequests.contains("requests:\n  proxy-url: \"\""))
        XCTAssertTrue(withRequests.contains("# 自定义凭据说明"))
    }

    func testInlineV8MappingsRemainValidAndKeepTrailingComments() throws {
        let original = """
        config-version: 8
        server: {host: 127.0.0.1, port: 8317} # 服务监听
        management: {secret-key: "old#key"} # 管理密钥说明

        """
        let portUpdated = try CPAConfigLayout.updating(original, path: ["server", "port"], value: 8318)
        let secretUpdated = try CPAConfigLayout.updating(
            portUpdated, path: ["management", "secret-key"], value: "new#key"
        )
        XCTAssertTrue(secretUpdated.contains("# 服务监听"))
        XCTAssertTrue(secretUpdated.contains("# 管理密钥说明"))
        let root = try XCTUnwrap(Yams.load(yaml: secretUpdated) as? [String: Any])
        XCTAssertEqual((root["server"] as? [String: Any])?["port"] as? Int, 8318)
        XCTAssertEqual((root["management"] as? [String: Any])?["secret-key"] as? String, "new#key")
    }
}
