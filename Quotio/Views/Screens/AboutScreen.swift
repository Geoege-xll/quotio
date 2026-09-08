//
//  AboutScreen.swift
//  Quotio
//

import SwiftUI
import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

// MARK: - About Screen

struct AboutScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showCopiedToast = false
    @State private var isHoveringVersion = false
    @State private var updaterService = UpdaterService.shared

    private var appVersion: String {
        AppIdentity.version
    }

    private var buildNumber: String {
        AppIdentity.build
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero Section
                heroSection

                // Description Card
                descriptionSection

                // Updates Section
                updatesSection

                // Links Section
                linksSection
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 48)
        }
        .quotioPage()
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                versionCopyToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showCopiedToast)
        .onAppear {
            #if canImport(Sparkle)
            updaterService.initializeIfNeeded()
            #endif
        }
        .navigationTitle("nav.about".localized())
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 16) {
            // App Icon with subtle depth & refined glow
            ZStack {
                // Subtle radial glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.blue.opacity(colorScheme == .dark ? 0.28 : 0.16),
                                Color.purple.opacity(colorScheme == .dark ? 0.16 : 0.08),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 75
                        )
                    )
                    .frame(width: 150, height: 150)
                    .blur(radius: 20)

                // App Icon
                appIconView
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.14),
                        radius: 16,
                        x: 0,
                        y: 6
                    )
            }

            // App Name & Tagline
            VStack(spacing: 6) {
                Text(verbatim: AppIdentity.displayName)
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("about.tagline".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Interactive Version Pill (Click to copy)
            versionPill
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var appIconView: some View {
        if let appIcon = updaterService.currentAppIcon {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
        } else if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.blue)
        }
    }

    // MARK: - Version Pill

    private var versionPill: some View {
        Button {
            copyVersionToClipboard()
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text("Version \(appVersion)")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Text("•")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 4) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Build \(buildNumber)")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Image(systemName: showCopiedToast ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(showCopiedToast ? .green : .secondary.opacity(0.7))
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                isHoveringVersion
                    ? QuotioTheme.Colors.cardElevated(for: colorScheme)
                    : QuotioTheme.Colors.cardInset(for: colorScheme),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isHoveringVersion
                            ? Color.blue.opacity(0.3)
                            : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringVersion = hovering
            }
        }
        .help("Click to copy full version info")
    }

    private func copyVersionToClipboard() {
        let fullVersion = AppIdentity.versionDescription
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullVersion, forType: .string)

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        showCopiedToast = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedToast = false
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        Text(String(format: "about.description".localized(), AppIdentity.displayName))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                QuotioTheme.Colors.cardBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.03),
                radius: 10,
                x: 0,
                y: 2
            )
    }

    // MARK: - Updates Section

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                Text("settings.updates".localized())
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 12) {
                AboutUpdateCard()

                if OperatingModeManager.shared.isLocalProxyMode {
                    AboutProxyUpdateCard()
                }
            }
        }
    }

    // MARK: - Links Section

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Links")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                LinkCard(
                    title: "GitHub: " + AppIdentity.displayName,
                    subtitle: "github.com/" + AppReleaseConfiguration.repository,
                    icon: "chevron.left.forwardslash.chevron.right",
                    color: .blue,
                    url: AppReleaseConfiguration.repositoryURL
                )

                LinkCard(
                    title: "GitHub: CLIProxyAPI",
                    subtitle: "github.com/router-for-me/CLIProxyAPI",
                    icon: "terminal.fill",
                    color: .purple,
                    url: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
                )
            }
        }
    }

    // MARK: - Version Copy Toast

    private var versionCopyToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Version copied to clipboard")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            QuotioTheme.Colors.cardBackground(for: colorScheme),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 14, x: 0, y: 5)
        .padding(.bottom, 24)
    }
}

// MARK: - About Update Card

