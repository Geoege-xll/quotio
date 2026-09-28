//
//  CustomProviderService.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Service for managing custom AI provider configurations.
//  Handles CRUD operations, persistence, and YAML config generation.
//

import Foundation
import CryptoKit
import Yams

@MainActor
@Observable
final class CustomProviderService {
    static let shared = CustomProviderService()
    
    // MARK: - Properties
    
    private(set) var providers: [CustomProvider] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private var providersLoadFailed = false
    private var providersStorageMissing = false
    
    private let storageKey = "customProviders"
    private let v8SyncedFieldsKey = "customProvidersV8SyncedFields"
    private let fileManager = FileManager.default

    /// 只记录 Quotio 已同步的字段身份；密钥仅保存 SHA-256 摘要，不在偏好中复制明文。
    /// 旧快照缺少 keyDigests 时宁可保留未知密钥，也不能把解码失败误当成用户删除。
    struct V8SyncedFields: Codable {
        let id: UUID
        let models: [V8ModelIdentity]
        let headerNames: [String]
        var keyDigests: [String]? = nil
    }

    /// 用稳定的界面 ID 追踪本应用写入的单条模型，避免删除同名的手工别名。
    struct V8ModelIdentity: Codable {
        let id: UUID
        let name: String
        let alias: String
    }

    /// 摘要仅用于辨认上一次由 Quotio 写入的密钥；真正的密钥始终留在原配置与本地服务商记录中。
    private func keyDigest(_ apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Initialization
    
    private init() {
        loadProviders()
    }
    
    // MARK: - CRUD Operations
    
    /// Add a new custom provider
    func addProvider(_ provider: CustomProvider) {
        var newProvider = provider
        newProvider = CustomProvider(
            id: provider.id,
            name: provider.name,
            type: provider.type,
            baseURL: provider.baseURL,
            prefix: provider.prefix,
            apiKeys: provider.apiKeys,
            models: provider.models,
            headers: provider.headers,
            limitToSelectedModels: provider.limitToSelectedModels,
            isEnabled: provider.isEnabled,
            createdAt: Date(),
            updatedAt: Date()
        )
        providers.append(newProvider)
        saveProviders()
    }
    
    /// Update an existing custom provider
    func updateProvider(_ provider: CustomProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else {
            lastError = "Provider not found"
            return
        }
        
        var updatedProvider = provider
        updatedProvider = CustomProvider(
            id: provider.id,
            name: provider.name,
            type: provider.type,
            baseURL: provider.baseURL,
            prefix: provider.prefix,
            apiKeys: provider.apiKeys,
            models: provider.models,
            headers: provider.headers,
            limitToSelectedModels: provider.limitToSelectedModels,
            isEnabled: provider.isEnabled,
            createdAt: providers[index].createdAt,
            updatedAt: Date()
        )
        providers[index] = updatedProvider
        saveProviders()
    }
    
    /// Delete a custom provider by ID
    func deleteProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        saveProviders()
    }
    
    /// Toggle provider enabled state
    func toggleProvider(id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        
        let provider = providers[index]
        let updatedProvider = CustomProvider(
            id: provider.id,
            name: provider.name,
            type: provider.type,
            baseURL: provider.baseURL,
            prefix: provider.prefix,
            apiKeys: provider.apiKeys,
            models: provider.models,
            headers: provider.headers,
            limitToSelectedModels: provider.limitToSelectedModels,
            isEnabled: !provider.isEnabled,
            createdAt: provider.createdAt,
            updatedAt: Date()
        )
        providers[index] = updatedProvider
        saveProviders()
    }
    
    /// Get a provider by ID
    func getProvider(id: UUID) -> CustomProvider? {
        providers.first { $0.id == id }
    }
    
    /// Get all enabled providers
    var enabledProviders: [CustomProvider] {
        providers.filter(\.isEnabled)
    }
    
    /// Get providers grouped by type
    var providersByType: [CustomProviderType: [CustomProvider]] {
        Dictionary(grouping: providers, by: \.type)
    }
    
    // MARK: - Persistence
    
