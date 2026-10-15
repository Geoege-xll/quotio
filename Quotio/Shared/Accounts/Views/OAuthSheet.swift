import SwiftUI
import AppKit

/// 账号页与仪表盘共同使用的原授权弹窗，保留完整视图及其私有 OAuthStatusView。
/// 所有 @State、task(id:)、新会话输入清理、自动关闭和退出取消仍归原视图，反馈仍来自同一个业务会话。
/// 不建立页面专用协调器，不复制授权状态，不改变 Kiro／设备流／手动回调及浏览器操作入口。
struct OAuthSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    let provider: AIProvider
    let onDismiss: () -> Void
    @State private var selectedKiroMethod: AuthCommand = .kiroImport
    @State private var manualOAuthCode = ""
    @State private var manualCallbackInput = ""
    @State private var showManualCallback = false
    @State private var githubHostInput = ""
    /// 读取原 VM 注入的同一模式实例，授权表单与实际执行路径保持一致，不另持全局模式引用。
    private var modeManager: OperatingModeManager { viewModel.modeManager }

    /// 域名是本轮表单输入，不存成全局“默认主机”；成功后与该凭据一起保存，避免影响其他账号。
    private var showsGitHubHost: Bool { provider == .copilot && modeManager.isMonitorMode }
    private var githubHost: GitHubHost? { GitHubHost(githubHostInput) }
    private var invalidGitHubHost: Bool {
        showsGitHubHost && !githubHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && githubHost == nil
    }

    private func startAuthorization() async {
        guard !invalidGitHubHost else { return }
        await viewModel.startOAuth(for: provider, authMethod: provider == .kiro ? selectedKiroMethod : nil,
            githubHost: showsGitHubHost ? githubHost : nil)
    }

    /// 反馈属于业务会话而不是弹窗局部 Task；同一提供商重试也不会接收旧提交的迟到结果。
    private var currentSession: OAuthState? {
        guard viewModel.oauthState?.provider == provider else { return nil }
        return viewModel.oauthState
    }
    private var isSubmittingCallback: Bool { currentSession?.callbackStatus == .submitting }
    private var callbackFeedbackMessage: String? {
        switch currentSession?.callbackStatus {
        case .submitted: return "oauth.callbackSubmitted".localized()
        case .failed: return "oauth.invalidCallback".localized()
        default: return nil
        }
    }
    private var callbackFeedbackIsError: Bool { currentSession?.callbackStatus == .failed }

    private var isPolling: Bool {
        currentSession?.status == .polling || currentSession?.status == .waiting
    }

    private var isSuccess: Bool {
        currentSession?.status == .success
    }

    private var isError: Bool {
        currentSession?.status == .error
    }

    private var kiroAuthMethods: [AuthCommand] {
        if modeManager.isMonitorMode { return [.kiroAWSLogin] }
        return [.kiroImport, .kiroGoogleLogin, .kiroAWSAuthCode, .kiroAWSLogin]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Spacer()
                QuotioCircularIconButton(systemImage: "xmark") {
                    viewModel.cancelOAuth()
                    onDismiss()
                }
                .accessibilityLabel("action.cancel".localized())
            }
            .padding(.top, 16)
            .padding(.trailing, 16)

            VStack(spacing: 24) {
                ProviderIcon(provider: provider, size: 56)

                VStack(spacing: 6) {
                    Text("oauth.connect".localized() + " " + provider.displayName)
                        .font(.title3)
                        .fontWeight(.bold)

                    Text("oauth.authenticateWith".localized() + " " + provider.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if provider == .kiro {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("oauth.authMethod".localized())
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Picker("", selection: $selectedKiroMethod) {
                            ForEach(kiroAuthMethods, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .frame(maxWidth: 320)
                }

                if !modeManager.isMonitorMode, provider.requiresCPA8OAuthPlugin {
                    // 不冒充内置登录支持，保留用户已注册插件时的入口及已有账号的管理功能。
                    Text("oauth.cpa8PluginRequired".localized())
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: 320, alignment: .leading)
                }

                if !modeManager.isMonitorMode,
                   viewModel.proxyManager.isLegacyAuthWarningNeeded(for: provider) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(viewModel.proxyManager.upstreamCompatibilityWarning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if showsGitHubHost {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("oauth.githubHost.label".localized()).font(.subheadline.weight(.medium))
                        QuotioCapsuleTextField("oauth.githubHost.placeholder".localized(), text: $githubHostInput, systemImage: "globe")
                            .autocorrectionDisabled()
                            .disabled(isPolling || isSuccess)
                        Text((invalidGitHubHost ? "oauth.githubHost.invalid" : "oauth.githubHost.hint").localized())
                            .font(.caption)
                            .foregroundStyle(invalidGitHubHost ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }.frame(maxWidth: 360, alignment: .leading)
                }

                if let state = viewModel.oauthState, state.provider == provider {
                    OAuthStatusView(status: state.status, error: state.error, state: state.state, userCode: state.userCode, authURL: state.authURL, provider: provider)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                if modeManager.isMonitorMode, provider == .claude, viewModel.oauthState?.status == .polling {
                    HStack(spacing: 8) {
                        QuotioCapsuleTextField("oauth.authorizationCode".localized(), text: $manualOAuthCode, systemImage: "key")
                        Button("oauth.complete".localized()) {
                            Task { await viewModel.completeMonitorOAuthCode(manualOAuthCode, provider: provider) }
                        }
                        .buttonStyle(.quotioPrimaryCapsule)
                        .disabled(manualOAuthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: 360)
                }

                if !modeManager.isMonitorMode, currentSession?.supportsManualCallback == true {
                    VStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showManualCallback.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showManualCallback ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text("oauth.manualCallbackHint".localized())
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        if showManualCallback {
                            VStack(spacing: 6) {
                                HStack(spacing: 8) {
                                    QuotioCapsuleTextField("oauth.manualCallbackPlaceholder".localized(), text: $manualCallbackInput, systemImage: "link")
                                    Button {
                                        submitManualCallback()
                                    } label: {
                                        if isSubmittingCallback {
                                            SmallProgressView()
                                        } else {
                                            Text("oauth.submitCallback".localized())
                                        }
                                    }
                                    .buttonStyle(.quotioPrimaryCapsule)
                                    .disabled(manualCallbackInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmittingCallback || currentSession?.callbackStatus == .submitted)
                                }

                                if let message = callbackFeedbackMessage {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundStyle(callbackFeedbackIsError ? .red : .green)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(maxWidth: 380)
                }

                HStack(spacing: 16) {
                    Button("action.cancel".localized(), role: .cancel) {
                        viewModel.cancelOAuth()
                        onDismiss()
                    }
                    .buttonStyle(.quotioSecondaryCapsule)

                    if isError {
                        Button {
                            Task {
                                await startAuthorization()
                            }
                        } label: {
                            Label("oauth.retry".localized(), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.quotioPrimaryCapsule)
                        .disabled(invalidGitHubHost)
                    } else if !isSuccess {
                        Button {
                            Task {
                                await startAuthorization()
                            }
                        } label: {
                            if isPolling {
                                SmallProgressView()
                            } else {
                                Label("oauth.authenticate".localized(), systemImage: "key.fill")
                            }
                        }
                        .buttonStyle(.quotioPrimaryCapsule)
                        .disabled(isPolling || invalidGitHubHost)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
        }
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .frame(width: 480)
        .frame(minHeight: 350)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: viewModel.oauthState?.status)
        // 自动关闭任务跟随当前弹窗与提供商；视图消失或状态切换会取消睡眠，不能误关闭后来打开的登录。
        .task(id: provider.rawValue + ":" + String(isSuccess)) {
            guard isSuccess, viewModel.oauthState?.provider == provider else { return }
            do {
                try await Task.sleep(for: .milliseconds(1500))
                try Task.checkCancellation()
                guard viewModel.oauthState?.provider == provider, viewModel.oauthState?.status == .success else { return }
                onDismiss()
            } catch is CancellationError {
                // 关闭弹窗或开始新登录是正常取消，不再调用旧 onDismiss。
            } catch { }
        }
        .onChange(of: currentSession?.sessionID) { _, _ in
            // 新会话不继承旧授权码或手动区展开状态，避免用户误提交上一轮输入。
            manualCallbackInput = ""
            showManualCallback = false
        }
        .onDisappear {
            // 覆盖系统关闭与父页面退出；另一提供商的弹窗已启动时不取消它的新会话。
            if viewModel.oauthState?.provider == provider { viewModel.cancelOAuth() }
        }
    }

    private func submitManualCallback() {
        guard let sessionID = currentSession?.sessionID else { return }
        let input = manualCallbackInput
        Task {
            // 协调器发布当前会话的反馈；取消或切换会话时不会回写旧弹窗状态。
            try? await viewModel.submitOAuthCallback(input, for: provider, sessionID: sessionID)
        }
    }
}

private struct OAuthStatusView: View {
    let status: OAuthState.OAuthStatus
    let error: String?
    let state: String?
    let userCode: String?
    let authURL: String?
    let provider: AIProvider

    init(status: OAuthState.OAuthStatus, error: String?, state: String?, userCode: String? = nil, authURL: String?, provider: AIProvider) {
        self.status = status
        self.error = error
        self.state = state
        self.userCode = userCode
        self.authURL = authURL
        self.provider = provider
    }

    /// Stable rotation angle for spinner animation (fixes UUID() infinite re-render)
    @State private var rotationAngle: Double = 0

    /// Visual feedback for copy action
    @State private var copied = false

    var body: some View {
        Group {
            switch status {
            case .waiting:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("oauth.openingBrowser".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)

            case .polling:
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(provider.color.opacity(0.2), lineWidth: 4)
                            .frame(width: 60, height: 60)

                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(provider.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 60, height: 60)
                            .rotationEffect(.degrees(rotationAngle - 90))
                            .onAppear {
                                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                    rotationAngle = 360
                                }
                            }

                        Image(systemName: "person.badge.key.fill")
                            .font(.title2)
                            .foregroundStyle(provider.color)
                    }

                    // 通用设备码流（CPA v8 返回的 user_code 或 Copilot/Kiro 设备码）
                    let resolvedCode = userCode ?? ((provider == .copilot || provider == .kiro) ? state : nil)
                    if let deviceCode = resolvedCode, !deviceCode.isEmpty {
                        VStack(spacing: 8) {
                            Text("oauth.enterCodeInBrowser".localized())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                Text(deviceCode)
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundStyle(provider.color)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(provider.color.opacity(0.1))
                                    .cornerRadius(8)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(deviceCode, forType: .string)
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        copied = false
                                    }
                                } label: {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                        .font(.title3)
                                }
                                .buttonStyle(.subtle)
                                .help("action.copyCode".localized())
                            }

                            if let urlString = authURL, let url = URL(string: urlString) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("oauth.openLink".localized(), systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.bordered)
                            }

                            Text("oauth.waitingForAuth".localized())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if (provider == .copilot || provider == .kiro), let message = error {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 350)
                    } else {
                        Text("oauth.waitingForAuth".localized())
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        // Show auth URL with copy/open buttons
                        if let urlString = authURL, let url = URL(string: urlString) {
                            VStack(spacing: 12) {
                                Text("oauth.copyLinkOrOpen".localized())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                HStack(spacing: 12) {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(urlString, forType: .string)
                                        copied = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            copied = false
                                        }
                                    } label: {
                                        Label(copied ? "oauth.copied".localized() : "oauth.copyLink".localized(), systemImage: copied ? "checkmark" : "doc.on.doc")
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button {
                                        NSWorkspace.shared.open(url)
                                    } label: {
                                        Label("oauth.openLink".localized(), systemImage: "safari")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(provider.color)
                                }
                            }
                        } else {
                            Text("oauth.completeBrowser".localized())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 16)
                
            case .success:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    
                    Text("oauth.success".localized())
                        .font(.headline)
                        .foregroundStyle(.green)
                    
                    Text("oauth.closingSheet".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                
            case .error:
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    
                    Text("oauth.failed".localized())
                        .font(.headline)
                        .foregroundStyle(.red)
                    
                    if let error = error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .frame(minHeight: 100)
    }
}
