//
//  QuotaScreen.swift
//  Quotio
//

import SwiftUI

struct QuotaScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var modeManager = OperatingModeManager.shared

    @State private var selectedProvider: AIProvider?
    @State private var settings = MenuBarSettingsManager.shared

    // MARK: - Data Sources

    /// All providers with quota data (unified from proxy, direct, and monitor sources)
    private var availableProviders: [AIProvider] {
        var providers = Set<AIProvider>()

        // From proxy auth files
        for file in viewModel.authFiles {
            if let provider = file.providerType {
                providers.insert(provider)
            }
        }

        // From direct auth files
        for file in viewModel.directAuthFiles {
            providers.insert(file.provider)
        }

        // From monitor accounts
        for account in viewModel.monitorAccounts {
            providers.insert(account.provider)
        }

        // From direct quota data
        for provider in viewModel.providerQuotas.keys {
            providers.insert(provider)
        }

        return providers.sorted { $0.displayName < $1.displayName }
    }

    /// Get account count for a provider
    private func accountCount(for provider: AIProvider) -> Int {
        var accounts = Set<String>()

        // From auth files
        for file in viewModel.authFiles where file.providerType == provider {
            accounts.insert(file.quotaLookupKey)
        }

        // From direct auth files
        for file in viewModel.directAuthFiles where file.provider == provider {
            accounts.insert(file.filename)
        }

        // From monitor accounts
        for account in viewModel.monitorAccounts where account.provider == provider {
            accounts.insert(account.accountKey)
        }

        // From quota data
        if let quotaAccounts = viewModel.providerQuotas[provider] {
            for key in quotaAccounts.keys {
                accounts.insert(key)
            }
        }

        return accounts.count
    }

    private func lowestQuotaPercent(for provider: AIProvider) -> Double? {
        guard let accounts = viewModel.providerQuotas[provider] else { return nil }

        var allTotals: [Double] = []
        for (_, quotaData) in accounts {
            let total = settings.quotaSummaryPercentage(for: provider, models: quotaData.models)
            if total >= 0 {
                allTotals.append(total)
            }
        }

        return allTotals.min()
    }

    /// Check if we have any data to show
    private var hasAnyData: Bool {
        !viewModel.authFiles.isEmpty ||
        !viewModel.directAuthFiles.isEmpty ||
        !viewModel.monitorAccounts.isEmpty ||
        !viewModel.providerQuotas.isEmpty
    }

    var body: some View {
        Group {
            if !hasAnyData {
                ContentUnavailableView(
                    "empty.noAccounts".localized(),
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("empty.addProviderAccounts".localized())
                )
            } else {
                mainContent
            }
        }
        .quotioPage()
        .navigationTitle("nav.quota".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // Display Style
                        Picker(selection: Binding(
                            get: { settings.quotaDisplayStyle },
                            set: { settings.quotaDisplayStyle = $0 }
                        )) {
                            ForEach(QuotaDisplayStyle.allCases) { style in
                                Label(style.localizationKey.localized(), systemImage: style.iconName)
                                    .tag(style)
                            }
                        } label: {
                            Text("settings.quota.displayStyle".localized())
                        }
                        .pickerStyle(.inline)

                        Divider()

                        // Display Mode (Used vs Remaining)
                        Picker(selection: Binding(
                            get: { settings.quotaDisplayMode },
                            set: { settings.quotaDisplayMode = $0 }
                        )) {
                            ForEach(QuotaDisplayMode.allCases) { mode in
                                Text(mode.localizationKey.localized())
                                    .tag(mode)
                            }
                        } label: {
                            Text("display_mode".localized())
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let provider = selectedProvider ?? availableProviders.first {
                            Button {
                                Task { await viewModel.refreshQuota(for: provider) }
                            } label: {
                                Label(
                                    provider.displayName + " — " + "action.refreshQuota".localized(),
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            .disabled(
                                viewModel.isRefreshing(provider: provider)
                                    || !viewModel.supportsScopedRefresh(for: provider)
                            )

                            Divider()
                        }

                        Button {
                            Task { await viewModel.manualRefresh() }
                        } label: {
                            Label("action.refresh".localized(), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(viewModel.isLoadingQuotas)
                    } label: {
                        if let provider = selectedProvider ?? availableProviders.first,
                           viewModel.isRefreshing(provider: provider) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("action.refreshQuota".localized())
                }
        }
        .onAppear {
            if selectedProvider == nil, let first = availableProviders.first {
                selectedProvider = first
            }
        }
        .onChange(of: availableProviders) { _, newProviders in
            if selectedProvider == nil || !newProviders.contains(selectedProvider!) {
                selectedProvider = newProviders.first
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Provider Segmented Control
            if availableProviders.count > 1 {
                providerSegmentedControl
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
            }

            // Selected Provider Content
            ScrollView {
                if let provider = selectedProvider ?? availableProviders.first {
                    ProviderQuotaView(
                        provider: provider,
                        authFiles: viewModel.authFiles.filter { $0.providerType == provider },
                        quotaData: viewModel.providerQuotas[provider] ?? [:],
                        subscriptionInfos: viewModel.subscriptionInfos[provider] ?? [:],
                        isLoading: viewModel.refreshingProviders.contains(provider)
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                } else {
                    ContentUnavailableView(
                        "empty.noQuotaData".localized(),
                        systemImage: "chart.bar.xaxis",
                        description: Text("empty.refreshToLoad".localized())
                    )
                    .padding(24)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Segmented Control

    private var providerSegmentedControl: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(availableProviders) { provider in
                    ProviderSegmentButton(
                        provider: provider,
                        quotaPercent: lowestQuotaPercent(for: provider),
                        accountCount: accountCount(for: provider),
                        isSelected: selectedProvider == provider
                    ) {
                        selectedProvider = provider
                    }
                }
            }
            .padding(3)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            )
            .animation(.spring(response: 0.30, dampingFraction: 0.74), value: selectedProvider)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

/// 配额页与仪表盘共用的数值规则：未知值不是零余额，独立金额也不是百分比额度。
/// 纯函数不依赖账号、网络或用户设置，便于用固定上游样例验证所有展示入口的语义。
nonisolated enum QuotaPercentagePresentation {
    static func isKnown(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    static func lowestRemaining(in models: [ModelQuota]) -> Double? {
        models.filter { !$0.isStandaloneMetric && isKnown($0.percentage) }
            .map { min(100, $0.percentage) }.min()
    }

    static func sorted(_ models: [ModelQuota]) -> [ModelQuota] {
        models.sorted {
            let left = isKnown($0.percentage) ? $0.percentage : Double.infinity
            let right = isKnown($1.percentage) ? $1.percentage : Double.infinity
            return left == right ? $0.id < $1.id : left < right
        }
    }

    /// nil 要一直保留到文字和进度条分支，防止未知额度被转换为已用 100%。
    static func displayValue(_ remaining: Double, showUsed: Bool) -> Double? {
        guard isKnown(remaining) else { return nil }
        let clamped = min(100, remaining)
        return showUsed ? 100 - clamped : clamped
    }

    static func text(_ remaining: Double, showUsed: Bool = false) -> String {
        guard let value = displayValue(remaining, showUsed: showUsed) else { return "—" }
        return String(format: "%.0f%%", value)
    }
}

fileprivate struct QuotaDisplayHelper {
    let displayMode: QuotaDisplayMode

    func statusColor(remainingPercent: Double) -> Color {
        guard QuotaPercentagePresentation.isKnown(remainingPercent) else { return .secondary }
        let clamped = max(0, min(100, remainingPercent))
        let usedPercent = 100 - clamped
        let checkValue = displayMode == .used ? usedPercent : clamped

        if displayMode == .used {
            if checkValue < 70 { return .green }
            if checkValue < 90 { return .yellow }
            return .red
        }

        if checkValue > 50 { return .green }
        if checkValue > 20 { return .orange }
        return .red
    }

    func displayPercent(remainingPercent: Double) -> Double {
        QuotaPercentagePresentation.displayValue(remainingPercent, showUsed: displayMode == .used) ?? 0
    }

    func percentText(remainingPercent: Double) -> String {
        QuotaPercentagePresentation.text(remainingPercent, showUsed: displayMode == .used)
    }

    /// Percentage for ring rendering. Unlike `displayPercent(remainingPercent:)`
    /// this keeps the "no data" sentinel instead of clamping it into a real
    /// value, so `RingProgressView` can render its unknown state.
    func ringPercent(remainingPercent: Double) -> Double {
        !QuotaPercentagePresentation.isKnown(remainingPercent)
            ? RingProgressView.unknownPercent
            : displayPercent(remainingPercent: remainingPercent)
    }
}

// MARK: - Provider Segment Button

private struct ProviderSegmentButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: AIProvider
    let quotaPercent: Double?
    let accountCount: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var statusColor: Color {
        guard let percent = quotaPercent else { return .secondary }
        return displayHelper.statusColor(remainingPercent: percent)
    }

    private var remainingPercent: Double {
        max(0, min(100, quotaPercent ?? 0))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 18)

                Text(provider.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                if accountCount > 1 {
                    Text(String(accountCount))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? (colorScheme == .dark ? .white : provider.color) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? provider.color.opacity(colorScheme == .dark ? 0.28 : 0.15) : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                }

                if quotaPercent != nil {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: remainingPercent / 100)
                            .stroke(statusColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 32)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    activeThumb
                } else if isHovered {
                    Capsule()
                        .fill(QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(colorScheme == .dark ? 0.5 : 0.6))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(SegmentButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var activeThumb: some View {
        ZStack {
            Capsule()
                .fill(QuotioTheme.Colors.cardBackground(for: colorScheme))
            Capsule()
                .fill(provider.color.opacity(colorScheme == .dark ? 0.16 : 0.10))
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            provider.color.opacity(colorScheme == .dark ? 0.42 : 0.32),
                            provider.color.opacity(colorScheme == .dark ? 0.14 : 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .shadow(
            color: provider.color.opacity(colorScheme == .dark ? 0.35 : 0.12),
            radius: colorScheme == .dark ? 6 : 3.5,
            x: 0,
            y: 1.5
        )
    }
}

// MARK: - Quota Status Dot

private struct QuotaStatusDot: View {
    let usedPercent: Double
    let size: CGFloat

    private var color: Color {
        if usedPercent < 70 { return .green }   // <70% used = healthy
        if usedPercent < 90 { return .yellow }  // 70-90% used = warning
        return .red                              // >90% used = critical
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: - Provider Quota View

private struct ProviderQuotaView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    let provider: AIProvider
    let authFiles: [AuthFile]
    let quotaData: [String: ProviderQuotaData]
    let subscriptionInfos: [String: SubscriptionInfo]
    let isLoading: Bool

    /// Get all accounts (from auth files or quota data keys)
    private var allAccounts: [AccountInfo] {
        var accounts: [AccountInfo] = []

        // From auth files
        for file in authFiles {
            let key = file.quotaLookupKey
            accounts.append(AccountInfo(
                key: key,
                email: file.email ?? file.name,
                status: file.status,
                statusColor: file.statusColor,
                authFile: file,
                quotaData: quotaData[key],
                subscriptionInfo: subscriptionInfos[key]
            ))
        }

        // From quota data (if not already added)
        let existingKeys = Set(accounts.map { $0.key })
        // Only Codex needs direct-auth email backfill because its quota key is
        // filename-based to distinguish same-email Plus/Team accounts.
        let directAuthEmailsByKey: [String: String] = provider == .codex
            ? viewModel.monitorAccounts
                .filter { $0.provider == .codex }
                .reduce(into: [:]) { $0[$1.accountKey] = $1.displayName }
            : [:]
        for (key, data) in quotaData {
            if !existingKeys.contains(key) {
                accounts.append(AccountInfo(
                    key: key,
                    email: data.accountDisplayName ?? directAuthEmailsByKey[key] ?? key,
                    status: "active",
                    statusColor: .green,
                    authFile: nil,
                    quotaData: data,
                    subscriptionInfo: subscriptionInfos[key]
                ))
            }
        }

        let sorted = accounts.sorted { $0.email < $1.email }

        // Float the account currently in use (Antigravity IDE) to the top,
        // keeping the alphabetical order as the tie-breaker.
        guard provider == .antigravity else { return sorted }
        return AccountSorting.prioritizingActive(sorted) {
            viewModel.isAntigravityAccountActive(email: $0.email)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            if allAccounts.isEmpty && isLoading {
                QuotaLoadingView()
            } else if allAccounts.isEmpty {
                emptyState
            } else {
                ForEach(allAccounts, id: \.key) { account in
                    AccountQuotaCardV2(
                        provider: provider,
                        account: account,
                        isLoading: isLoading && account.quotaData == nil
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("quota.noDataYet".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
    }
}

// MARK: - Account Info

private struct AccountInfo {
    let key: String
    let email: String
    let status: String
    let statusColor: Color
    let authFile: AuthFile?
    let quotaData: ProviderQuotaData?
    let subscriptionInfo: SubscriptionInfo?
}

// MARK: - Account Quota Card V2

private struct AccountQuotaCardV2: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    let provider: AIProvider
    let account: AccountInfo
    let isLoading: Bool

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
            accountHeader

            // 即使刷新失败后继续保留可用缓存，也明确展示失败原因和该缓存的更新时间。
            AccountQuotaFreshnessView(provider: provider, accountKey: account.key, data: account.quotaData)

            if isLoading {
                QuotaLoadingView()
            } else if hasQuotaData {
                usageSection
            } else if let message = account.authFile?.humanReadableStatus {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 16)
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let info = account.subscriptionInfo {
                        SubscriptionBadgeV2(info: info)
                    } else if let planName = account.quotaData?.planDisplayName {
                        PlanBadgeV2Compact(planName: planName)
                    }

                    Text(displayEmail)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }

                // Show token expiry for Kiro accounts
                if let quotaData = account.quotaData, let tokenExpiry = quotaData.formattedTokenExpiry {
                    HStack(spacing: 4) {
                        Image(systemName: "key")
                            .font(.caption2)
                        Text(tokenExpiry)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                if account.status != "ready" && account.status != "active" {
                    Text(account.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(account.statusColor)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if provider == .antigravity {
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

                if isActiveInIDE {
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

                if provider == .antigravity && !isActiveInIDE {
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

    private var displayStyle: QuotaDisplayStyle { settings.quotaDisplayStyle }

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
            .sheet(isPresented: $showModelsDetailSheet) {
                AntigravityModelsDetailSheet(
                    email: account.email,
                    models: data.models
                )
            }
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

    @ViewBuilder
    private var antigravityContentByStyle: some View {
        switch displayStyle {
        case .lowestBar:
            AntigravityLowestBarLayout(groups: antigravityDisplayGroups)
        case .ring:
            AntigravityRingLayout(groups: antigravityDisplayGroups)
        case .card:
            VStack(spacing: 12) {
                ForEach(antigravityDisplayGroups) { group in
                    AntigravityGroupRow(group: group)
                }
            }
        }
    }

    @ViewBuilder
    private func standardContentByStyle(data: ProviderQuotaData) -> some View {
        let isCard = displayStyle == .card
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

            if isCard {
                meterContentByStyle(models: standaloneModels)
            } else {
                ForEach(standaloneModels) { model in
                    StandaloneMetricRow(model: model)
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
            VStack(spacing: 12) {
                ForEach(models) { model in
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
}

/// 单独的时间视图每分钟更新缓存状态，不触发上游请求，也不使整张配额卡片轮询刷新。
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

// MARK: - Plan Badge V2 Compact (for header inline display)

private struct PlanBadgeV2Compact: View {
    let planName: String

    private var tierConfig: (name: String, color: Color) {
        let lowercased = planName.lowercased()

        // Check for Pro variants
        if lowercased.contains("pro") {
            return ("Pro", .purple)
        }

        // Check for Plus
        if lowercased.contains("plus") {
            return ("Plus", .blue)
        }

        // Check for Team
        if lowercased.contains("team") {
            return ("Team", .orange)
        }

        // Check for Enterprise
        if lowercased.contains("enterprise") {
            return ("Enterprise", .red)
        }

        // Free/Standard
        if lowercased.contains("free") || lowercased.contains("standard") {
            return ("Free", .secondary)
        }

        // Default: use display name
        let displayName = planName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return (displayName, .secondary)
    }

    var body: some View {
        Text(tierConfig.name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tierConfig.color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Plan Badge V2

private struct PlanBadgeV2: View {
    let planName: String

    private var planConfig: (color: Color, icon: String) {
        let lowercased = planName.lowercased()

        // Handle compound names like "Pro Student"
        if lowercased.contains("pro") && lowercased.contains("student") {
            return (.purple, "graduationcap.fill")
        }

        switch lowercased {
        case "pro":
            return (.purple, "crown.fill")
        case "plus":
            return (.blue, "plus.circle.fill")
        case "team":
            return (.orange, "person.3.fill")
        case "enterprise":
            return (.red, "building.2.fill")
        case "free":
            return (.secondary, "person.fill")
        case "student":
            return (.green, "graduationcap.fill")
        default:
            return (.secondary, "person.fill")
        }
    }

    private var displayName: String {
        planName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: planConfig.icon)
                .font(.caption)
            Text(displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(planConfig.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(planConfig.color.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Subscription Badge V2

private struct SubscriptionBadgeV2: View {
    let info: SubscriptionInfo

    private var tierConfig: (name: String, color: Color) {
        let tierId = info.tierId.lowercased()
        let tierName = info.tierDisplayName.lowercased()

        // Check for Ultra tier (highest priority)
        if tierId.contains("ultra") || tierName.contains("ultra") {
            return ("Ultra", .orange)
        }

        // Check for Pro tier
        if tierId.contains("pro") || tierName.contains("pro") {
            return ("Pro", .purple)
        }

        // Check for Free/Standard tier
        if tierId.contains("standard") || tierId.contains("free") ||
           tierName.contains("standard") || tierName.contains("free") {
            return ("Free", .secondary)
        }

        // Fallback: use the display name from API
        return (info.tierDisplayName, .secondary)
    }

    var body: some View {
        Text(tierConfig.name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tierConfig.color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Antigravity Display Group

// MARK: - Antigravity Group Row

private struct AntigravityGroupRow: View {
    let group: AntigravityDisplayGroup

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var remainingPercent: Double {
        group.percentage
    }

    private var groupIcon: String {
        if group.name.contains("Claude") { return "brain.head.profile" }
        if group.name.contains("Image") { return "photo" }
        if group.name.contains("Flash") { return "bolt.fill" }
        return "sparkles"
    }

    var body: some View {
        let displayPercent = remainingPercent < 0 ? 0 : displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor: Color = remainingPercent < 0 ? .secondary : displayHelper.statusColor(remainingPercent: remainingPercent)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: groupIcon)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                Text(group.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if group.models.count > 1 {
                    Text(String(group.models.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }

                Spacer()

                Text(remainingPercent < 0 ? "—" : String(format: "%.0f%%", displayPercent))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()

                if let firstModel = group.models.first,
                   firstModel.formattedResetTime != "—" && !firstModel.formattedResetTime.isEmpty {
                    Text(firstModel.formattedResetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(statusColor.gradient)
                        .frame(width: proxy.size.width * (displayPercent / 100))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Antigravity Lowest Bar Layout

private struct AntigravityLowestBarLayout: View {
    @Environment(\.colorScheme) private var colorScheme
    let groups: [AntigravityDisplayGroup]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var sorted: [AntigravityDisplayGroup] {
        // 共用明细已将未知额度放在末尾，避免未知值抢占最低额度主行。
        groups
    }

    private var lowest: AntigravityDisplayGroup? {
        sorted.first
    }

    private var others: [AntigravityDisplayGroup] {
        Array(sorted.dropFirst())
    }

    private func displayPercent(for remainingPercent: Double) -> Double {
        remainingPercent < 0 ? 0 : displayHelper.displayPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let lowest = lowest {
                let statusColor = lowest.percentage < 0 ? Color.secondary : displayHelper.statusColor(remainingPercent: lowest.percentage)
                // Hero row for bottleneck
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(lowest.percentage < 0 ? "—" : String(format: "%.0f%%", displayPercent(for: lowest.percentage)))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(statusColor)
                            .monospacedDigit()
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(statusColor.gradient)
                                .frame(width: proxy.size.width * (displayPercent(for: lowest.percentage) / 100))
                        }
                    }
                    .frame(height: 8)
                }
                .padding(11)
                .background(
                    statusColor.opacity(colorScheme == .dark ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            statusColor.opacity(colorScheme == .dark ? 0.28 : 0.16),
                            lineWidth: 0.5
                        )
                )
            }

            // Others as compact text rows
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others) { group in
                        HStack {
                            Text(group.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(group.percentage < 0 ? "—" : String(format: "%.0f%%", displayPercent(for: group.percentage)))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle((group.percentage < 0 ? Color.secondary : displayHelper.statusColor(remainingPercent: group.percentage)))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Antigravity Ring Layout

private struct AntigravityRingLayout: View {
    let groups: [AntigravityDisplayGroup]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var columns: [GridItem] {
        let count = min(max(groups.count, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func ringPercent(for remainingPercent: Double) -> Double {
        displayHelper.ringPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(groups) { group in
                VStack(spacing: 6) {
                    RingProgressView(
                        percent: ringPercent(for: group.percentage),
                        size: 44,
                        lineWidth: 5,
                        tint: (group.percentage < 0 ? Color.secondary : displayHelper.statusColor(remainingPercent: group.percentage)),
                        showLabel: true
                    )

                    Text(group.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Standard Lowest Bar Layout

private struct StandardLowestBarLayout: View {
    @Environment(\.colorScheme) private var colorScheme
    let models: [ModelQuota]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var sorted: [ModelQuota] {
        // 未知值排在最后，不能覆盖真实最低额度；同值按模型身份稳定排序。
        QuotaPercentagePresentation.sorted(models)
    }

    private var lowest: ModelQuota? {
        sorted.first
    }

    private var others: [ModelQuota] {
        Array(sorted.dropFirst())
    }

    private func displayPercent(for remainingPercent: Double) -> Double {
        displayHelper.displayPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let lowest = lowest {
                let statusColor = displayHelper.statusColor(remainingPercent: lowest.percentage)
                // Hero row for bottleneck
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.displayName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(displayHelper.percentText(remainingPercent: lowest.percentage))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(statusColor)
                            .monospacedDigit()
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                            if QuotaPercentagePresentation.isKnown(lowest.percentage) {
                                Capsule()
                                    .fill(statusColor.gradient)
                                    .frame(width: proxy.size.width * (displayPercent(for: lowest.percentage) / 100))
                            }
                        }
                    }
                    .frame(height: 8)

                    if lowest.formattedResetTime != "—" && !lowest.formattedResetTime.isEmpty {
                        Text(lowest.formattedResetTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(11)
                .background(
                    statusColor.opacity(colorScheme == .dark ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            statusColor.opacity(colorScheme == .dark ? 0.28 : 0.16),
                            lineWidth: 0.5
                        )
                )
            }

            // Others as compact text rows
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others) { model in
                        HStack {
                            Text(model.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                                Text(model.formattedResetTime)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(displayHelper.percentText(remainingPercent: model.percentage))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(displayHelper.statusColor(remainingPercent: model.percentage))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Standard Ring Layout

private struct StandardRingLayout: View {
    let models: [ModelQuota]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var columns: [GridItem] {
        let count = min(max(models.count, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func ringPercent(for remainingPercent: Double) -> Double {
        displayHelper.ringPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(models) { model in
                VStack(spacing: 6) {
                    RingProgressView(
                        percent: ringPercent(for: model.percentage),
                        size: 44,
                        lineWidth: 5,
                        tint: displayHelper.statusColor(remainingPercent: model.percentage),
                        showLabel: true
                    )

                    Text(model.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                        Text(model.formattedResetTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Antigravity Models Detail Sheet

private struct AntigravityModelsDetailSheet: View {
    let email: String
    let models: [ModelQuota]

    @Environment(\.dismiss) private var dismiss

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var sortedModels: [ModelQuota] {
        models.sorted { $0.name < $1.name }
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("quota.allModels".localized())
                        .font(.headline)
                    Text(email.masked(if: settings.hideSensitiveInfo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("action.close".localized())
            }
            .padding()

            Divider()
                .opacity(0.5)

            // Models Grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sortedModels) { model in
                        ModelDetailCard(model: model)
                    }
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(.background)
    }
}

// MARK: - Model Detail Card (for sheet)

private struct ModelDetailCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelQuota

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var remainingPercent: Double {
        // 保留上游未知哨兵，避免详情页与主卡片对同一模型分别显示耗尽和未知。
        model.percentage
    }

    var body: some View {
        let displayPercent = displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor = displayHelper.statusColor(remainingPercent: remainingPercent)

        VStack(alignment: .leading, spacing: 8) {
            // Model name (raw name)
            Text(model.name)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Progress bar
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    if QuotaPercentagePresentation.isKnown(remainingPercent) {
                        Capsule()
                            .fill(statusColor.gradient)
                            .frame(width: proxy.size.width * (displayPercent / 100))
                    }
                }
            }
            .frame(height: 6)

            // Footer: Percentage + Reset time
            HStack {
                Text(displayHelper.percentText(remainingPercent: remainingPercent))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()

                Spacer()

                if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                    Text(model.formattedResetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
        )
    }
}

// MARK: - Usage Row V2

private struct UsageRowV2: View {
    let name: String
    let icon: String?
    let usedPercent: Double
    let used: Int?
    let limit: Int?
    let formattedUsage: String?
    let resetTime: String
    let tooltip: String?

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var isUnknown: Bool {
        usedPercent < 0 || usedPercent > 100
    }

    private var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var body: some View {
        let displayPercent = displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor = displayHelper.statusColor(remainingPercent: remainingPercent)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                }

                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .help(tooltip ?? "")

                Spacer()

                if let formattedUsage {
                    Text(formattedUsage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else if let used = used {
                    if let limit = limit, limit > 0 {
                        Text(String(used) + "/" + String(limit))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                if !isUnknown {
                    Text(String(format: "%.0f%%", displayPercent))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                if resetTime != "—" && !resetTime.isEmpty {
                    Text(resetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !isUnknown {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(statusColor.gradient)
                            .frame(width: proxy.size.width * (displayPercent / 100))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

private struct StandaloneMetricRow: View {
    let model: ModelQuota

    var body: some View {
        HStack(spacing: 10) {
            Text(model.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            Text(model.formattedUsage ?? "—")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .help(model.tooltip ?? "")
    }
}

// MARK: - Loading View

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

// MARK: - Preview

#Preview {
    QuotaScreen()
        .environment(QuotaViewModel())
        .frame(width: 600, height: 500)
}
