import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 验证配置生成、多语言契约与子代理配置规则，确保界面状态不改写底层草稿。
@MainActor
final class ClaudeConfigurationViewTests: XCTestCase {

    /// 验证编译进应用的资源，防止新增目录提示在运行时显示为原始 key。
    /// 不修改用户语言偏好，四种应用语言分别从其真实 lproj 资源包读取。
    func testModelCatalogNoticesHaveBundledTranslationsForEveryAppLanguage() {
        let keys = ["unconfirmed", "currentConfiguration", "accountsChanged"].map { "agents.models." + $0 }
            + ["agents.modelMapping.oneMillion", "agents.modelMapping.oneMillion.info", "agents.modelMapping.oneMillion.declared"]
        for language in AppLanguage.allCases {
            for key in keys {
                let value = language.bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "\(language.rawValue) 缺少 \(key)")
                XCTAssertFalse(value.isEmpty)
            }
        }
        XCTAssertEqual(AppLanguage.chinese.bundle.localizedString(forKey: keys[0], value: nil, table: nil), "未在当前目录确认")
    }

    /// 直接验证打包后的四种应用语言资源，避免源码中存在 key、运行时却原样显示 key 的漏检。
    /// 不修改 LanguageManager 或用户偏好；模型 ID 保持原文，仅兼容提示及计数使用本地化。
    func testCompatibilityNoticesHaveBundledTranslationsForEveryAppLanguage() throws {
        let keys = ["migrated", "unresolved", "conflicts", "requiresJSON", "unreadable"].map {
            "agents.claudeCompatibility." + $0
        }
        for language in AppLanguage.allCases {
            let bundle = language.bundle
            XCTAssertTrue(bundle.bundlePath.hasSuffix("\(language.rawValue).lproj"), "应使用目标语言的实际资源包")
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "\(language.rawValue) 缺少 \(key)")
                XCTAssertFalse(value.isEmpty)
            }
            let format = bundle.localizedString(forKey: keys[0], value: nil, table: nil)
            let rendered = String(format: format, 3)
            XCTAssertTrue(rendered.contains("3"), "迁移数量必须实际显示")
            XCTAssertFalse(rendered.contains("%ld"))
        }
        XCTAssertEqual(AppLanguage.chinese.bundle.localizedString(forKey: keys[1], value: nil, table: nil),
                       "当前模型目录未找到以下旧模型，已保留原值：")
    }

    func testShowingExistingNativeAndLegacyConfigurationsDoesNotModifyTheirData() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = AgentConfigurationService(homeDirectory: home)
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "isolated-test-key")
        config.modelSlots = [.opus: "glm-5.3", .fable: "codex/gpt-6-astra", .sonnet: "gemini-3.8-flash-high", .haiku: "gpt-6-luna"]
        config.claudeModel1M = [.opus: true, .fable: true]
        config.claudeModelDisplayNames = [.sonnet: "Sonnet · 存量名称"]
        config.claudeModel = "sonnet"
        config.claudeSubagentModel = "fable"
        config.claudeSubagentModelForce = "1"
        let menu: [String: Any] = ["futureMenu": ["keep": true], "options": [
            ["model": "codex/gpt-6.1-sol", "label": "GPT-6.1-Sol · Codex", "description": "work@example.com · via magpie"],
            ["model": "zhipu/glm-5.3[1m]", "label": "GLM-5.3 · Zhipu GLM", "description": "工作账号 · via magpie"],
            ["model": "custom/model", "label": "用户独立名称", "description": "原有独立说明保持不变"]]]
        config.claudeModelPicker = .read(menu)
        config.claudeModelPicker.shouldWrite = false
        let models = [
            AvailableModel(id: "glm-5.3", name: "glm-5.3", provider: "zhipu", isDefault: false, displayPlatform: "zhipu"),
            AvailableModel(id: "gemini-3.8-flash-high", name: "gemini-3.8-flash-high", provider: "google", isDefault: false, displayPlatform: "google"),
            AvailableModel(id: "gpt-6-luna", name: "gpt-6-luna", provider: "codex", isDefault: false, displayPlatform: "codex")]

        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.selectedAgent = .claudeCode
        viewModel.availableModels = models
        for kind in ["existing", "native", "legacy"] {
            var shown = config
            if kind != "existing" {
                shown.claudeModelPicker = .roleDefaults(mode: .native)
                shown.claudeModelPicker.shouldWrite = false
                shown.claudeModelDisplayNames = nil
                shown.claudeSubagentModel = nil
            }
            if kind == "legacy" {
                shown.modelSlots.removeValue(forKey: .fable)
                shown.claudeModel1M.removeValue(forKey: .fable)
            }
            viewModel.currentConfiguration = shown
            let before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shown)) as? NSDictionary
            let after = try XCTUnwrap(viewModel.currentConfiguration)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as? NSDictionary,
                before, "显示 \(kind) 配置不能改写旧菜单、名称、Fable 或子代理设置")
        }
    }

    /// 检查子代理规则：继承与指定模式、强制开关及其对草稿的保护
    func testSubagentDefaultRulesAndForceOptions() async throws {
        for (forced, model) in [
            (true, "inherit"),
            (false, "inherit"),
            (true, "fable")
        ] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeSubagent-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: home) }
            let viewModel = AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: home))
            var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fixture-only-key")
            config.claudeSubagentModel = model
            config.claudeSubagentModelForce = forced ? "1" : ""
            viewModel.currentConfiguration = config
            let before = try JSONEncoder().encode(config)

            if model == "inherit" {
                XCTAssertNil(viewModel.currentConfiguration?.claudeSubagentSelector)
            } else {
                XCTAssertEqual(viewModel.currentConfiguration?.claudeSubagentSelector, model)
            }
            XCTAssertEqual(viewModel.currentConfiguration?.claudeSubagentSettings.isForced, forced)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(viewModel.currentConfiguration))) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: before) as? NSDictionary)
        }
    }
}
