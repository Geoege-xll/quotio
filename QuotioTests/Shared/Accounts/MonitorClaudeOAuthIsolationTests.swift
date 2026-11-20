import Foundation
import XCTest
@testable import QuotioPlus

/// 使用临时元数据和内存保险库验证已失效的世代不能提交凭据。
@MainActor
final class MonitorClaudeOAuthIsolationTests: XCTestCase {
    private struct Fixture {
        let metadata: MonitorMetadataStore
        let vault: MonitorCredentialVault
        let backend: MemoryBackend
    }

    /// 锁只保护测试内存字典；可在一次无世代保存中阻塞保险库，以验证排队中的旧授权不能越过取消。
    private final class MemoryBackend: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var nextGate: SaveGate?
        var count: Int { lock.withLock { values.count } }
        func blockNextSave(_ gate: SaveGate) { lock.withLock { nextGate = gate } }
        func read(_ key: String) -> Data? { lock.withLock { values[key] } }
        func save(_ data: Data, _ key: String) -> Bool {
            let gate = lock.withLock { let gate = nextGate; nextGate = nil; return gate }
            gate?.wait()
            return lock.withLock { values[key] = data; return true }
        }
        func replace(_ data: Data, _ key: String, _ expected: String) -> Bool {
            lock.withLock {
                guard let old = values[key], MonitorIdentity.fingerprint(old.base64EncodedString()) == expected else { return false }
                values[key] = data
                return true
            }
        }
        func delete(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
        var adapter: MonitorCredentialVault.Backend {
            .init(read: { self.read($0) }, save: { self.save($0, $1) },
                  compareAndSwap: { self.replace($0, $1, $2) }, delete: { self.delete($0) })
        }
    }

    private final class SaveGate: @unchecked Sendable {
        let entered: XCTestExpectation
        private let condition = NSCondition()
        private var released = false
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() {
            entered.fulfill()
            condition.lock()
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() {
            condition.lock(); released = true; condition.broadcast(); condition.unlock()
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = MonitorMetadataStore(url: directory.appendingPathComponent("accounts.json"))
        let backend = MemoryBackend()
        let vault = MonitorCredentialVault(metadata: metadata, backend: backend.adapter)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Fixture(metadata: metadata, vault: vault, backend: backend)
    }

    func testQueuedVaultWriteRejectsSessionInvalidatedWhileWaiting() async throws {
        let fixture = try fixture()
        let entered = expectation(description: "无世代保存暂时占用保险库"), queued = expectation(description: "授权保存准备进入保险库")
        let gate = SaveGate(entered)
        fixture.backend.blockNextSave(gate)
        defer { gate.release() }
        let credential = MonitorOAuthCredential(accessToken: "fixture", refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil, extra: [:])
        let first = MonitorAccount.make(provider: .claude, accountKey: "first", source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let expired = MonitorAccount.make(provider: .claude, accountKey: "expired", source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let occupying = Task { try await fixture.vault.save(credential, metadata: first) }
        await fulfillment(of: [entered], timeout: 3)
        let state = MonitorStateRevision(), revision = state.advance()
        let pending = Task {
            queued.fulfill()
            try await fixture.vault.save(credential, metadata: expired, revision: revision, state: state)
        }
        await fulfillment(of: [queued], timeout: 3)
        state.advance()
        gate.release()
        try await occupying.value
        do { try await pending.value; XCTFail("排队期间已取消的授权不能在保险库恢复后保存") }
        catch { XCTAssertTrue(error is CancellationError) }
        let accounts = await fixture.metadata.accounts()
        XCTAssertEqual(fixture.backend.count, 1)
        XCTAssertNil(fixture.backend.read(expired.id))
        XCTAssertEqual(accounts.map(\.id), [first.id])
    }

    func testMetadataRejectsExpiredSessionWithoutChangingExistingAccounts() async throws {
        let fixture = try fixture()
        let account = MonitorAccount.make(provider: .claude, accountKey: "fixture", source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let state = MonitorStateRevision(), revision = state.advance()
        state.advance()
        do { try await fixture.metadata.saveAccount(account, revision: revision, state: state); XCTFail("失效授权不能补写元数据") }
        catch { XCTAssertTrue(error is CancellationError) }
        let accounts = await fixture.metadata.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

}
