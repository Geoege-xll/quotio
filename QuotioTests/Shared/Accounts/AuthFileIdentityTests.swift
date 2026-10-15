import XCTest
@testable import QuotioPlus

/// 使用 CPA 官方客户端去重规则对应的离线响应，验证磁盘／运行两条记录是同一凭据。
/// 不读取真实用户认证文件、不请求配额接口，重点检查索引冲突和模式切换。
@MainActor
final class AuthFileIdentityTests: XCTestCase {
    private func file(name: String = "claude-work.json", provider: String = "claude", index: String? = nil,
                      email: String? = "work@example.com", source: String? = nil,
                      status: String = "ready", disabled: Bool = false, id: String? = nil) throws -> AuthFile {
        var object: [String: Any] = ["id": id ?? name, "name": name, "provider": provider,
            "status": status, "disabled": disabled]
        if let index { object["auth_index"] = index }
        if let email { object["email"] = email }
        if let source {
            object["source"] = source
            object["runtime_only"] = source != "file"
            if source == "file" { object["path"] = "/isolated/\(name)" }
        }
        return try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func direct(name: String = "claude-work.json", email: String = "work@example.com") -> DirectAuthFile {
        DirectAuthFile(id: name, provider: .claude, email: email, login: nil, expired: nil, accountType: nil,
            filePath: "/isolated/\(name)", source: .cliProxyApi, filename: name)
    }

    private func quota(_ percent: Double, updated: TimeInterval) -> ProviderQuotaData {
        ProviderQuotaData(models: [ModelQuota(name: "fixture", percentage: percent, resetTime: "")],
            lastUpdated: Date(timeIntervalSince1970: updated), accountDisplayName: "work@example.com")
    }

    private func accounts(_ files: [AuthFile], direct: [DirectAuthFile] = [],
                          quotas: [String: ProviderQuotaData] = [:]) -> [AccountRowData] {
        AccountPageData.groupedAccounts(mode: .localProxy, proxyRunning: true, authFiles: files,
            directAuthFiles: direct, monitorAccounts: [], quotas: [.claude: quotas], customProviders: [],
            warpTokens: [], monitorStatus: { _ in (nil, nil) })[.claude] ?? []
    }

    func testDiskAndRuntimeRecordForSameFileBecomeOneCredential() throws {
        let disk = try file(source: "file")
        let runtime = try file(index: "runtime-a", email: nil, source: "memory", status: "error", disabled: true)
        for input in [[disk, runtime], [runtime, disk]] {
            let merged = try XCTUnwrap(AuthFileIdentity.deduplicated(input).first)
            XCTAssertEqual(AuthFileIdentity.deduplicated(input).count, 1)
            XCTAssertEqual(merged.authIndex, "runtime-a", "路由必须使用当前运行索引")
            XCTAssertEqual(merged.email, "work@example.com", "磁盘元数据用于补充显示身份")
            XCTAssertEqual(merged.source, "file")
            XCTAssertEqual(merged.path, disk.path)
            XCTAssertEqual(merged.runtimeOnly, false)
            XCTAssertEqual(merged.status, "error", "不能用旧磁盘状态覆盖当前运行状态")
            XCTAssertTrue(merged.disabled)
            XCTAssertEqual(accounts(input).count, 1, "服务商筛选与目录不能把同一账号计数两次")
        }
    }

    func testSameIndexedRecordIsNotListedTwice() throws {
        let runtime = try file(index: "a")
        XCTAssertEqual(AuthFileIdentity.deduplicated([runtime, runtime]).count, 1)
    }

    func testDifferentIndexesForSameFilenameStaySeparateAndKeepUnindexedEntry() throws {
        let a = try file(index: "a", id: "a")
        let b = try file(index: "b", id: "b")
        let disk = try file(source: "file", id: "disk")
        let merged = AuthFileIdentity.deduplicated([disk, a, b, a])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(Set(merged.map { $0.authIndex ?? "" }), ["", "a", "b"])
        XCTAssertEqual(accounts([a, b]).count, 2, "索引冲突不能按邮箱或文件名误合并")
    }

    func testProviderBoundaryIsNotMergedEvenWithSameFilename() throws {
        let claude = try file(index: "a")
        let antigravity = try file(provider: "antigravity", index: "b")
        XCTAssertEqual(AuthFileIdentity.deduplicated([claude, antigravity]).count, 2)
    }

    func testMissingIDsWithConflictingIndexesAndProvidersHaveStableUniqueLookupIDs() throws {
        let a = try JSONDecoder().decode(AuthFile.self,
            from: Data(#"{"name":"same.json","provider":"claude","auth_index":"a"}"#.utf8))
        let b = try JSONDecoder().decode(AuthFile.self,
            from: Data(#"{"name":"same.json","provider":"claude","auth_index":"b"}"#.utf8))
        let other = try JSONDecoder().decode(AuthFile.self,
            from: Data(#"{"name":"same.json","provider":"antigravity","auth_index":"a"}"#.utf8))
        let merged = AuthFileIdentity.deduplicated([a, b, other])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(Set(merged.map(\.id)).count, 3)
        XCTAssertEqual(AuthFileIdentity.deduplicated(merged).map(\.id), merged.map(\.id), "规范化必须幂等")
        let reversed = AuthFileIdentity.deduplicated([other, b, a])
        XCTAssertEqual(Set(reversed.map(\.id)), Set(merged.map(\.id)), "返回顺序变化不能改变查找身份")
        XCTAssertTrue(merged.allSatisfy { $0.name == "same.json" }, "管理 API 文件参数保持原值")
        XCTAssertEqual(Set(merged.filter { $0.providerType == .claude }.map { $0.authIndex ?? "" }), ["a", "b"])
    }

    func testNumericZeroIndexIsARealRoutingIdentity() throws {
        let data = Data(#"{"name":"claude-work.json","provider":"claude","auth_index":0}"#.utf8)
        let runtime = try JSONDecoder().decode(AuthFile.self, from: data)
        let merged = try XCTUnwrap(AuthFileIdentity.deduplicated([try file(source: "file"), runtime]).first)
        XCTAssertEqual(merged.authIndex, "0")
    }

    func testLegacyEmailQuotaIsAttachedToCurrentCPAKeyWithoutExtraCacheRow() throws {
        let disk = try file(source: "file")
        let runtime = try file(index: "a", source: "memory")
        let raw = ["work@example.com": quota(70, updated: 10)]
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: [disk, runtime], directFiles: [direct()])
        let migrated = AuthFileIdentity.rekey([AIProvider.claude: raw], aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        XCTAssertEqual(migrated[.claude]?.count, 1)
        XCTAssertEqual(migrated[.claude]?[runtime.quotaLookupKey]?.models[0].percentage, 70)
        let rows = accounts([disk, runtime], direct: [direct()], quotas: raw)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].quotaAccountKeys, [runtime.quotaLookupKey])
        XCTAssertEqual(rows[0].source, .proxy)
    }

    func testCurrentCPASnapshotWinsOverLegacyAndUnindexedCopies() throws {
        let disk = try file(source: "file")
        let runtime = try file(index: "a")
        let raw = ["work@example.com": quota(90, updated: 50), disk.quotaLookupKey: quota(80, updated: 30),
            runtime.quotaLookupKey: quota(40, updated: 20)]
        // 实际 ViewModel 已先规范认证目录，旧无索引槽位仍必须被识别，不能依赖原重复行留着。
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: AuthFileIdentity.deduplicated([disk, runtime]), directFiles: [direct()])
        let mapped = AuthFileIdentity.rekey([AIProvider.claude: raw], aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        XCTAssertEqual(mapped[.claude]?.count, 1)
        XCTAssertEqual(mapped[.claude]?[runtime.quotaLookupKey]?.models[0].percentage, 40,
            "已有 CPA 精确结果优先，不能被更新较晚但来自旧身份键的快照覆盖")
        XCTAssertEqual(accounts([disk, runtime], direct: [direct()], quotas: raw).count, 1)
    }

    func testNewestLegacySnapshotIsSelectedWithoutSummingQuota() throws {
        let runtime = try file(index: "a")
        let raw = ["work@example.com": quota(80, updated: 10), "claude-work.json": quota(20, updated: 30)]
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: [runtime], directFiles: [direct()])
        let mapped = AuthFileIdentity.rekey([AIProvider.claude: raw], aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        XCTAssertEqual(mapped[.claude]?.count, 1)
        XCTAssertEqual(mapped[.claude]?[runtime.quotaLookupKey]?.models[0].percentage, 20)
    }

    func testSameEmailDifferentFilesDoNotBorrowAnAmbiguousLegacyQuota() throws {
        let a = try file(name: "team-a.json", index: "a")
        let b = try file(name: "team-b.json", index: "b")
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: [a, b], directFiles: [])
        XCTAssertNil(aliases[.claude]?["work@example.com"])
        let rows = accounts([a, b], quotas: ["work@example.com": quota(50, updated: 10)])
        XCTAssertEqual(rows.filter { $0.source == .proxy }.count, 2)
        XCTAssertEqual(rows.filter { $0.source == .quotaCache }.count, 1)
    }

    func testLocalEmailCollisionBlocksAliasEvenIfOnlyOneFileHasLoadedInCPA() throws {
        let runtime = try file(name: "team-a.json", index: "a")
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true, authFiles: [runtime],
            directFiles: [direct(name: "team-a.json"), direct(name: "team-b.json")])
        XCTAssertNil(aliases[.claude]?["work@example.com"])
    }

    func testExplicitDifferentCredentialDirectoriesDoNotBorrowLocalQuota() throws {
        let payload = Data(#"{"name":"claude-work.json","provider":"claude","email":"work@example.com","auth_index":"a","path":"/other-directory/claude-work.json"}"#.utf8)
        let runtime = try JSONDecoder().decode(AuthFile.self, from: payload)
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: [runtime], directFiles: [direct()])
        XCTAssertNil(aliases[.claude]?["work@example.com"])
        XCTAssertNil(aliases[.claude]?["claude-work.json"])
        let stopped = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: false,
            authFiles: [runtime], directFiles: [direct()])
        XCTAssertNil(stopped[.claude]?[runtime.quotaLookupKey], "停服也不能跨明确不同的目录迁移")
    }

    func testStopAndRestartReusesSameFileSnapshotWithCurrentDirectoryKey() throws {
        let runtime = try file(index: "a")
        let local = direct()
        let running = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: [runtime], directFiles: [local])
        let initial = [AIProvider.claude: [local.menuBarAccountKey: quota(70, updated: 10)]]
        let started = AuthFileIdentity.rekey(initial, aliases: running) { $0.lastUpdated > $1.lastUpdated }
        let stoppedAliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: false,
            authFiles: [runtime], directFiles: [local])
        let stopped = AuthFileIdentity.rekey(started, aliases: stoppedAliases) { $0.lastUpdated > $1.lastUpdated }
        XCTAssertEqual(stopped[.claude]?.count, 1)
        XCTAssertEqual(stopped[.claude]?[local.menuBarAccountKey]?.models[0].percentage, 70)
        let restarted = AuthFileIdentity.rekey(stopped, aliases: running) { $0.lastUpdated > $1.lastUpdated }
        XCTAssertEqual(restarted[.claude]?.count, 1)
        XCTAssertNotNil(restarted[.claude]?[runtime.quotaLookupKey])
    }

    func testStoppingNeverCollapsesDifferentIndexedCredentialsIntoOneLocalEmail() throws {
        let a = try file(index: "a", id: "a")
        let b = try file(index: "b", id: "b")
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: false,
            authFiles: [a, b], directFiles: [direct()])
        XCTAssertNil(aliases[.claude]?[a.quotaLookupKey])
        XCTAssertNil(aliases[.claude]?[b.quotaLookupKey])
        let original = [AIProvider.claude: [a.quotaLookupKey: quota(20, updated: 10),
            b.quotaLookupKey: quota(80, updated: 20)]]
        let mapped = AuthFileIdentity.rekey(original, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        XCTAssertEqual(mapped[.claude]?.count, 2)
        XCTAssertEqual(mapped[.claude]?[a.quotaLookupKey]?.models[0].percentage, 20)
        XCTAssertEqual(mapped[.claude]?[b.quotaLookupKey]?.models[0].percentage, 80)
        let pins = [MenuBarQuotaItem(provider: "claude", accountKey: a.quotaLookupKey),
            MenuBarQuotaItem(provider: "claude", accountKey: b.quotaLookupKey)]
        XCTAssertEqual(AuthFileIdentity.rekeyMenuBarItems(pins, aliases: aliases), pins)
    }

    func testMonitorDirectoryIsNotRekeyedByUnrelatedCPAState() throws {
        let aliases = AuthFileIdentity.quotaAliases(mode: .monitor, proxyRunning: true,
            authFiles: [try file(index: "a")], directFiles: [direct()])
        XCTAssertTrue(aliases.isEmpty)
    }

    func testPinnedItemsFollowCredentialKeyWithoutDuplicatingOrChangingOrder() throws {
        let runtime = try file(index: "a")
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: [runtime], directFiles: [direct()])
        let other = MenuBarQuotaItem(provider: AIProvider.codex.rawValue, accountKey: "other")
        let items = [other, MenuBarQuotaItem(provider: "claude", accountKey: "work@example.com"),
            MenuBarQuotaItem(provider: "claude", accountKey: runtime.quotaLookupKey)]
        let migrated = AuthFileIdentity.rekeyMenuBarItems(items, aliases: aliases)
        XCTAssertEqual(migrated, [other, MenuBarQuotaItem(provider: "claude", accountKey: runtime.quotaLookupKey)])
        XCTAssertEqual(AuthFileIdentity.rekeyMenuBarItems(migrated, aliases: aliases), migrated,
            "重复刷新必须保持幂等，不能继续改变固定项")
    }
}
