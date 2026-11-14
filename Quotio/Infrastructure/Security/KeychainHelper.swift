//
//  KeychainHelper.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Keychain helper for secure credential storage
//

import Foundation
import LocalAuthentication
import Security

// MARK: - Keychain Helper

enum KeychainHelper {
    nonisolated enum MonitorCredentialBackend: Equatable {
        case keychain
        case vault
    }

    nonisolated private static let securityLock = NSRecursiveLock()
    nonisolated private static var localService: String {
        AppIdentity.keychainService(suffix: "local-management")
    }
    nonisolated private static var warpService: String {
        AppIdentity.keychainService(suffix: "warp")
    }
    private static let localManagementAccount = "local-management-key"
    private static let warpTokensAccount = "warp-tokens"
    private static let localManagementDefaultsKey = "managementKey"
    private static let warpTokensDefaultsKey = "warpTokens"
    nonisolated private static var monitorAuthService: String {
        AppIdentity.keychainService(suffix: "monitor-auth")
    }

    // Legacy service names for keychain migration (newest first)
    nonisolated private static var legacyLocalServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "local-management")
    }
    nonisolated private static var legacyWarpServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "warp")
    }
    nonisolated private static var legacyMonitorAuthServices: [String] {
        AppIdentity.legacyKeychainServices(suffix: "monitor-auth")
    }

    static func saveLocalManagementKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        let saved = saveData(data, service: localService, account: localManagementAccount)
        if !saved {
            Log.keychain("Failed to save local management key")
        }
        return saved
    }

    static func getLocalManagementKey() -> String? {
        if let key = readString(service: localService, account: localManagementAccount) {
            return key
        }

        // Migrate from legacy keychain service name
        if AppIdentity.isProduction,
           let legacyKey = migrateString(from: legacyLocalServices, to: localService, account: localManagementAccount) {
            return legacyKey
        }

        guard let legacyKey = UserDefaults.standard.string(forKey: localManagementDefaultsKey),
              !legacyKey.hasPrefix("$2a$") else {
            return nil
        }

        if saveLocalManagementKey(legacyKey) {
            UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
        }

        return legacyKey
    }

    static func deleteLocalManagementKey() {
        deleteData(service: localService, account: localManagementAccount)
        if AppIdentity.isProduction {
            for legacy in legacyLocalServices {
                deleteData(service: legacy, account: localManagementAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
    }

    static func saveWarpTokens(_ data: Data) -> Bool {
        let saved = saveData(data, service: warpService, account: warpTokensAccount)
        if !saved {
            Log.keychain("Failed to save Warp tokens")
        }
        return saved
    }

    static func getWarpTokens() -> Data? {
        if let data = readData(service: warpService, account: warpTokensAccount) {
            return data
        }

        if AppIdentity.isProduction,
           let legacyData = migrateData(from: legacyWarpServices, to: warpService, account: warpTokensAccount) {
            return legacyData
        }

        guard let legacyData = UserDefaults.standard.data(forKey: warpTokensDefaultsKey) else {
            return nil
        }

        if saveWarpTokens(legacyData) {
            UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
        }

        return legacyData
    }

    static func deleteWarpTokens() {
        deleteData(service: warpService, account: warpTokensAccount)
        if AppIdentity.isProduction {
            for legacy in legacyWarpServices {
                deleteData(service: legacy, account: warpTokensAccount)
            }
        }
        UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
    }

    // MARK: - Monitor-only credentials

    nonisolated static func saveMonitorCredential(_ data: Data, account: String) -> Bool {
        saveData(data, service: monitorAuthService, account: account)
    }

    nonisolated static func getMonitorCredential(account: String) -> Data? {
        if let data = readData(service: monitorAuthService, account: account) {
            return data
        }
        guard AppIdentity.isProduction else { return nil }
        return migrateData(from: legacyMonitorAuthServices, to: monitorAuthService, account: account)
    }

    nonisolated static func deleteMonitorCredential(account: String) {
        deleteData(service: monitorAuthService, account: account)
        if AppIdentity.isProduction {
            for legacy in legacyMonitorAuthServices {
                deleteData(service: legacy, account: account)
            }
        }
    }

    nonisolated static func compareAndSwapMonitorCredential(
        _ data: Data,
        account: String,
        expectedFingerprint: String
    ) -> Bool {
        guard let current = getMonitorCredential(account: account),
              MonitorIdentity.fingerprint(current.base64EncodedString()) == expectedFingerprint else {
            return false
        }
        if monitorCredentialBackend(vaultEnabled: YubiKeySecretVault.isEnabled) == .vault {
            return YubiKeySecretVault.save(data, service: monitorAuthService, account: account)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: monitorAuthService,
            kSecAttrAccount as String: account,
        ]
        return performSecurityCall {
            SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } == errSecSuccess
    }

    nonisolated static func monitorCredentialBackend(vaultEnabled: Bool) -> MonitorCredentialBackend {
        vaultEnabled ? .vault : .keychain
    }

    /// Read a credential owned by another local CLI/app without mutating it.
    nonisolated static func readExternalCredential(service: String, account: String? = nil) -> Data? {
        readExternalCredentialRecord(service: service, account: account)?.data
    }

    /// 判断是否属于由 CLI 工具（如 Claude Code、gh、Cursor、Factory）直接通过 /usr/bin/security 管理的钥匙串服务。
    /// 这类工具使用 `security add-generic-password -U` 保存密码时会将钥匙串项的分区列表重置为 apple-tool:，
    /// 导致应用进程内 SecItemCopyMatching 遭遇 errSecAuthFailed 或 errSecInteractionNotAllowed。
    nonisolated static func isCLIExternalService(service: String, account: String? = nil) -> Bool {
        if service == "Claude Code-credentials" || service.hasPrefix("Claude Code-credentials-") { return true }
        if service == "gh:github.com" || service.hasPrefix("gh:") { return true }
        if service == "cursor-access-token" { return true }
        if service == "Factory CLI" && account == "auth-encryption-key-security-cli" { return true }
        return false
    }

    /// 通过 /usr/bin/security 命令行工具读取钥匙串密码，以绕过 CLI 工具自行更新凭据后重置分区列表导致的访问权限丢失
    nonisolated static func readCLIKeychainCredential(
        service: String,
        account: String? = nil,
        timeout: TimeInterval = 10
    ) -> (data: Data, account: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty {
            args.append(contentsOf: ["-a", account])
        }
        args.append("-w")
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 防止子进程 stdout/stderr 管道缓冲区填满导致死锁，使用 DispatchGroup 在后台线程并发读取
        let group = DispatchGroup()
        let outputBuffer = CLIOutputBuffer()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputBuffer.append(data)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            Log.keychain("Failed to spawn /usr/bin/security for service \(service): \(error)")
            return nil
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            Log.keychain("/usr/bin/security timed out reading service: \(service)")
            return nil
        }

        _ = group.wait(timeout: .now() + 2)

        guard process.terminationStatus == 0 else {
            if process.terminationStatus != 44 {
                Log.keychain("/usr/bin/security failed for service \(service) with status \(process.terminationStatus)")
            }
            return nil
        }

        let rawOutput = outputBuffer.snapshot()
        guard let decodedData = decodeCLIPasswordOutput(rawOutput, service: service, account: account) else {
            return nil
        }

        return (decodedData, account ?? "")
    }

    /// 解析 `/usr/bin/security -w` 的输出：
    /// `security -w` 在内容包含非可打印字节（或包含非 ASCII UTF-8 字节）时会输出纯十六进制字符串。
    /// - 对于 Claude Code：仅在解出的十六进制有效且为以 `{` 或 `[` 开头的合法 UTF-8 JSON 时才采用 hex 解码，防止误判；
    /// - 对于 Factory CLI (auth-encryption-key-security-cli)：64 个十六进制字符解码为 32 字节的对称密钥；
    /// - 对于 gh / cursor-access-token：保留原始 UTF-8 字符串（去除首尾空白），防止纯十六进制格式的 Token 被错误解码损坏。
    nonisolated static func decodeCLIPasswordOutput(_ rawData: Data, service: String, account: String?) -> Data? {
        guard let outputString = String(data: rawData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !outputString.isEmpty else {
            return nil
        }

        // Factory CLI 的 auth-encryption-key-security-cli 是 32 字节的二进制密钥，在 security -w 下输出为 64 位十六进制
        if service == "Factory CLI" && account == "auth-encryption-key-security-cli" {
            if outputString.count == 64, let hexData = dataFromHexString(outputString) {
                return hexData
            }
            return Data(outputString.utf8)
        }

        // Claude Code 凭据：可能是原生 JSON 字符串，也可能因包含特殊字符被 security 转为十六进制
        if service == "Claude Code-credentials" || service.hasPrefix("Claude Code-credentials-") {
            if outputString.count % 2 == 0,
               let hexData = dataFromHexString(outputString),
               let jsonStr = String(data: hexData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               (jsonStr.hasPrefix("{") || jsonStr.hasPrefix("[")) {
                return hexData
            }
            return Data(outputString.utf8)
        }

        // 对于 gh:* 与 cursor-access-token 等普通文本凭据，直接作为 UTF-8 返回
        return Data(outputString.utf8)
    }

    /// 将十六进制字符串转为 Data
    nonisolated private static func dataFromHexString(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else { return nil }
            let byteString = hex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    /// 并发收集 CLI 子进程 stdout 输出的线程安全缓冲区，显式声明为 nonisolated 以避免默认 MainActor 隔离导致后台队列访问报错
    nonisolated private final class CLIOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(chunk)
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    nonisolated static func readExternalCredentialRecord(
        service: String,
        account: String? = nil
    ) -> (data: Data, account: String)? {
        // 如果是 CLI 工具管理的钥匙串项，先通过 /usr/bin/security 读取，避免分区丢失引发的权限错误
        if isCLIExternalService(service: service, account: account) {
            if let cliResult = readCLIKeychainCredential(service: service, account: account) {
                return cliResult
            }
        }

        let query = externalCredentialQuery(service: service, account: account)

        var unmanagedResult: Unmanaged<CFTypeRef>?
        let status = performSecurityCall {
            QuotioSecItemCopyMatchingWithoutInteraction(query as CFDictionary, &unmanagedResult)
        }
        // SecItemCopyMatching 遵循 Create 规则；C 兼容层只透传对象，不改变其所有权。
        let result = unmanagedResult?.takeRetainedValue()
        if status == errSecSuccess,
           let item = result as? [String: Any],
           let data = item[kSecValueData as String] as? Data,
           let resolvedAccount = item[kSecAttrAccount as String] as? String {
            return (data, resolvedAccount)
        }
        if status != errSecItemNotFound && status != errSecInteractionNotAllowed && status != errSecAuthFailed {
            Log.keychain("External keychain read failed (service: \(service)): \(status)")
        }
        return nil
    }

    nonisolated static func externalCredentialQuery(service: String, account: String? = nil) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// Update a known writable credential source after an OAuth refresh.
    nonisolated static func writeExternalCredential(_ data: Data, service: String, account: String) -> Bool {
        saveData(data, service: service, account: account)
    }

    nonisolated static func compareAndSwapExternalCredential(
        service: String,
        account: String,
        expectedData: Data,
        newData: Data
    ) -> Bool {
        guard readExternalCredentialRecord(service: service, account: account)?.data == expectedData else {
            return false
        }
        let query = externalCredentialUpdateQuery(service: service, account: account)
        let status = performSecurityCall {
            QuotioSecItemUpdateWithoutInteraction(
                query as CFDictionary,
                [kSecValueData as String: newData] as CFDictionary
            )
        }
        return status == errSecSuccess
    }

    nonisolated static func externalCredentialUpdateQuery(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    nonisolated private static func migrateData(from oldServices: [String], to newService: String, account: String) -> Data? {
        for oldService in oldServices {
            guard let data = readData(service: oldService, account: account) else { continue }
            if saveData(data, service: newService, account: account) {
                deleteData(service: oldService, account: account)
            }
            return data
        }
        return nil
    }

    nonisolated private static func migrateString(from oldServices: [String], to newService: String, account: String) -> String? {
        // Non-destructive read: validate UTF-8 before committing the destructive migration
        for oldService in oldServices {
            guard let data = readData(service: oldService, account: account) else { continue }
            guard let decoded = String(data: data, encoding: .utf8) else { continue }
            _ = migrateData(from: [oldService], to: newService, account: account)
            return decoded
        }
        return nil
    }


    nonisolated private static func saveData(_ data: Data, service: String, account: String) -> Bool {
        if YubiKeySecretVault.isEnabled {
            let existing = YubiKeySecretVault.readResult(service: service, account: account)
            guard allowsVaultOverwrite(existing) else {
                Log.keychain("Refusing to overwrite unreadable vault envelope (service: \(service), account: \(account))")
                return false
            }
            return YubiKeySecretVault.save(data, service: service, account: account)
        }
        return saveKeychainData(data, service: service, account: account)
    }

    /// Whether a vault write may proceed over whatever is already stored.
    ///
    /// A caller that could not read a secret cannot tell "absent" from "hardware
    /// key unavailable", so it may regenerate one and store it -- destroying the
    /// envelope that still holds the real value. `CLIProxyManager` does exactly
    /// this at construction. Refuse rather than roll a live credential back.
    /// `.absent` costs only a file-existence check, so first writes stay
    /// prompt-free; only an overwrite pays for a decrypt.
    nonisolated static func allowsVaultOverwrite(_ existing: YubiKeySecretVault.ReadResult) -> Bool {
        if case .unreadable = existing { return false }
        return true
    }

    nonisolated private static func saveKeychainData(_ data: Data, service: String, account: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = performSecurityCall {
            SecItemUpdate(
                identity as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ] as CFDictionary
            )
        }
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Log.keychain("Keychain update failed (service: \(service), account: \(account)): \(updateStatus)")
            return false
        }

        var query = identity
        query.merge([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }

        let status = performSecurityCall {
            SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess {
            return true
        }

        Log.keychain("Keychain save failed (service: \(service), account: \(account)): \(status)")
        return false
    }

    nonisolated private static func readData(service: String, account: String) -> Data? {
        if YubiKeySecretVault.isEnabled {
            let result = YubiKeySecretVault.readResult(service: service, account: account)
            if case let .success(data) = result { return data }
            // Only an absent envelope may be filled from a legacy Keychain copy.
            // An unreadable one means the hardware key is unavailable or the
            // envelope is bad, and overwriting it would roll the credential back.
            guard YubiKeySecretVault.shouldMigrateLegacy(result) else { return nil }
            // Move a legacy secret only after a complete encrypted write/read
            // round trip has succeeded.
            guard let legacy = readKeychainData(service: service, account: account),
                  YubiKeySecretVault.save(legacy, service: service, account: account),
                  case let .success(roundTripped) = YubiKeySecretVault.readResult(service: service, account: account),
                  roundTripped == legacy else { return nil }
            deleteKeychainData(service: service, account: account)
            return legacy
        }
        return readKeychainData(service: service, account: account)
    }

    nonisolated private static func readKeychainData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = performSecurityCall {
            SecItemCopyMatching(query as CFDictionary, &result)
        }

        if status == errSecSuccess {
            return result as? Data
        }

        if status != errSecItemNotFound {
            Log.keychain("Keychain read failed (service: \(service), account: \(account)): \(status)")
        }

        return nil
    }

    private static func readString(service: String, account: String) -> String? {
        guard let data = readData(service: service, account: account) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func deleteData(service: String, account: String) {
        if YubiKeySecretVault.isEnabled {
            YubiKeySecretVault.delete(service: service, account: account)
        }
        deleteKeychainData(service: service, account: account)
    }

    nonisolated private static func deleteKeychainData(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = performSecurityCall {
            SecItemDelete(query as CFDictionary)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.keychain("Keychain delete failed (service: \(service), account: \(account)): \(status)")
        }
    }

    nonisolated private static func performSecurityCall(
        _ operation: () -> OSStatus
    ) -> OSStatus {
        securityLock.lock()
        defer { securityLock.unlock() }
        return operation()
    }

    #if DEBUG
    /// 回归测试读取交互标志；实际钥匙串调用仍由 securityLock 串行保护。
    nonisolated static func legacyKeychainInteractionAllowedForTesting() -> Bool? {
        var allowed = false
        let status = performSecurityCall {
            QuotioGetLegacyKeychainInteractionAllowed(&allowed)
        }
        return status == errSecSuccess ? allowed : nil
    }
    #endif
}
