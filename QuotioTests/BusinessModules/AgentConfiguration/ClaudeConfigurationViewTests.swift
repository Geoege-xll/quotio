import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 配置生成与兼容由领域测试验证；这里只保留生产视图显示时不改写配置的独有边界。
/// 使用隔离 home 和单一主题，不修改语言偏好，不导出 PNG 或 CLI 临时配置。
@MainActor
final class ClaudeConfigurationViewTests: XCTestCase {
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
            let root = VStack(spacing: 16) {
                ClaudeModelMappingView(viewModel: viewModel, onOneMillionChange: {})
                ClaudeAdvancedSettingsSection(viewModel: viewModel, onSettingsChange: {})
            }.padding(20).environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 1200)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            window.close()
            let after = try XCTUnwrap(viewModel.currentConfiguration)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as? NSDictionary,
                before, "显示 \(kind) 配置不能改写旧菜单、名称、Fable 或子代理设置")
        }
    }
}
