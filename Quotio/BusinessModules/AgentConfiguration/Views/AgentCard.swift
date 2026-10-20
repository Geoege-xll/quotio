//
//  AgentCard.swift
//  Quotio - Individual CLI agent card component
//

import AppKit
import SwiftUI

struct AgentCard: View {
    let status: AgentStatus
    var viewModel: AgentSetupViewModel? = nil
    let onConfigure: () -> Void

    @State private var showUninstallAlert = false
    @State private var isLaunching = false
    /// 安装信息属于当前卡片的临时呈现状态；不复制检测结果，不持有新的业务任务。
    @State private var showsInstallationInfo = false

    private var isCheckingUpdate: Bool {
        viewModel?.isCheckingUpdates[status.agent] == true
    }

    private var updateMessage: String? {
        viewModel?.updateMessages[status.agent]
    }

    private var remoteVersion: String? {
        viewModel?.remoteVersions[status.agent]
    }

    private var hasNewerVersion: Bool {
        viewModel?.hasNewerVersion(for: status) ?? false
    }

    /// 这里只压缩版本输出的展示，不改原始检测值和 ViewModel 的版本比较／升级规则。
    /// 预发布和构建后缀继续保留；遇到非标准输出时原样展示，完整内容始终可在安装信息中查看。
    private func compactVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"\d+(?:\.\d+)+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?(?:\+[0-9A-Za-z][0-9A-Za-z.-]*)?"#,
                                       options: .regularExpression) else { return trimmed }
        return "v" + trimmed[range]
    }

    private var installationSource: String {
        if case .homebrewCask = status.installMethod { return "Homebrew" }
        return status.installMethod.displayName
    }

    /// VM 保存的是检查当时的本地化文案，而切换语言只重建视图。识别全部随包翻译，
    /// 避免旧语言的成功结果被新界面误判为异常；这里只读资源，不新增检测状态或任务。
    private static let updateMessageTemplates: [(latest: String, available: String)] = {
        Bundle.main.localizations.compactMap { language in
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
            return (bundle.localizedString(forKey: "agents.latestVersion", value: nil, table: nil),
                    bundle.localizedString(forKey: "agents.updateAvailable", value: nil, table: nil))
        }
    }()

    private var isLatestMessage: Bool {
        guard let message = updateMessage else { return false }
        return message == "agents.latestVersion".localized() || Self.updateMessageTemplates.contains { $0.latest == message }
    }

    private var isAvailableMessage: Bool {
        guard let message = updateMessage, let remoteVersion else { return false }
        return Self.updateMessageTemplates.contains { String(format: $0.available, remoteVersion) == message }
    }

    /// 原更新消息仍由 ViewModel 持有。最新版本结果保留在检查按钮提示中，异常与手动处理说明仍然可见。
    /// 升级后旧的“可升级”消息不能继续占位；可升级与否始终采用原 hasNewerVersion 判定。
    private var needsAttentionMessage: String? {
        guard !isCheckingUpdate, let message = updateMessage, !message.isEmpty,
              !isLatestMessage, !isAvailableMessage else { return nil }
        return message
    }

    private var feedbackText: String? {
        if isCheckingUpdate { return "agents.checkUpdate.checking".localized() }
        if let message = needsAttentionMessage { return message }
        if hasNewerVersion, let remoteVersion {
            // 本地化字符串自带 v，传入压缩后的纯版本，避免出现“v版本输出”或双重 v。
            let version = compactVersion(remoteVersion)
            return String(format: "agents.updateAvailable".localized(), version.hasPrefix("v") ? String(version.dropFirst()) : version)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // 图标与外方内圆规范统一，44x44 尺寸与左侧两行信息及右侧两排操作形成稳定视觉对齐
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(status.agent.color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: status.agent.systemIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(status.agent.color)
            }
            .padding(.top, 1)

            // 按实际提议宽度选择布局：宽时右侧两排对齐，极窄时操作区平滑换到下方
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    information.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    actions
                }
                .frame(minHeight: 44)
                VStack(alignment: .leading, spacing: 12) {
                    information
                    HStack { Spacer(minLength: 0); actions }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 14)
        .confirmationDialog(
            String(format: "agents.uninstall.confirm.title".localized(), status.agent.displayName),
            isPresented: $showUninstallAlert,
            titleVisibility: .visible
        ) {
            Button("agents.uninstall".localized(), role: .destructive) {
                Task { await viewModel?.uninstallAgent(status) }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text(String(format: "agents.uninstall.confirm.message".localized(), status.uninstallCommand))
        }
    }

    // 名称与配置状态是第一层信息，版本与来源是第二层；适当加大行间距，保持呼吸感与行级对齐。
    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(status.agent.displayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .help(status.agent.displayName)

                StatusBadge(status: status)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // 窗口变窄或错误说明较长时，仅次要信息自然换行，按钮与标题不会被挤出卡片。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    metadata
                    if feedbackText != nil { feedback }
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) {
                    metadata
                    if feedbackText != nil { feedback }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 右侧操作保持两行平铺布局：上行配置与打开，下行辅助工具条，保持视觉秩序与操作层级。
    // 原回调及异步操作仍在原类型内执行，不引入操作路由器或新的任务宿主。
    private var actions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            primaryActions
            utilityActions
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            if hasNewerVersion {
                Button {
                    Task { await viewModel?.upgradeAgent(status) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("agents.upgrade".localized())
                    }
                }
                .buttonStyle(.quotioPrimaryMicroCapsule(height: 26, tint: .orange))
                .accessibilityIdentifier("agents.upgrade.\(status.agent.id)")
            }

            Button {
                onConfigure()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: status.configured ? "arrow.triangle.2.circlepath" : "gearshape")
                    Text("agents.configure".localized())
                }
            }
            .buttonStyle(.quotioPrimaryMicroCapsule(height: 26, tint: status.agent.color))
            .help((status.configured ? "agents.reconfigure" : "agents.configure").localized())
            .accessibilityIdentifier("agents.configure.\(status.agent.id)")
            // 打开 CLI (Open in CLI)
            Button {
                Task {
                    isLaunching = true
                    defer { isLaunching = false }
                    try? await TerminalLauncher.shared.launchAgent(agent: status.agent, binaryPath: status.binaryPath)
                }
            } label: {
                HStack(spacing: 4) {
                    if isLaunching { SmallProgressView().frame(width: 12, height: 12) }
                    else { Image(systemName: "terminal") }
                    Text("agents.open".localized())
                }
            }
            .buttonStyle(.quotioMicroCapsule(height: 26))
            .disabled(isLaunching)
            .help("agents.open.help".localized())
            .accessibilityIdentifier("agents.open.\(status.agent.id)")
        }
    }

    /// 辅助入口恢复原来的图标工具条，继续使用设计系统的 26pt 圆形按钮。
    /// 更新状态、安装弹窗及卸载确认仍由原卡片／ViewModel 持有，布局调整不增加任务或业务状态。
    private var utilityActions: some View {
        HStack(spacing: 6) {
            QuotioCircularIconButton(
                systemImage: "arrow.triangle.2.circlepath",
                tooltip: isLatestMessage
                    ? "agents.checkUpdate".localized() + " · " + "agents.latestVersion".localized()
                    : "agents.checkUpdate".localized(),
                isLoading: isCheckingUpdate
            ) {
                Task { await viewModel?.checkForUpdate(for: status) }
            }
            .disabled(viewModel == nil)
            .accessibilityLabel("agents.checkUpdate".localized())
            .accessibilityIdentifier("agents.checkUpdate.\(status.agent.id)")

            QuotioCircularIconButton(systemImage: "info.circle", tooltip: "agents.installationInfo".localized()) {
                showsInstallationInfo = true
            }
            .accessibilityLabel("agents.installationInfo".localized())
            .accessibilityIdentifier("agents.installationInfo.\(status.agent.id)")
            .popover(isPresented: $showsInstallationInfo, arrowEdge: .bottom) {
                AgentInstallationInfo(status: status) { showsInstallationInfo = false }
            }

            if let docsURL = status.agent.docsURL {
                QuotioCircularIconButton(systemImage: "book", tooltip: "agents.viewDocs".localized()) {
                    NSWorkspace.shared.open(docsURL)
                }
                .accessibilityLabel("agents.viewDocs".localized())
                .accessibilityIdentifier("agents.viewDocs.\(status.agent.id)")
            }

            // 直接入口仍先出现原卸载确认，点击图标本身不执行命令或清理用户配置。
            QuotioCircularIconButton(systemImage: "trash", tint: .red, backgroundTint: .red,
                                     tooltip: "agents.uninstall".localized()) {
                showUninstallAlert = true
            }
            .accessibilityLabel("agents.uninstall".localized())
            .accessibilityIdentifier("agents.uninstall.\(status.agent.id)")
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let version = status.version, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: compactVersion(version))
                Text("·").accessibilityHidden(true)
            }
            Text(verbatim: installationSource)
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private var feedback: some View {
        HStack(spacing: 4) {
            if isCheckingUpdate { SmallProgressView().frame(width: 10, height: 10) }
            else { Image(systemName: needsAttentionMessage == nil ? "arrow.up.circle" : "exclamationmark.triangle") }
            Text(verbatim: feedbackText ?? "")
        }
        .font(.caption).foregroundStyle(isCheckingUpdate ? Color.secondary : .orange)
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        .help(feedbackText ?? "")
    }
}

