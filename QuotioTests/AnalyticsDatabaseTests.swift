import XCTest
import SQLite3
@testable import Quotio

/// 公共数据库只使用临时路径，验证统一存储依赖的事务、隔离和迁移边界。
final class AnalyticsDatabaseTests: XCTestCase {
    private enum TestError: Error { case interrupted }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("analytics.sqlite")
    }

    func testRollbackDoesNotAdvanceMigrationOrCommitPartialFacts() throws {
        let db = AnalyticsDatabase(url: try location())
        try db.execute("CREATE TABLE facts(id INTEGER PRIMARY KEY)")
        XCTAssertThrowsError(try db.transaction {
            try db.execute("INSERT INTO facts VALUES(1)")
            try db.markMigration("client-v1")
            throw TestError.interrupted
        })
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM facts"), 0)
        XCTAssertFalse(try db.hasMigration("client-v1"))
        try db.transaction {
            try db.execute("INSERT INTO facts VALUES(2)")
            try db.markMigration("client-v1")
        }
        XCTAssertEqual(try db.scalarInt("SELECT id FROM facts"), 2)
        XCTAssertTrue(try db.hasMigration("client-v1"))
        XCTAssertFalse(try db.hasMigration("cpa-v1"))
    }

    func testNestedRollbackPreservesOuterTransactionAndOtherConnectionsSeeCommit() throws {
        let url = try location()
        let first = AnalyticsDatabase(url: url), second = AnalyticsDatabase(url: url)
        try first.execute("CREATE TABLE facts(id INTEGER PRIMARY KEY)")
        _ = try second.connection()
        try first.transaction {
            try first.execute("INSERT INTO facts VALUES(1)")
            XCTAssertThrowsError(try first.transaction {
                try first.execute("INSERT INTO facts VALUES(2)")
                throw TestError.interrupted
            })
            XCTAssertEqual(try second.scalarInt("SELECT COUNT(*) FROM facts"), 0)
            try first.execute("INSERT INTO facts VALUES(3)")
        }
        XCTAssertEqual(try second.scalarInt("SELECT COUNT(*) FROM facts"), 2)
        XCTAssertEqual(try second.scalarText("PRAGMA journal_mode"), "wal")
    }

    func testEmptyBlobIsNotNullAndNewDatabaseHasPrivatePermissions() throws {
        let url = try location(), db = AnalyticsDatabase(url: url)
        try db.execute("CREATE TABLE values_table(value BLOB)")
        try db.execute("INSERT INTO values_table VALUES(?)", [.blob(Data())])
        XCTAssertEqual(try db.scalarText("SELECT typeof(value) FROM values_table"), "blob")
        XCTAssertEqual(try db.scalarInt("SELECT length(value) FROM values_table"), 0)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
    }

    func testSymlinkDatabaseAndLegacyPathsAreRejected() throws {
        let target = try location(), link = target.deletingLastPathComponent().appendingPathComponent("linked.sqlite")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AnalyticsDatabase.validate(link))
        XCTAssertThrowsError(try AnalyticsDatabase(url: link).connection())
    }

    func testAllProductionLegacyDirectoriesResolveToOneDatabase() {
        let home = "/isolated-home"
        for directory in ["UsageStatistics", "ClientUsage", "CallAnalytics"] {
            let old = URL(fileURLWithPath: home + "/Library/Application Support/Quotio/" + directory + "/ledger.json")
            XCTAssertEqual(AnalyticsDatabase.storeURL(forLegacyURL: old), AnalyticsDatabase.defaultURL(homeDirectory: home))
        }
    }
}
