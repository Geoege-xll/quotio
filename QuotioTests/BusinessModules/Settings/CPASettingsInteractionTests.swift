import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 只保留真实生产组件的绑定副作用与失败不写入回归，不导出人工验收截图。
/// 使用内存草稿和无副作用的应用回调，不启动 CPA、不读取真实账号或写用户配置。
@MainActor
final class CPASettingsInteractionTests: XCTestCase {
    @Observable final class FormState {
        var strategy = "weighted-round-robin"
        var session = true
        var draft = CPAAdvancedSettingsDraft()
        var requestsExpanded = false
        var logsExpanded = false
        var applyCount = 0
    }

    private struct Preview: View {
        @Bindable var state: FormState

        var body: some View {
            Form {
                CPARoutingPolicySection(strategy: $state.strategy, sessionAffinity: $state.session)
                Section {
                    CPAAdvancedSettingsOptions(scope: .requests, sessionAffinity: state.session,
                        draft: $state.draft, isExpanded: $state.requestsExpanded) { state.applyCount += 1 }
                }
                Section {
                    CPAAdvancedSettingsOptions(scope: .logging, draft: $state.draft,
                        isExpanded: $state.logsExpanded) { state.applyCount += 1 }
                }
            }
            .formStyle(.grouped)
            .modifier(SettingsPageBackground())
        }
    }

    private func render(_ state: FormState, width: CGFloat, scheme: ColorScheme) {
        let host = NSHostingView(rootView: Preview(state: state).environment(\.colorScheme, scheme))
        let size = CGSize(width: width, height: 940)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

    }

    func testAdvancedOptionsStartCollapsedAndExpandingDoesNotSave() throws {
        let state = FormState()
        XCTAssertFalse(state.requestsExpanded); XCTAssertFalse(state.logsExpanded)
        let original = state.draft
        render(state, width: 760, scheme: .light)
        state.requestsExpanded = true; state.logsExpanded = true
        render(state, width: 760, scheme: .light)
        XCTAssertEqual(state.draft, original)
        XCTAssertEqual(state.applyCount, 0, "展开和渲染不能触发应用回调")
    }

    func testDisablingSessionAffinityKeepsExistingDraftWithoutApplying() throws {
        let state = FormState()
        state.requestsExpanded = true; state.logsExpanded = true
        state.draft.sessionTTL = "37m15s"; state.draft.sessionSubagents = false
        state.draft.maxRetryCredentials = "12"; state.draft.keepaliveSeconds = "-1"
        state.draft.logsMaxSizeMB = "4096"; state.draft.errorLogsMaxFiles = "0"
        let original = state.draft
        render(state, width: 580, scheme: .dark)
        state.session = false
        render(state, width: 580, scheme: .dark)
        XCTAssertEqual(state.draft, original, "关闭会话绑定时不能清理 TTL 或子代理配置")
        XCTAssertEqual(state.applyCount, 0)
    }

    func testAccountWeightReadFailureRendersRetryWithoutWritingDefault() async throws {
        let domain = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { _, _ in .replyStatus(#"{"error":"fixture-unavailable"}"#, 503) }
        LifecycleHTTPProtocol.register(state, host: domain)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: ManagementAPIClient.managementURL(for: "https://" + domain),
            authKey: "fake-management", configuration: config)
        addTeardownBlock { await client.invalidate(); LifecycleHTTPProtocol.remove(host: domain) }
        let host = NSHostingView(rootView: CPAAccountWeightSheet(displayName: "隔离测试账号",
            authFileName: "fixture.json", client: client))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(state.requests.isEmpty)
        XCTAssertTrue(state.requests.allSatisfy { $0.method == "GET" }, "读取失败不能把默认权重写回服务端")
    }

    func testAdvancedDraftHasChangesAcrossScopes() {
        let saved = CPAAdvancedSettingsDraft()
        var modified = saved
        XCTAssertFalse(modified.hasChanges(comparedTo: saved, scope: .requests))
        XCTAssertFalse(modified.hasChanges(comparedTo: saved, scope: .logging))

        // 修改请求参数
        modified.maxRetryCredentials = "5"
        XCTAssertTrue(modified.hasChanges(comparedTo: saved, scope: .requests))
        XCTAssertFalse(modified.hasChanges(comparedTo: saved, scope: .logging))

        // 仅修改日志参数
        var loggingOnly = saved
        loggingOnly.logsMaxSizeMB = "512"
        XCTAssertFalse(loggingOnly.hasChanges(comparedTo: saved, scope: .requests))
        XCTAssertTrue(loggingOnly.hasChanges(comparedTo: saved, scope: .logging))
    }

    func testInlineApplyFieldRendersWithoutCrash() {
        let host = NSHostingView(rootView: Form {
            QuotioInlineApplyField(
                titleKey: "settings.upstreamProxy",
                placeholderKey: "settings.upstreamProxy.placeholder",
                text: .constant("http://127.0.0.1:7890"),
                savedText: "http://127.0.0.1:7890",
                isValid: true,
                validationErrorMessage: nil,
                isSaving: false
            ) {}
        }.formStyle(.grouped))
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(host.window)
    }
}
