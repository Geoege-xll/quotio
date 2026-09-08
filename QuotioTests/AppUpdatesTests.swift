import XCTest
import Sparkle
@testable import Quotio

/// 使用临时 Bundle 和注入的上游响应验证更新边界，不联网、不启动 Sparkle、不安装任何应用。
@MainActor
final class AppUpdatesTests: XCTestCase {
    private func bundle(_ info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("FallbackName.bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return try XCTUnwrap(Bundle(url: root))
    }

    private func release(tag: String = "v9.2.1") -> UpstreamRelease {
        UpstreamRelease(tag: tag, name: "Release", publishedAt: Date(timeIntervalSince1970: 1000), notes: "Release notes")
    }

    func testDisplayNameOverridesProjectAndExecutableNames() throws {
        let value = try bundle(["CFBundleDisplayName": "我的应用", "CFBundleName": "LegacyProject", "CFBundleExecutable": "OldBinary"])
        XCTAssertEqual(AppIdentity.displayName(in: value), "我的应用")
    }

    func testDisplayNameFallbacksHandleMissingAndBlankValues() throws {
        for name in ["", "  \n"] {
            XCTAssertEqual(AppIdentity.displayName(in: try bundle(["CFBundleDisplayName": name, "CFBundleName": "BundleName"])), "BundleName")
        }
        XCTAssertEqual(AppIdentity.displayName(in: try bundle([:])), "FallbackName")
    }

    func testBuiltApplicationUsesOwnReleaseFeedAndSeparateUpstream() throws {
        XCTAssertEqual(AppIdentity.displayName, "QuotioPlus")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.app.george.quotioplus")
        XCTAssertTrue(AppIdentity.versionDescription.hasPrefix(AppIdentity.displayName + " v"))
        XCTAssertEqual(AppReleaseConfiguration.repository, "Geoege-xll/quotio")
        XCTAssertEqual(AppReleaseConfiguration.upstreamRepository, "nguyenphutrong/quotio")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, AppReleaseConfiguration.feedURL.absoluteString)
        XCTAssertEqual(AppReleaseConfiguration.atomFeedURL.absoluteString, "https://github.com/Geoege-xll/quotio/releases.atom")
        XCTAssertFalse(AppReleaseConfiguration.feedURL.absoluteString.contains(AppReleaseConfiguration.upstreamRepository))
        XCTAssertTrue(AppReleaseConfiguration.upstreamAPIURL.absoluteString.contains(AppReleaseConfiguration.upstreamRepository))
    }

    func testOnlyConfiguredOwnPublicKeysEnableAutomaticInstallation() {
        XCTAssertFalse(AppReleaseConfiguration.isValidPublicKey(nil))
        XCTAssertFalse(AppReleaseConfiguration.isValidPublicKey("$(SPARKLE_PUBLIC_ED_KEY)"))
        XCTAssertFalse(AppReleaseConfiguration.isValidPublicKey("not a key"))
        XCTAssertFalse(AppReleaseConfiguration.isValidPublicKey(Data(repeating: 1, count: 31).base64EncodedString()))
        XCTAssertFalse(AppReleaseConfiguration.isValidPublicKey("HBpWFjUcNUuuZfdxhVlw2Mc87IT8tj1C68rufluZ0M4="))
        XCTAssertTrue(AppReleaseConfiguration.isValidPublicKey(Data(repeating: 1, count: 32).base64EncodedString()))
    }

    func testUpdaterImplementsSparkleCompletionSelector() {
        // 可选 Objective-C 委托方法拼写错误也能编译，因此同时验证协议 selector 和实际方法注册。
        // 只检查类型信息，不初始化服务、访问用户偏好或启动更新器。
        let selector = #selector(SPUUpdaterDelegate.updater(_:didFinishUpdateCycleFor:error:))
        XCTAssertNotNil(class_getInstanceMethod(UpdaterService.self, selector))
    }