    private func loadProviders() {
        isLoading = true
        defer { isLoading = false }
        
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            providers = []
            providersLoadFailed = false
            providersStorageMissing = true
            return
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            providers = try decoder.decode([CustomProvider].self, from: data)
            providersLoadFailed = false
            providersStorageMissing = false
        } catch {
            lastError = "Failed to load providers: \(error.localizedDescription)"
            providers = []
            providersLoadFailed = true
        }
    }
    
    private func saveProviders() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(providers)
            UserDefaults.standard.set(data, forKey: storageKey)
            // 用户在界面完成一次明确保存后，新记录已能正常解码，可解除之前的保护状态。
            providersLoadFailed = false
            providersStorageMissing = false
            lastError = nil
        } catch {
            lastError = "Failed to save providers: \(error.localizedDescription)"
        }
    }
    
    /// Force reload providers from storage
    func reloadProviders() {
        loadProviders()
    }
    
    // MARK: - Config Generation
    
    /// Generate YAML config sections for all enabled custom providers
    func generateYAMLConfig() -> String {
        enabledProviders.toYAMLSections()
    }
    
    /// Update the CLIProxyAPI config file to include custom providers
    func syncToConfigFile(configPath: String) throws {
        guard fileManager.fileExists(atPath: configPath) else {
            throw CustomProviderError.configFileNotFound
        }
        
        var content = try String(contentsOfFile: configPath, encoding: .utf8)
        if let root = try Yams.load(yaml: content) as? [String: Any],
           CPAConfigLayout.isMigratedV8(root) {
            // v8 只能经官方局部配置接口写入；直接序列化整份 YAML 会清除用户注释。
            throw CustomProviderError.invalidProvider("CPA 8 服务商需通过管理接口同步")
        }
        
        // Remove existing custom provider sections
        content = removeCustomProviderSections(from: content)
        
        // Append new custom provider sections
        let customProviderYAML = generateYAMLConfig()
        if !customProviderYAML.isEmpty {
            content += "\n# Custom Providers (managed by Quotio)\n"
            content += customProviderYAML
        }
        
        try content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// 为 CPA 8 生成局部 PATCH，仅替换实际变化的凭据族数组，保留文件其它部分的注释。
    /// 首次接管同名同密钥的旧版分组时以原分组为基础，保留优先级、单密钥覆盖等高级字段。
    func makeV8ProviderPatch(
        configPath: String,
        legacyOwnedProviderIDs: Set<UUID> = [],
        legacyOwnedKeys: [String: Set<String>] = [:],
        managedProviders: [CustomProvider]? = nil
    ) throws -> Data? {
        // 本地列表解码失败不等于用户删除了服务商；禁止因此删除 CPA 中仍可用的凭据。
        guard !providersLoadFailed else {
            throw CustomProviderError.invalidProvider("本地服务商数据读取失败，已暂停 CPA 8 同步以保护现有凭据")
        }
        // 没有存储记录不能推断用户主动删除了所有服务商；保留可能仍在 CPA 中工作的旧组。
        if providersStorageMissing && providers.isEmpty { return nil }
        let records = UserDefaults.standard.data(forKey: v8SyncedFieldsKey)
            .flatMap { try? JSONDecoder().decode([V8SyncedFields].self, from: $0) } ?? []
        let previous = records.reduce(into: [UUID: V8SyncedFields]()) { $0[$1.id] = $1 }
        return try makeV8ProviderPatch(
            configPath: configPath, managedProviders: managedProviders ?? providers,
            previouslySynced: previous,
            legacyOwnedProviderIDs: legacyOwnedProviderIDs,
            legacyOwnedKeys: legacyOwnedKeys
        )
    }

    /// 仅在 CPA 确认接收 PATCH 后更新同步快照；失败时保留旧快照供重试计算差异。
    func markV8ProvidersSynced(_ managedProviders: [CustomProvider]? = nil) throws {
        let records = (managedProviders ?? providers).map {
            V8SyncedFields(id: $0.id, models: $0.models.map {
                V8ModelIdentity(id: $0.id, name: $0.name, alias: $0.effectiveAlias)
            },
                           headerNames: $0.effectiveHeaders.map(\.key),
                           keyDigests: $0.isEnabled ? $0.apiKeys.map { keyDigest($0.apiKey) } : [])
        }
        UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: v8SyncedFieldsKey)
    }

    /// 只把旧文件中位于 Quotio 专属注释区块的服务商视为可接管对象。
    /// 单凭迁移后的名称和密钥相同无法区分手工配置，误认后未来删除会丢失用户分组。
    func legacyOwnedProviderIDs(in yaml: String, managedProviders: [CustomProvider]? = nil) -> Set<UUID> {
        guard let marker = yaml.range(of: "# Custom Providers (managed by Quotio)"),
              let block = try? Yams.load(yaml: String(yaml[marker.upperBound...])) as? [String: Any] else {
            return []
        }
        let candidates = managedProviders ?? providers
        return Set(candidates.compactMap { provider -> UUID? in
            // 旧版生成器只输出当时启用的服务商，但用户可能在服务停止期间将其停用；
            // 此时磁盘仍留有旧区块，归属必须以磁盘内容而非当前开关状态为准。
            let groups = block[provider.type.yamlSectionKey] as? [[String: Any]] ?? []
            let configuredKeys = Set(provider.apiKeys.map(\.apiKey))
            guard !configuredKeys.isEmpty else { return nil }
            // 同族且同密钥的两个本地对象无法从旧 YAML 唯一对应到各自分组；一律不自动接管。
            let ambiguous = candidates.contains {
                $0.id != provider.id && $0.type.yamlSectionKey == provider.type.yamlSectionKey
                    && Set($0.apiKeys.map(\.apiKey)) == configuredKeys
            }
            guard !ambiguous else { return nil }
            let found: Bool
            if provider.type == .openaiCompatibility || provider.type == .clinePass {
                found = groups.contains { group in
                    let keys = (group["api-key-entries"] as? [[String: Any]] ?? [])
                        .compactMap { $0["api-key"] as? String }
                    return group["name"] as? String == provider.name && Set(keys) == configuredKeys
                }
            } else {
                let keys = Set(groups.compactMap { $0["api-key"] as? String })
                found = configuredKeys.isSubset(of: keys)
            }
            return found ? provider.id : nil
        })
    }

    /// 迁移前读取 Quotio 专属旧区块的密钥：已删除的本地对象不再有 ID，只能借此
    /// 在官方迁移后辨认其残留凭据。只保存于本轮调用内，绝不写入偏好或日志。
    func legacyOwnedKeys(in yaml: String) -> [String: Set<String>] {
        guard let marker = yaml.range(of: "# Custom Providers (managed by Quotio)"),
              let block = try? Yams.load(yaml: String(yaml[marker.upperBound...])) as? [String: Any] else {
            return [:]
        }
        var result: [String: Set<String>] = [:]
        for type in CustomProviderType.allCases {
            let groups = block[type.yamlSectionKey] as? [[String: Any]] ?? []
            let keys: [String]
            if type == .openaiCompatibility || type == .clinePass {
                keys = groups.flatMap { ($0["api-key-entries"] as? [[String: Any]] ?? [])
                    .compactMap { $0["api-key"] as? String } }
            } else {
                keys = groups.compactMap { $0["api-key"] as? String }
            }
            result[v8Family(for: type), default: []].formUnion(keys)
        }
        return result
    }

    /// 显式传入服务商列表，供迁移测试在临时文件上验证，不读取或改动当前用户的账号数据。
    func makeV8ProviderPatch(
        configPath: String,
        managedProviders: [CustomProvider],
        previouslySynced: [UUID: V8SyncedFields] = [:],
        legacyOwnedProviderIDs: Set<UUID> = [],
        legacyOwnedKeys: [String: Set<String>] = [:]
    ) throws -> Data? {
        let yaml = try String(contentsOfFile: configPath, encoding: .utf8)
        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              CPAConfigLayout.isMigratedV8(root) else {
            throw CustomProviderError.invalidProvider("CPA 配置尚未完成 v8 迁移")
        }
        let families = root["api-keys"] as? [String: Any] ?? [:]
        let marker = #" \(Quotio [0-9A-Fa-f-]{36}\)$"#
        var changedFamilies: [String: Any] = [:]
        for family in ["openai-compatibility", "claude", "gemini", "codex"] {
            if let existing = families[family], !(existing is [[String: Any]]) {
                throw CustomProviderError.invalidProvider("CPA 8 的 \(family) 分组结构无效，已拒绝覆盖")
            }
            let originalGroups = families[family] as? [[String: Any]] ?? []
            var groups: [[String: Any]] = []
            for var group in originalGroups {
                let name = group["name"] as? String ?? ""
                guard let markerRange = name.range(of: marker, options: .regularExpression),
                      let former = previouslySynced.first(where: {
                          name.hasSuffix("(Quotio \($0.key.uuidString))")
                      }),
                      !managedProviders.contains(where: {
                          v8Family(for: $0.type) == family && $0.id == former.key
                      }) else {
                    groups.append(group)
                    continue
                }
                // 用户删除了本地服务商时，只能撤销上次成功同步的密钥。旧快照没有摘要，
                // 或该分组后来被用户手工加过密钥时，都不能把整组凭据直接删除。
                guard let digests = former.value.keyDigests else {
                    // 升级前的同步快照没有密钥摘要；保留整组并继续启动，不让一个无法
                    // 判定归属的旧组阻断其他服务商与代理。用户可在 CPA 管理页手工处理。
                    NSLog("[CustomProviderService] 保留旧快照无法确认归属的服务商组：%@", former.key.uuidString)
                    groups.append(group)
                    continue
                }
                let owned = Set(digests)
                guard var keys = group["keys"] as? [[String: Any]] else {
                    throw CustomProviderError.invalidProvider("CPA 8 的 \(family) 密钥结构无效，已拒绝删除服务商分组")
                }
                keys.removeAll { entry in
                    guard let key = entry["api-key"] as? String else { return false }
                    return owned.contains(keyDigest(key))
                }
                if !keys.isEmpty {
                    group["keys"] = keys
                    // 剩余密钥不归 Quotio 管理，移除名称标记，后续同步不会再碰它们。
                    let plainName = name[..<markerRange.lowerBound].trimmingCharacters(in: .whitespaces)
                    if plainName.isEmpty { group.removeValue(forKey: "name") }
                    else { group["name"] = plainName }
                    groups.append(group)
                }
            }
            // 本地对象在服务停止期间被删除或移走了单条密钥，旧 Quotio 区块仍可能
            // 在官方迁移后生成有效分组。只从唯一匹配的未标记组撤销这些旧密钥；
            // 若同一密钥出现于多个组，归属有歧义，宁可中止迁移也不能误删手工凭据。
            let configuredKeys = Set(managedProviders.filter { v8Family(for: $0.type) == family }
                .flatMap { $0.apiKeys.map(\.apiKey) })
            let orphanedKeys = (legacyOwnedKeys[family] ?? []).subtracting(configuredKeys)
            var emptiedOrphanIndices = Set<Int>()
            for key in orphanedKeys {
                let matches = groups.indices.filter { index in
                    let name = groups[index]["name"] as? String ?? ""
                    guard name.range(of: marker, options: .regularExpression) == nil else { return false }
                    return (groups[index]["keys"] as? [[String: Any]] ?? [])
                        .contains { $0["api-key"] as? String == key }
                }
                guard matches.count <= 1 else {
                    throw CustomProviderError.invalidProvider("旧版 \(family) 密钥在多个分组出现，已拒绝自动清理")
                }
                if let index = matches.first, var keys = groups[index]["keys"] as? [[String: Any]] {
                    keys.removeAll { $0["api-key"] as? String == key }
                    groups[index]["keys"] = keys
                    if keys.isEmpty { emptiedOrphanIndices.insert(index) }
                }
            }
            groups = groups.enumerated().compactMap { emptiedOrphanIndices.contains($0.offset) ? nil : $0.element }
            let preexistingGroupCount = groups.count
            var claimedLegacyIndices = Set<Int>()
            var mergedLegacyIndices = Set<Int>()

            for provider in managedProviders where v8Family(for: provider.type) == family {
                let markedName = managedName(for: provider)
                let markedMatch = groups.firstIndex {
                    ($0["name"] as? String ?? "").hasSuffix("(Quotio \(provider.id.uuidString))")
                }
                let requestedKeys = Set(provider.apiKeys.map(\.apiKey))
                // v7 的 Claude/Gemini/Codex 生成器按密钥拆成多个条目，上游迁移器也会
                // 保留为多个组。只有旧文件的专属区块证明归属、且这些组恰好覆盖全部密钥，
                // 才能合并；相交但不完整或包含重复密钥时拒绝同步，避免复制凭据。
                let legacyMatches: [Int] = markedMatch == nil && legacyOwnedProviderIDs.contains(provider.id)
                    ? (0..<preexistingGroupCount).filter { index in
                        guard !claimedLegacyIndices.contains(index), !mergedLegacyIndices.contains(index),
                              (groups[index]["name"] as? String ?? "").range(of: marker, options: .regularExpression) == nil else {
                            return false
                        }
                        let keys = Set((groups[index]["keys"] as? [[String: Any]] ?? [])
                            .compactMap { $0["api-key"] as? String })
                        return !keys.isEmpty && keys.isSubset(of: requestedKeys)
                    } : []
                let legacyKeys = legacyMatches.flatMap { index in
                    (groups[index]["keys"] as? [[String: Any]] ?? []).compactMap { $0["api-key"] as? String }
                }
                if !legacyMatches.isEmpty {
                    guard Set(legacyKeys) == requestedKeys, legacyKeys.count == requestedKeys.count else {
                        throw CustomProviderError.invalidProvider("旧版 \(provider.name) 密钥分组无法安全合并，请检查重复或缺失的密钥")
                    }
                    let settings = try legacyMatches.map { index -> Data in
                        var comparable = groups[index]
                        comparable.removeValue(forKey: "name")
                        comparable.removeValue(forKey: "keys")
                        // v7 的单密钥代理被上游提升为组代理，各组代理允许不同。
                        comparable.removeValue(forKey: "proxy-url")
                        return try JSONSerialization.data(withJSONObject: comparable, options: [.sortedKeys])
                    }
                    guard settings.dropFirst().allSatisfy({ $0 == settings[0] }) else {
                        throw CustomProviderError.invalidProvider("旧版 \(provider.name) 密钥分组设置不一致，已停止自动合并")
                    }
                    claimedLegacyIndices.formUnion(legacyMatches)
                    mergedLegacyIndices.formUnion(legacyMatches.dropFirst())
                }
                let match = markedMatch ?? legacyMatches.first
                var group = match.map { groups[$0] } ?? [:]
                let previous = previouslySynced[provider.id]
                if match != nil && !(group["keys"] is [[String: Any]]) {
                    throw CustomProviderError.invalidProvider("CPA 8 的 \(family) 密钥结构无效，已拒绝覆盖服务商分组")
                }
                var oldKeys = group["keys"] as? [[String: Any]] ?? []
                if markedMatch == nil, !legacyMatches.isEmpty {
                    oldKeys += legacyMatches.dropFirst().flatMap { groups[$0]["keys"] as? [[String: Any]] ?? [] }
                    // 上游将 v7 的每条 proxy-url 提升为组属性；接管后按 UI 的单密钥设置
                    // 重新写入，防止用户清空代理时仍继承旧的组代理。
                    group.removeValue(forKey: "proxy-url")
                }
                let currentDigests = Set(provider.apiKeys.map { keyDigest($0.apiKey) })
                let ownedDigests = Set(previous?.keyDigests ?? []).union(currentDigests)
                let unmanagedKeys = oldKeys.filter { entry in
                    guard let key = entry["api-key"] as? String else { return true }
                    return !ownedDigests.contains(keyDigest(key))
                }
                if !provider.isEnabled {
                    // CPA 8 的 Claude/Gemini/Codex 组不接受 disabled 字段；停用意味着
                    // 从配置移除本应用管理的密钥，手工加入的密钥则拆成独立组保留。
                    if !unmanagedKeys.isEmpty {
                        group["keys"] = unmanagedKeys
                        let plainName = provider.name.trimmingCharacters(in: .whitespaces)
                        if plainName.isEmpty { group.removeValue(forKey: "name") }
                        else { group["name"] = plainName }
                        group.removeValue(forKey: "disabled")
                        if let match { groups[match] = group }
                        else { groups.append(group) }
                    } else if let match {
                        mergedLegacyIndices.insert(match)
                    }
                    continue
                }
                group["name"] = markedName
                group.removeValue(forKey: "disabled")
                // 未见于同步快照的密钥可能由用户通过 CPA 管理页添加；保留其完整字段。
                // 按原顺序留下手工密钥和仍在 UI 中的密钥，避免改变 CPA 的轮转顺序；
                // 对 UI 管理项只覆盖代理地址，新加入的密钥再追加到末尾。
                var nextKeys = oldKeys.filter { entry in
                    guard let key = entry["api-key"] as? String else { return true }
                    let digest = keyDigest(key)
                    return !ownedDigests.contains(digest) || currentDigests.contains(digest)
                }
                for key in provider.apiKeys {
                    let index = nextKeys.firstIndex { $0["api-key"] as? String == key.apiKey }
                    var entry = index.map { nextKeys[$0] } ?? [:]
                    entry["api-key"] = key.apiKey
                    if let proxy = key.proxyURL, !proxy.isEmpty { entry["proxy-url"] = proxy }
                    else { entry.removeValue(forKey: "proxy-url") }
                    if let index { nextKeys[index] = entry }
                    else { nextKeys.append(entry) }
                }
                group["keys"] = nextKeys
                if !provider.baseURL.isEmpty,
                   (family == "openai-compatibility" || family == "codex" || provider.baseURL != provider.type.defaultBaseURL) {
                    group["base-url"] = provider.baseURL
                } else {
                    group.removeValue(forKey: "base-url")
                }
                if let prefix = provider.prefix, !prefix.isEmpty {
                    group["prefix"] = prefix
                } else {
                    group.removeValue(forKey: "prefix")
                }
                var models = group["models"] as? [[String: Any]] ?? []
                let currentModelIDs = Set(provider.models.map(\.id))
                let removedModels = (previous?.models ?? []).filter { !currentModelIDs.contains($0.id) }
                models.removeAll { entry in
                    removedModels.contains {
                        $0.name == entry["name"] as? String && $0.alias == entry["alias"] as? String
                    }
                }
                for model in provider.models {
                    let prior = previous?.models.first { $0.id == model.id }
                    let index = models.firstIndex {
                        $0["name"] as? String == model.name && $0["alias"] as? String == model.effectiveAlias
                    } ?? models.firstIndex {
                        guard let prior else { return false }
                        return $0["name"] as? String == prior.name && $0["alias"] as? String == prior.alias
                    } ?? models.firstIndex {
                        // 无同步快照的首次接管才按上游名称寻找旧条目。
                        previous == nil && $0["name"] as? String == model.name
                    }
                    if let index {
                        models[index]["name"] = model.name
                        models[index]["alias"] = model.effectiveAlias
                    } else {
                        models.append(["name": model.name, "alias": model.effectiveAlias])
                    }
                }
                // 首次接管旧组时，模型中的额外条目可能是用户手工添加的，故不凭空删除。
                // 已标记组只清理上次快照记录的模型，保留其它模型及其高级字段。
                if models.isEmpty { group.removeValue(forKey: "models") }
                else { group["models"] = models }

                var headers = group["headers"] as? [String: String] ?? [:]
                let currentHeaderNames = Set(provider.effectiveHeaders.map(\.key))
                let removedHeaderNames = Set(previous?.headerNames ?? []).subtracting(currentHeaderNames)
                for name in removedHeaderNames { headers.removeValue(forKey: name) }
                for header in provider.effectiveHeaders { headers[header.key] = header.value }
                if headers.isEmpty { group.removeValue(forKey: "headers") }
                else {
                    group["headers"] = headers
                }
                if let match { groups[match] = group } else { groups.append(group) }
            }
            groups = groups.enumerated().compactMap { mergedLegacyIndices.contains($0.offset) ? nil : $0.element }
            let before = try JSONSerialization.data(withJSONObject: originalGroups, options: [.sortedKeys])
            let after = try JSONSerialization.data(withJSONObject: groups, options: [.sortedKeys])
            if before != after { changedFamilies[family] = groups }
        }
        guard !changedFamilies.isEmpty else { return nil }
        // CPA 8 的 /config 虽然先检查 JSON 有效性，实际却用 YAML 解析器读取正文。
        // Foundation 默认把 base-url 中的斜杠编码为 \/；这是合法 JSON，但上游
        // YAML 解析器会返回 invalid_body。保留普通斜杠，确保 URL 仍能被 CPA 接受。
        return try JSONSerialization.data(
            withJSONObject: ["api-keys": changedFamilies],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func managedName(for provider: CustomProvider) -> String {
        "\(provider.name) (Quotio \(provider.id.uuidString))"
    }

    /// 把 UI 保留的服务商类型映射到 CPA 8 的凭据族；GLM 与 ClinePass 使用 OpenAI 兼容执行器。
    private func v8Family(for type: CustomProviderType) -> String {
        switch type {
        case .claudeCompatibility: return "claude"
        case .geminiCompatibility: return "gemini"
        case .codexCompatibility: return "codex"
        case .openaiCompatibility, .clinePass, .glmCompatibility: return "openai-compatibility"
        }
    }
    
    /// Remove custom provider sections from config content.
    /// Internal (not private) so unit tests can verify strip/re-append round-trips.
    func removeCustomProviderSections(from content: String) -> String {
        var result = content
        
        // Derive and deduplicate the CLIProxyAPI section keys managed by custom providers.
        let customProviderKeys = Set(CustomProviderType.allCases.map(\.yamlSectionKey))
            .sorted()
            .map { "\($0):" }
        
        // Remove marker comment and everything after it that belongs to custom providers
        if let markerRange = result.range(of: "# Custom Providers (managed by Quotio)") {
            // Find the end of custom providers section (next top-level key or end of file)
            let afterMarker = result[markerRange.upperBound...]
            
            var endIndex = result.endIndex
            
            // Look for any non-custom-provider top-level key
            let topLevelKeyPattern = #"(?m)^[a-z][\w-]*:"#
            if let regex = try? NSRegularExpression(pattern: topLevelKeyPattern, options: []) {
                let searchRange = NSRange(afterMarker.startIndex..<afterMarker.endIndex, in: result)
                let matches = regex.matches(in: result, options: [], range: searchRange)
                
                for match in matches {
                    if let range = Range(match.range, in: result) {
                        let key = String(result[range])
                        if !customProviderKeys.contains(key) {
                            endIndex = range.lowerBound
                            break
                        }
                    }
                }
            }
            
            // Remove the custom providers section
            result.removeSubrange(markerRange.lowerBound..<endIndex)
        }
        
        // Also remove standalone custom provider sections that might exist without marker
        for key in customProviderKeys {
            result = removeYAMLSection(key, from: result)
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Remove a top-level YAML section by key
    private func removeYAMLSection(_ key: String, from content: String) -> String {
        var result = content
        
        // Pattern to match the section start
        guard let startRange = result.range(of: "\n\(key)") ?? result.range(of: key) else {
            return result
        }
        
        guard startRange.upperBound < result.endIndex else {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
            return result
        }
        
        let searchStart = result.index(after: startRange.upperBound)
        guard searchStart < result.endIndex else {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
            return result
        }
        
        // Find the next top-level key (line starting with non-whitespace followed by colon)
        let afterSection = result[searchStart...]
        let pattern = #"(?m)^[a-z][\w-]*:"#
        
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let firstMatch = regex.firstMatch(in: result, options: [], range: NSRange(afterSection.startIndex..<afterSection.endIndex, in: result)),
           let matchRange = Range(firstMatch.range, in: result) {
            result.removeSubrange(startRange.lowerBound..<matchRange.lowerBound)
        } else {
            // No more top-level keys, remove to end
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
        }
        
        return result
    }
    
    // MARK: - Validation
    
    /// Validate a provider before saving
    func validateProvider(_ provider: CustomProvider) -> [String] {
        var errors = provider.validate()
        
        // Check for duplicate names (excluding current provider if updating)
        let existingNames = providers
            .filter { $0.id != provider.id }
            .map { $0.name.lowercased() }
        
        if existingNames.contains(provider.name.lowercased()) {
            errors.append("A provider with this name already exists")
        }
        
        return errors
    }
    
    // MARK: - Import/Export
    
    /// Export providers to JSON data
    func exportProviders() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(providers)
    }
    
    /// Import providers from JSON data
    func importProviders(from data: Data, merge: Bool = true) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importedProviders = try decoder.decode([CustomProvider].self, from: data)
        
        if merge {
            // Merge: add new providers, update existing ones by ID
            for imported in importedProviders {
                if let existingIndex = providers.firstIndex(where: { $0.id == imported.id }) {
                    providers[existingIndex] = imported
                } else {
                    providers.append(imported)
                }
            }
        } else {
            // Replace all providers
            providers = importedProviders
        }
        
        saveProviders()
    }
}

// MARK: - Errors

enum CustomProviderError: LocalizedError {
    case configFileNotFound
    case invalidProvider(String)
    case saveError(String)
    
    var errorDescription: String? {
        switch self {
        case .configFileNotFound:
            return "Config file not found"
        case .invalidProvider(let message):
            return "Invalid provider: \(message)"
        case .saveError(let message):
            return "Failed to save: \(message)"
        }
    }
}