struct AboutUpdateCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @State private var isHovered = false

    #if canImport(Sparkle)
    private let updaterService = UpdaterService.shared
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 32, height: 32)

                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: AppIdentity.displayName)
                        .font(.headline)
                        .fontWeight(.semibold)

                    #if canImport(Sparkle)
                    Text(updaterService.updateChannel.displayName)
                        .font(.caption2)
                        .foregroundStyle(updaterService.updateChannel == .beta ? .orange : .secondary)
                    #endif
                }

                Spacer()

                #if canImport(Sparkle)
                Button(updaterService.checkButtonTitleKey.localized()) {
                    updaterService.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                #endif
            }

            Divider()
                .opacity(0.6)

            #if canImport(Sparkle)
            // Options
            VStack(spacing: 10) {
                HStack {
                    Text("settings.autoCheckUpdates".localized())
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $autoCheckUpdates)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: autoCheckUpdates) { _, newValue in
                            updaterService.automaticallyChecksForUpdates = newValue
                        }
                }

                HStack {
                    Text("settings.updateChannel.receiveBeta".localized())
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { updaterService.updateChannel == .beta },
                        set: { newValue in
                            updaterService.updateChannel = newValue ? .beta : .stable
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            .disabled(!updaterService.supportsAutomaticUpdates)

            if !updaterService.supportsAutomaticUpdates {
                Text("updates.own.manualOnly".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Footer: Last checked info
            HStack {
                Image(systemName: "clock")
                    .font(.caption2)
                Text("settings.lastChecked".localized())
                Spacer()
                if let date = updaterService.lastUpdateCheckDate {
                    UpdateCheckTimestamp(date: date)
                } else {
                    Text("settings.never".localized())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            #else
            Text("settings.version".localized() + ": " + (AppIdentity.version))
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            QuotioTheme.Colors.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.35 : (isHovered ? 0.08 : 0.04)),
            radius: colorScheme == .dark ? 14 : (isHovered ? 8 : 4),
            x: 0,
            y: colorScheme == .dark ? 5 : (isHovered ? 2 : 1)
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - About Proxy Update Card

struct AboutProxyUpdateCard: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var showAdvancedSheet = false
    @State private var isCheckingForUpdate = false
    @State private var isUpgrading = false
    @State private var upgradeError: String?

    private var proxyManager: CLIProxyManager {
        viewModel.proxyManager
    }

    private var atomFeedService: AtomFeedUpdateService {
        AtomFeedUpdateService.shared
    }

    private var currentVersionText: String {
        if let version = proxyManager.currentVersion ?? proxyManager.installedProxyVersion {
            return "v\(version)"
        }
        return "Not installed"
    }

    private var statusText: String {
        if proxyManager.currentVersion == nil && proxyManager.installedProxyVersion == nil {
            return "Install required"
        }

        if proxyManager.upgradeAvailable, let upgrade = proxyManager.availableUpgrade {
            return "Update available: v\(upgrade.version)"
        }

        return "Up to date"
    }

    private var statusColor: Color {
        if upgradeError != nil {
            return .orange
        }
        if proxyManager.upgradeAvailable {
            return .green
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 32, height: 32)

                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.proxyUpdate".localized())
                        .font(.headline)
                        .fontWeight(.semibold)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(statusColor == .secondary ? .secondary : statusColor)
                    }
                }

                Spacer()

                // Current version tag
                Text(currentVersionText)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        QuotioTheme.Colors.cardInset(for: colorScheme),
                        in: Capsule()
                    )
                    .foregroundStyle(.secondary)
            }

            Divider()
                .opacity(0.6)

            if let error = upgradeError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Action row
            HStack(spacing: 10) {
                Button {
                    checkForUpdate()
                } label: {
                    ZStack {
                        Text("settings.proxyUpdate.checkNow".localized())
                            .opacity(isCheckingForUpdate ? 0 : 1)

                        if isCheckingForUpdate {
                            SmallProgressView()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCheckingForUpdate)

                if let upgrade = proxyManager.availableUpgrade {
                    Button {
                        performUpgrade(to: upgrade)
                    } label: {
                        ZStack {
                            Text("action.update".localized())
                                .opacity(isUpgrading ? 0 : 1)

                            if isUpgrading {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isUpgrading)
                }

                Spacer()

                if let lastCheck = atomFeedService.lastCLIProxyCheck {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        UpdateCheckTimestamp(date: lastCheck)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Button {
                    showAdvancedSheet = true
                } label: {
                    HStack(spacing: 3) {
                        Text("settings.proxyUpdate.advanced".localized())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            QuotioTheme.Colors.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.35 : (isHovered ? 0.08 : 0.04)),
            radius: colorScheme == .dark ? 14 : (isHovered ? 8 : 4),
            x: 0,
            y: colorScheme == .dark ? 5 : (isHovered ? 2 : 1)
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .sheet(isPresented: $showAdvancedSheet) {
            ProxyVersionManagerSheet()
                .environment(viewModel)
        }
    }

    private func checkForUpdate() {
        isCheckingForUpdate = true
        upgradeError = nil

        Task { @MainActor in
            defer {
                isCheckingForUpdate = false
            }

            await proxyManager.checkForUpgrade()
        }
    }

    private func performUpgrade(to version: ProxyVersionInfo) {
        isUpgrading = true
        upgradeError = nil

        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: version)
                isUpgrading = false
            } catch {
                upgradeError = error.localizedDescription
                isUpgrading = false
            }
        }
    }
}

// MARK: - Link Card

struct LinkCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String?
    let icon: String
    let color: Color
    let url: URL?
    let action: (() -> Void)?

    @State private var isHovered = false

    init(
        title: String,
        subtitle: String? = nil,
        icon: String,
        color: Color,
        url: URL? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.url = url
        self.action = action
    }

    var body: some View {
        Button {
            if let url = url {
                NSWorkspace.shared.open(url)
            } else if let action = action {
                action()
            }
        } label: {
            HStack(spacing: 12) {
                // Icon squircle
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(isHovered ? 0.18 : 0.09))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isHovered ? color : color.opacity(0.85))
                }

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(isHovered ? color : .primary)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // Arrow icon (for external links)
                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovered ? color : .secondary.opacity(0.5))
                        .offset(x: isHovered ? 1 : 0, y: isHovered ? -1 : 0)
                }
            }
            .padding(12)
            .background(
                isHovered
                    ? QuotioTheme.Colors.cardElevated(for: colorScheme)
                    : QuotioTheme.Colors.cardBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? color.opacity(0.3)
                            : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? (isHovered ? 0.4 : 0.25) : (isHovered ? 0.08 : 0.03)),
                radius: colorScheme == .dark ? (isHovered ? 16 : 10) : (isHovered ? 8 : 4),
                x: 0,
                y: colorScheme == .dark ? 5 : (isHovered ? 2 : 1)
            )
            .scaleEffect(isHovered ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
