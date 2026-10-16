import AppKit
import SwiftUI
import Vision
import XCTest
@testable import QuotioPlus

/// 仅覆盖领域测试不能验证的页面输出：失败页保留重试、迟到密钥触发手动预览。
/// 当前 SwiftUI 原生测试宿主不提供完整 AX 子树，沿用全模型弹窗的本地绘制＋Vision 验证；
/// 不修改系统辅助功能设置，不请求屏幕录制，也不操作当前运行的生产窗口。
@MainActor
final class AgentConfigurationRetryViewTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentRetryView-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func show(_ vm: AgentSetupViewModel) async throws -> NSWindow {
        vm.configurationMode = .manual
        let host = NSHostingView(rootView: AgentConfigSheet(viewModel: vm, agent: .openCode).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        // 观察 onAppear 已执行后再切换模式，避免测试初始化与真实表单初始化相互覆盖。
        for _ in 0..<50 {
            if vm.configurationMode == .automatic { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(vm.configurationMode, .automatic)
        return window
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func scrollToPreview(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        guard let scroll = scrollViews(host).first, let document = scroll.documentView else { return }
        let offset = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func canonical(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    private func renderedText(_ view: NSView) throws -> String {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let preferred: String
        switch LanguageManager.shared.currentLanguage {
        case .english: preferred = "en-US"
        case .chinese: preferred = "zh-Hans"
        case .french: preferred = "fr-FR"
        case .vietnamese: preferred = "vi-VN"
        }
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = (preferred == "en-US" ? [preferred] : [preferred, "en-US"]).filter(supported.contains)
        request.customWords = ["action.retry".localized(), "agents.models.clientKeyRequired".localized(), "saved-model"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func waitForText(_ expected: String, in host: NSView, preview: Bool = false) async throws -> String {
        var actual = ""
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(50))
            if preview { scrollToPreview(host) }
            actual = try renderedText(host)
            if canonical(actual).contains(canonical(expected)) { return actual }
        }
        XCTFail("真实页面应呈现 \(expected)；实际绘制：\(actual)")
        return actual
    }

    func testFailurePageExposesRetryAndReturnsToSameDraft() async throws {
        let vm = AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: try temporaryHome()), fetchModels: { _, _ in [] })
        vm.selectedAgent = .openCode
        vm.currentConfiguration = AgentConfiguration(agent: .openCode, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture")
        let window = try await show(vm)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        vm.configResult = .failure(error: "fixture-save-failed")
        _ = try await waitForText("action.retry".localized(), in: host)
        // VM 重试动作的实际提交链路由领域回归覆盖，这里验证原生页面返回编辑且不丢草稿。
        vm.retryConfiguration()
        _ = try await waitForText("agents.connectionInfo".localized(), in: host)
        XCTAssertEqual(vm.currentConfiguration?.apiKey, "fixture")
        XCTAssertEqual(vm.currentConfiguration?.proxyURL, "https://fixture.invalid/v1")
    }

    func testLateKeyRebuildsFailedManualPreviewEvenWhenDirectoryRemainsEmpty() async throws {
        let home = try temporaryHome()
        let file = home.appendingPathComponent(".config/opencode/opencode.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"provider":{"quotio":{"models":{"saved-model":{"name":"Saved"}},"options":{"baseURL":"https://fixture.invalid/v1"}}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let vm = AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: home), fetchModels: { _, _ in [] })
        vm.selectedAgent = .openCode
        vm.currentConfiguration = AgentConfiguration(agent: .openCode, proxyURL: "https://fixture.invalid/v1", apiKey: "")
        let window = try await show(vm)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        vm.configurationMode = .manual
        let failure = String("agents.models.clientKeyRequired".localized().prefix(20))
        _ = try await waitForText(failure, in: host, preview: true)
        vm.currentConfiguration?.apiKey = "late-client-key"
        let loaded = await vm.loadModels(forceRefresh: true)
        XCTAssertTrue(loaded)
        XCTAssertTrue(vm.availableModels.isEmpty, "预览更新不能依赖目录 [] 到 [] 的变化")
        _ = try await waitForText("saved-model", in: host, preview: true)
    }
}