/// 仅展示卡片已有的安装快照；不重新扫描、不读配置文件，也不修改安装渠道和检测状态。
/// 完整原始版本、包名和路径集中呈现，长路径可换行、选择和复制，不依赖悬停才能获取。
private struct AgentInstallationInfo: View {
    let status: AgentStatus
    let onClose: () -> Void

    private var source: String {
        switch status.installMethod {
        case .homebrewCask(let name): return "Homebrew (Cask) · " + name
        case .homebrewFormula(let name): return "Homebrew (Formula) · " + name
        case .npm(let package): return "npm · " + package
        case .pnpm(let package): return "pnpm · " + package
        case .bun(let package): return "bun · " + package
        case .standalone, .unknown: return status.installMethod.displayName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(status.agent.displayName + " · " + "agents.installationInfo".localized()).font(.headline)
                Spacer(minLength: 8)
                QuotioCircularIconButton(systemImage: "xmark", tooltip: "action.close".localized(), action: onClose)
                    .accessibilityLabel("action.close".localized())
            }
            LabeledContent("agents.installationInfo.version".localized()) {
                Text(verbatim: status.version ?? "—").textSelection(.enabled)
            }
            LabeledContent("agents.installationInfo.source".localized()) {
                Text(verbatim: source).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("agents.installationInfo.path".localized()).foregroundStyle(.secondary)
                    Spacer()
                    if let path = status.binaryPath {
                        QuotioCircularIconButton(systemImage: "doc.on.doc", tooltip: "agents.installationInfo.copyPath".localized()) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        }
                        .accessibilityLabel("agents.installationInfo.copyPath".localized())
                        .accessibilityIdentifier("agents.copyPath.\(status.agent.id)")
                    }
                }
                Text(verbatim: status.binaryPath ?? "—")
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout).padding(16).frame(width: 380, alignment: .leading)
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.statusColor)
                .frame(width: 6, height: 6)

            Text(status.statusLocalizationKey.localized())
                .font(.caption)
                .foregroundStyle(status.statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.statusColor.opacity(0.1))
        .clipShape(Capsule())
        // 「已配置」指 Quotio 的代理接入；Pi 自身登录其他提供商并不等于已接入 CPA。
        .help(status.agent == .pi ? "agents.pi.statusHelp".localized() : status.statusLocalizationKey.localized())
    }
}

#Preview {
    VStack(spacing: 16) {
        AgentCard(
            status: AgentStatus(
                agent: .claudeCode,
                installed: true,
                configured: true,
                binaryPath: "/usr/local/bin/claude",
                version: "1.0.0",
                lastConfigured: Date()
            ),
            onConfigure: {}
        )

        AgentCard(
            status: AgentStatus(
                agent: .openCode,
                installed: true,
                configured: false,
                binaryPath: nil,
                version: nil,
                lastConfigured: nil
            ),
            onConfigure: {}
        )
    }
    .padding()
    .frame(width: 600)
}
