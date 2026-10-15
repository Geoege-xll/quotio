import XCTest
import Yams
@testable import QuotioPlus

final class CPA8VersionPolicyTests: XCTestCase {
    func testOnlyCPA8ReleasesCanBeActivated() {
        // 官方仍同时发布 7.x；版本过滤必须解析主版本，不能误收 7.x 或 80.x。
        for accepted in ["8.0.0", "v8.0.3", "8.2.1-1"] {
            XCTAssertTrue(ProxyVersionInfo(version: accepted, sha256: "").isSupportedMajorVersion)
        }
        for rejected in ["7.3.20", "v7.3.21", "80.0.0", "8beta", "8", "8.0", "8..0", "8.-1.0", "-8.0.0", "9.0.0", ""] {
            XCTAssertFalse(ProxyVersionInfo(version: rejected, sha256: "").isSupportedMajorVersion)
        }
        XCTAssertEqual(ProxyVersionInfo.minimumSupportedVersion, "8.0.0")
    }

    /// 只有明确的 GitHub API 限流才访问发行页；普通 403 或服务端错误保持原始失败。
    func testReleasePageFallbackRequiresRateLimitResponse() throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases"))
        let throttled = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 403, httpVersion: nil, headerFields: ["X-RateLimit-Remaining": "0"]
        ))
        let forbidden = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
        let tooMany = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil))

        XCTAssertTrue(ProxyReleasePageParser.isRateLimited(throttled))
        XCTAssertTrue(ProxyReleasePageParser.isRateLimited(tooMany))
        XCTAssertFalse(ProxyReleasePageParser.isRateLimited(forbidden))
    }

    /// 网页中的预发布标记独立于标签格式；同时过滤 v7 并去除重复条目。
    func testReleasePageUsesPublishedStatusInsteadOfTagShape() {
        let html = """
        <section id="release-v7.3.21"><include-fragment data-deferred-src="https://github.com/router-for-me/CLIProxyAPI/releases/expanded_assets/v7.3.21"></include-fragment></section>
        <section id="release-v8.0.4"><span class="Label Label--warning">Pre-release</span><include-fragment data-deferred-src="https://github.com/router-for-me/CLIProxyAPI/releases/expanded_assets/v8.0.4"></include-fragment></section>
        <section id="release-v8.2.1-1"><include-fragment data-deferred-src="https://github.com/router-for-me/CLIProxyAPI/releases/expanded_assets/v8.2.1-1"></include-fragment></section>
        <section id="release-v8.2.1-1"><include-fragment data-deferred-src="https://github.com/router-for-me/CLIProxyAPI/releases/expanded_assets/v8.2.1-1"></include-fragment></section>
        """

        let listed = ProxyReleasePageParser.listedReleases(in: html, repository: "router-for-me/CLIProxyAPI")
        XCTAssertEqual(listed, [
            .init(tag: "v8.0.4", prerelease: true),
            .init(tag: "v8.2.1-1", prerelease: false)
        ])
        // 列表标记需传递给指定标签的资产解析；资产页本身不包含发布状态。
        let assetHTML = """
        <li><a href="/router-for-me/CLIProxyAPI/releases/download/v8.0.4/CLIProxyAPI_8.0.4_darwin_arm64.tar.gz">macOS</a><span>sha256:\(String(repeating: "a", count: 64))</span></li>
        """
        let release = ProxyReleasePageParser.release(
            tag: listed[0].tag, html: assetHTML,
            repository: "router-for-me/CLIProxyAPI", prerelease: listed[0].prerelease
        )
        XCTAssertEqual(release?.prerelease, true)
    }

    /// 官方首屏可能全是较新的 v7；必须只沿站内下一页链接继续查找 v8。
    func testReleasePagePaginationCanReachV8AfterV7OnlyPage() {
        let first = """
        <section id="release-v7.3.22"><include-fragment data-deferred-src="https://github.com/router-for-me/CLIProxyAPI/releases/expanded_assets/v7.3.22"></include-fragment></section>
        <a class="next_page" rel="next" href="/router-for-me/CLIProxyAPI/releases?page=2">Next</a>
        """
        let second = """
        <section id="release-v8.0.3"><include-fragment data-deferred-src="https://github.com/router-for-me/CLIProxyAPI/releases/expanded_assets/v8.0.3"></include-fragment></section>
        <a href="https://example.com/router-for-me/CLIProxyAPI/releases?page=3">External</a>
        """

        XCTAssertTrue(ProxyReleasePageParser.listedReleases(in: first, repository: "router-for-me/CLIProxyAPI").isEmpty)
        XCTAssertEqual(ProxyReleasePageParser.nextPage(in: first, repository: "router-for-me/CLIProxyAPI"), 2)
        XCTAssertEqual(ProxyReleasePageParser.listedReleases(in: second, repository: "router-for-me/CLIProxyAPI"),
                       [.init(tag: "v8.0.3", prerelease: false)])
        XCTAssertNil(ProxyReleasePageParser.nextPage(in: second, repository: "router-for-me/CLIProxyAPI"))
    }

    /// 单个发行资产不可读或校验信息缺失时，后面的可安装版本仍须出现在列表中。
    func testReleasePageVersionCollectionSkipsBrokenCandidates() async throws {
        let candidates: [ProxyReleasePageParser.ListedRelease] = [
            .init(tag: "v8.0.5", prerelease: false),
            .init(tag: "v8.0.4", prerelease: false),
            .init(tag: "v8.0.3", prerelease: false)
        ]
        let versions = try await ProxyReleasePageParser.collectAvailableVersions(from: candidates, limit: 2) { candidate in
            if candidate.tag == "v8.0.5" { throw ProxyError.networkError("assets not ready") }
            if candidate.tag == "v8.0.4" { return nil }
            return ProxyVersionInfo(version: "8.0.3", sha256: String(repeating: "a", count: 64))
        }

        XCTAssertEqual(versions.map(\.version), ["8.0.3"])
    }

    /// 下载地址必须属于指定发行版；缺少该资产行 SHA-256 时不得生成可安装版本。
    func testReleasePageAssetKeepsMatchingDigest() throws {
        let digest = String(repeating: "a", count: 64)
        let html = """
        <li><a href="/router-for-me/CLIProxyAPI/releases/download/v8.0.3/CLIProxyAPI_8.0.3_darwin_arm64.tar.gz">macOS</a><span>sha256:\(digest)</span></li>
        <li><a href="/router-for-me/CLIProxyAPI/releases/download/v7.3.21/old.tar.gz">旧版</a></li>
        """
        let release = try XCTUnwrap(ProxyReleasePageParser.release(
            tag: "v8.0.3", html: html, repository: "router-for-me/CLIProxyAPI"
        ))

        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].sha256Checksum, digest)
        XCTAssertEqual(ProxyVersionInfo(from: release, asset: release.assets[0])?.version, "8.0.3")
        XCTAssertNil(ProxyReleasePageParser.release(
            tag: "v7.3.21", html: html, repository: "router-for-me/CLIProxyAPI"
        ))

        let withoutDigest = try XCTUnwrap(ProxyReleasePageParser.release(
            tag: "v8.0.3", html: html.replacingOccurrences(of: "sha256:\(digest)", with: ""),
            repository: "router-for-me/CLIProxyAPI"
        ))
        XCTAssertNil(ProxyVersionInfo(from: withoutDigest, asset: withoutDigest.assets[0]))
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