    func testAutomaticCheckPreferenceDistinguishesUnsetFromDisabled() throws {
        let name = "AppUpdatesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(UpdaterService.automaticCheckPreference(defaults: defaults))
        defaults.set(false, forKey: "autoCheckUpdates")
        XCTAssertFalse(UpdaterService.automaticCheckPreference(defaults: defaults))
        defaults.set(true, forKey: "autoCheckUpdates")
        XCTAssertTrue(UpdaterService.automaticCheckPreference(defaults: defaults))
    }

    func testUpstreamReleaseUsesTagAndOfficialLinkRatherThanAppVersion() throws {
        let data = Data(#"{"tag_name":"v9.2.1","name":"Upstream release","published_at":"2026-09-08T02:30:00Z","body":"Notes","html_url":"https://example.invalid/redirect"}"#.utf8)
        let result = try XCTUnwrap(UpstreamRelease.decode(data, statusCode: 200))
        XCTAssertEqual(result.tag, "v9.2.1")
        XCTAssertNotNil(result.publishedAt)
        XCTAssertEqual(result.releaseURL.absoluteString, "https://github.com/nguyenphutrong/quotio/releases/tag/v9.2.1")
    }

    func testNoReleaseAndHTTPFailuresAreNotReportedAsUpToDate() throws {
        XCTAssertNil(try UpstreamRelease.decode(Data(), statusCode: 404))
        XCTAssertThrowsError(try UpstreamRelease.decode(Data(), statusCode: 403))
        XCTAssertThrowsError(try UpstreamRelease.decode(Data(), statusCode: 500))
        XCTAssertThrowsError(try UpstreamRelease.decode(Data("broken".utf8), statusCode: 200))
        XCTAssertThrowsError(try UpstreamRelease.decode(Data(#"{"tag_name":" "}"#.utf8), statusCode: 200))
    }

    func testOpeningAnAlreadyCheckedScreenDoesNotRequestAgain() async {
        let expected = release()
        let checker = UpstreamReleaseChecker(load: { expected })
        await checker.checkIfNeeded()
        let checked = checker.lastChecked
        XCTAssertEqual(checker.release, expected)
        XCTAssertNotNil(checked)
        XCTAssertNil(checker.errorKey)
        await checker.checkIfNeeded()
        XCTAssertEqual(checker.lastChecked, checked)
        XCTAssertFalse(checker.isChecking)
    }

    func testFailedRetryPreservesPreviousReleaseAndTimestamp() async {
        let expected = release()
        let loader = ResponseSequence(release: expected)
        let checker = UpstreamReleaseChecker(load: { try await loader.next() })
        await checker.check()
        let checked = checker.lastChecked
        await checker.check()
        XCTAssertEqual(checker.release, expected)
        XCTAssertEqual(checker.lastChecked, checked)
        XCTAssertEqual(checker.errorKey, "updates.upstream.rateLimited")
        XCTAssertFalse(checker.isChecking)
    }

    func testLeavingDuringCheckDoesNotPublishAnErrorOrSuccess() async {
        let checker = UpstreamReleaseChecker(load: {
            try await Task.sleep(for: .seconds(30))
            return nil
        })
        let task = Task { await checker.check() }
        await Task.yield()
        task.cancel()
        await task.value
        XCTAssertNil(checker.lastChecked)
        XCTAssertNil(checker.errorKey)
        XCTAssertFalse(checker.isChecking)
    }

    func testEmptyReleaseListHasSuccessfulCheckTime() async {
        let checker = UpstreamReleaseChecker(load: { nil })
        await checker.check()
        XCTAssertNil(checker.release)
        XCTAssertNotNil(checker.lastChecked)
        XCTAssertNil(checker.errorKey)
    }

    /// 跨任务状态由 actor 串行维护，避免测试夹具自身引入 Swift 6 数据竞争。
    private actor ResponseSequence {
        let release: UpstreamRelease
        var count = 0
        init(release: UpstreamRelease) { self.release = release }
        func next() throws -> UpstreamRelease? {
            count += 1
            if count == 1 { return release }
            throw UpstreamRelease.CheckError.http(429)
        }
    }
}
