import SwiftUI

/// 账号额度内容与其专用辅助视图。布局、修饰器和子视图顺序沿用原来的额度卡片。
/// 继续读取环境中的同一个 QuotaViewModel；三个弹窗开关和原有刷新、授权 Task 均保留在
/// AccountQuotaContent 内，不把状态或异步任务下放给新文件中的展示组件。
struct AccountQuotaContent: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme

    // 默认复用应用偏好；允许离线回归注入独立偏好域，避免测试修改用户隐私设置。
    var settings: MenuBarSettingsManager = .shared
    let provider: AIProvider
    let account: AccountQuotaPresentation
    let isLoading: Bool
    // 融合页由 AccountRow 提供唯一身份和管理操作；这里仅保留套餐、额度与专属工具。
    var showsIdentity: Bool = true
    // 多 Key 连接需要区分各额度桶；这里只展示已有标签或编号，不显示实际密钥。
    var quotaLabel: String?
    // 编号单独显示，隐私掩码不能抹掉多密钥额度段之间的辨认信息。
    var quotaSequence: Int?
    // 样式是展示输入，父页面沿用用户偏好；原生离线回归可传入三种样式逐一验证。
    var displayStyle: QuotaDisplayStyle = MenuBarSettingsManager.shared.quotaDisplayStyle

    @State private var showSwitchSheet = false
    @State private var showModelsDetailSheet = false

    private var accountID: QuotaAccountID {
        QuotaAccountID(provider: provider, accountKey: account.key)
    }

    private var isRefreshing: Bool {
        viewModel.isRefreshing(account: accountID)
    }

    /// Check if OAuth is in progress for this provider
    private var isReauthenticating: Bool {
        guard let oauthState = viewModel.oauthState else { return false }
        return oauthState.provider == provider &&
               (oauthState.status == .waiting || oauthState.status == .polling)
    }

    /// Get auth URL if available during reauthentication
    private var reauthURL: URL? {
        guard let oauthState = viewModel.oauthState,
              oauthState.provider == provider,
              let urlString = oauthState.authURL else { return nil }
        return URL(string: urlString)
    }
    @State private var showWarmupSheet = false

    private var hasQuotaData: Bool {
        guard let data = account.quotaData else { return false }
        return !data.models.isEmpty
    }

    private var displayEmail: String {
        account.email.masked(if: settings.hideSensitiveInfo)
    }

    /// 配置名／额度子标题与身份行遵守同一隐私规则，多密钥连接不能在子标题泄露名称。
    var displayQuotaLabel: String? {
        quotaLabel?.masked(if: settings.hideSensitiveInfo)
    }

    /// 普通账号的套餐已在唯一身份行显示；多 Key 的套餐可能不同，必须在各段
    /// 安全编号后保留该 Key 的徽章，不能把首个 Key 的套餐当成整个连接的套餐。
    var showsPlanBadge: Bool { showsIdentity || quotaSequence != nil }

    private var isWarmupEnabled: Bool {
        viewModel.isWarmupEnabled(for: provider, accountKey: account.key)
    }

    /// Check if this Antigravity account is active in IDE
    private var isActiveInIDE: Bool {
        provider == .antigravity && viewModel.isAntigravityAccountActive(email: account.email)
    }

    /// 与状态栏使用同一份模型/额度桶明细，不再按旧版本名称分组或跨额度池平均。
    private var antigravityDisplayGroups: [AntigravityDisplayGroup] {
        guard let data = account.quotaData, provider == .antigravity else { return [] }
        return AntigravityDisplayGroup.make(from: data.models)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 融合模式的套餐和预热／刷新已进入唯一账号行；仅在需要额外子标题或
            // 禁止状态的重新授权入口时呈现本段头部，避免产生空的第二行工具栏。
            if showsIdentity || quotaLabel != nil || account.quotaData?.isForbidden == true {
                accountHeader
            }

            // 即使刷新失败后继续保留可用缓存，也明确展示失败原因和该缓存的更新时间。
            AccountQuotaFreshnessView(provider: provider, accountKey: account.key, data: account.quotaData)

            // CPA 的模型级 429 也会把认证文件置为 error。即使旧额度仍可显示，
            // 也必须把具体原因放在对应账号卡上，不能只留下一个红色 Error。
            if let file = account.authFile,
               let message = file.humanReadableStatus,
               file.status == "error" || !hasQuotaData {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: file.status == "error" ? "exclamationmark.triangle.fill" : "info.circle")
                    VStack(alignment: .leading, spacing: 3) {
                        if let model = file.quotaCooldownModel {
                            Text(String(format: "quota.modelCooldownFor".localized(), model))
                                .fontWeight(.medium)
                        }
                        Text(message)
                            .lineLimit(3)
                            .help(message)
                    }
                }
                .font(.caption)
                .foregroundStyle(file.status == "error" ? Color.orange : Color.secondary)
                .accessibilityElement(children: .combine)
            }

            if isLoading {
                QuotaLoadingView()
            } else if hasQuotaData {
                usageSection
            } else {
                // 已连接但尚无额度的账号也保留管理操作，并明确给出等待刷新提示。
                Text("quota.noDataYet".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // 全模型弹窗挂在账号卡片的稳定根节点，继续复用本类型原有的显示状态。
        // 刷新会暂时切换 loading／无额度分支，不能因此卸载 presenter 或关闭已打开的弹窗；
        // 此处只传展示快照和原注入偏好，不持有第二份模型、设置或刷新任务。
        .sheet(isPresented: $showModelsDetailSheet) {
            AntigravityModelsDetailSheet(
                email: account.email,
                models: account.quotaData?.models ?? [],
                displayMode: settings.quotaDisplayMode,
                hideSensitiveInfo: settings.hideSensitiveInfo
            )
        }
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let displayQuotaLabel {
                        Text(displayQuotaLabel)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    if let quotaSequence {
                        Text("#\(quotaSequence)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if showsPlanBadge, let info = account.subscriptionInfo {
                        SubscriptionBadgeV2(info: info)
                    } else if showsPlanBadge, let planName = account.quotaData?.planDisplayName {
                        PlanBadgeV2Compact(planName: planName)
                    }

                    if showsIdentity {
                        Text(displayEmail)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                }

                // Show token expiry for Kiro accounts
                if showsIdentity, let quotaData = account.quotaData, let tokenExpiry = quotaData.formattedTokenExpiry {
                    HStack(spacing: 4) {
                        Image(systemName: "key")
                            .font(.caption2)
                        Text(tokenExpiry)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                if showsIdentity && account.status != "ready" && account.status != "active" {
                    Text(account.authFile?.quotaCooldownModel == nil
                         ? account.status.capitalized
                         : "quota.modelCooldown".localized())
                        .font(.caption)
                        .foregroundStyle(account.authFile?.quotaCooldownModel == nil ? account.statusColor : .orange)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if showsIdentity && provider == .antigravity {
                    Button {
                        showWarmupSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isWarmupEnabled ? "bolt.fill" : "bolt")
                                .font(.caption)
                            Text("Warm Up")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(isWarmupEnabled ? provider.color : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isWarmupEnabled ? provider.color.opacity(colorScheme == .dark ? 0.22 : 0.12) : QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(isWarmupEnabled ? provider.color.opacity(0.35) : QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("action.warmup".localized())
                }

                if showsIdentity && isActiveInIDE {
                    Text("antigravity.active".localized())
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
                        )
                }

                if showsIdentity && provider == .antigravity && !isActiveInIDE {
                    Button {
                        showSwitchSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.square")
                                .font(.caption)
                            Text("Use in IDE")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(colorScheme == .dark ? 0.2 : 0.1), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.blue.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("antigravity.useInIDE".localized())
                }

                if showsIdentity {
                Button {
                    Task {
                        await viewModel.refreshQuota(for: accountID)
                    }
                } label: {
                    if isRefreshing || isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("action.refresh".localized())
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                        )
                    }
                }
                .buttonStyle(.plain)
                .disabled(
                    viewModel.isRefreshBlocked(for: accountID)
                        || !viewModel.supportsScopedRefresh(for: provider)
                )
                .help("action.refreshQuota".localized())
                }

                if let data = account.quotaData, data.isForbidden {
                    if provider == .claude {
                        // When reauthenticating with authURL available, show "Open Link" button
                        if isReauthenticating, let url = reauthURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Image(systemName: "safari")
                                        .font(.caption)
                                }
                                .foregroundStyle(.orange)
                                .frame(width: 56, height: 26)
                                .background(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("oauth.openLink".localized())
                        } else {
                            Button {
                                Task {
                                    await viewModel.startOAuth(for: .claude, launchMode: .autoOpen)
                                }
                            } label: {
                                if isReauthenticating {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .frame(width: 26, height: 26)
                                } else {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .frame(width: 26, height: 26)
                                        .background(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Circle())
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isReauthenticating)
                            .help("quota.reauthenticate".localized())
                        }
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(width: 26, height: 26)
                            .background(Color.red.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5)
                            )
                            .help("Limit Reached")
                    }
                }
            }
        }
        .sheet(isPresented: $showSwitchSheet) {
            SwitchAccountSheet(
                accountEmail: account.email,
                onDismiss: {
                    showSwitchSheet = false
                }
            )
            .environment(viewModel)
        }
        .sheet(isPresented: $showWarmupSheet) {
            WarmupSheet(
                provider: provider,
                accountKey: account.key,
                accountEmail: account.email,
                onDismiss: {
                    showWarmupSheet = false
                }
            )
            .environment(viewModel)
        }
    }

    // MARK: - Usage Section

    private var isQuotaUnavailable: Bool {
        guard let data = account.quotaData else { return false }
        return data.models.allSatisfy { $0.percentage < 0 && !$0.isStandaloneMetric }
    }

    @ViewBuilder
    private var usageSection: some View {
        if let data = account.quotaData {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Usage")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()

                    if provider == .antigravity && data.models.count > 4 {
                        Button {
                            showModelsDetailSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("quota.details".localized())
                                    .font(.caption)
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .opacity(0.5)

                // Display based on quotaDisplayStyle setting
                if isQuotaUnavailable {
                    quotaUnavailableView
                } else {
                    quotaContentByStyle
                }
            }
            .padding(.top, 4)
        }
    }

    private var quotaUnavailableView: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Text("quota.notAvailable".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var quotaContentByStyle: some View {
        if provider == .antigravity && !antigravityDisplayGroups.isEmpty {
            // Antigravity uses grouped display
            antigravityContentByStyle
        } else if let data = account.quotaData {
            // Standard providers
            standardContentByStyle(data: data)
        }
    }

    /// 自适应额度网格列配置：单条额度指标占满单列（如 Codex 仅有周限额），大于等于2条指标时自适应为一行两个（类似菜单栏网格排版）。
    static func quotaGridColumns(count: Int) -> [GridItem] {
        if count <= 1 {
            return [GridItem(.flexible())]
        } else {
            return [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ]
        }
    }

    @ViewBuilder
    private var antigravityContentByStyle: some View {
        switch displayStyle {
        case .lowestBar:
            AntigravityLowestBarLayout(groups: antigravityDisplayGroups)
        case .ring:
            AntigravityRingLayout(groups: antigravityDisplayGroups)
        case .card:
            LazyVGrid(columns: Self.quotaGridColumns(count: antigravityDisplayGroups.count), spacing: 8) {
                ForEach(antigravityDisplayGroups) { group in
                    AntigravityGroupRow(group: group)
                }
            }
        }
    }

    @ViewBuilder
    private func standardContentByStyle(data: ProviderQuotaData) -> some View {
        if displayStyle == .card {
            let meterModels = data.models.filter { !$0.isStandaloneMetric }
            let standaloneModels = data.models.filter(\.isStandaloneMetric)
            let factorySections = provider == .factoryDroid
                ? FactoryDroidQuotaSection.sections(from: meterModels)
                : []

            VStack(spacing: 8) {
                if !factorySections.isEmpty {
                    ForEach(factorySections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            FactoryDroidQuotaSectionHeader(title: section.title)
                            standardCardGrid(models: section.models)
                        }
                    }
                    if !standaloneModels.isEmpty {
                        standardCardGrid(models: standaloneModels)
                    }
                } else {
                    standardCardGrid(models: data.models)
                }
            }
        } else {
            let meterModels = data.models.filter { !$0.isStandaloneMetric }
            let standaloneModels = data.models.filter(\.isStandaloneMetric)
            let factorySections = provider == .factoryDroid
                ? FactoryDroidQuotaSection.sections(from: meterModels)
                : []

            VStack(spacing: 12) {
                if !factorySections.isEmpty {
                    ForEach(factorySections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            FactoryDroidQuotaSectionHeader(title: section.title)
                            meterContentByStyle(models: section.models)
                        }
                    }
                } else if !meterModels.isEmpty {
                    meterContentByStyle(models: meterModels)
                }

                ForEach(standaloneModels) { model in
                    StandaloneMetricRow(model: model)
                }
            }
        }
    }

    /// 标准提供商在卡片（横条）样式下的自适应网格展示，支持普通进度与独立指标统一排版。
    @ViewBuilder
    private func standardCardGrid(models: [ModelQuota]) -> some View {
        LazyVGrid(columns: Self.quotaGridColumns(count: models.count), spacing: 8) {
            ForEach(models) { model in
                if model.isStandaloneMetric {
                    StandaloneMetricRow(model: model)
                } else {
                    UsageRowV2(
                        name: model.displayName,
                        icon: nil,
                        usedPercent: model.usedPercentage,
                        used: model.used,
                        limit: model.limit,
                        formattedUsage: model.presentation == nil ? nil : model.formattedUsage,
                        resetTime: model.formattedResetTime,
                        tooltip: model.tooltip
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func meterContentByStyle(models: [ModelQuota]) -> some View {
        switch displayStyle {
        case .lowestBar:
            StandardLowestBarLayout(models: models)
        case .ring:
            StandardRingLayout(models: models)
        case .card:
            standardCardGrid(models: models)
        }
    }
}

/// 单独的时间视图每分钟更新缓存状态，不触发上游请求，也不使整张配额卡片轮询刷新。
/// 仅服务于本文件的额度卡片，保留 private 可见性以及原有 TimelineView 更新边界。
private struct AccountQuotaFreshnessView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let provider: AIProvider
    let accountKey: String
    let data: ProviderQuotaData?

    private var account: MonitorAccount {
        // 代理模式可能没有 monitorAccounts 条目；仅构造查询状态所需的身份，不保存或读取凭据。
        viewModel.monitorAccounts.first { $0.provider == provider && $0.accountKey == accountKey }
            ?? MonitorAccount.make(provider: provider, accountKey: accountKey, source: .legacyCLIProxy)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let status = viewModel.monitorStatus(for: account)
            VStack(alignment: .leading, spacing: 4) {
                if status.status == "outdated", let message = status.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let updated = data?.lastUpdated {
                    // 始终使用配额快照时间，不使用按钮点击时间或失败请求的完成时间。
                    Text(String(format: "monitor.status.updated".localized(), updated.formatted(date: .abbreviated, time: .shortened)))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Factory Droid 额度分区的局部标题，继续由父卡片决定分区顺序与数据来源。
private struct FactoryDroidQuotaSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
}

/// 额度读取期间的局部骨架视图；动画状态和 onAppear 仍属于本类型，文件拆分不重建调度。
private struct QuotaLoadingView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 100, height: 12)
                        Spacer()
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 48, height: 12)
                    }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 6)
                }
            }
        }
        .opacity(isAnimating ? 0.4 : 1)
        .animation(.easeOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }
    }
}
