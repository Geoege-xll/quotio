//
//  CurrentModeBadge.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Compact badge showing current operating mode in sidebar footer
//

import SwiftUI

/// Compact badge showing current mode in sidebar, clickable to open settings
struct CurrentModeBadge: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var modeManager = OperatingModeManager.shared
    @State private var isHovered = false

    var body: some View {
        Button {
            viewModel.currentPage = .settings
        } label: {
            HStack(spacing: 9) {
                // Squircle Mode Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(modeIconGradient)
                        .frame(width: 22, height: 22)
                        .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)

                    Image(systemName: modeIconSymbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)

                // Mode name & status
                VStack(alignment: .leading, spacing: 1) {
                    Text(modeName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    // Status subtitle
                    Text(statusText)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Chevron indicator
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("sidebar.modeBadge.hint".localized())
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var modeIconSymbol: String {
        switch modeManager.currentMode {
        case .monitor:
            return "chart.bar.fill"
        case .localProxy:
            return "server.rack"
        }
    }

    private var modeIconGradient: LinearGradient {
        switch modeManager.currentMode {
        case .monitor:
            return LinearGradient(
                colors: [Color(red: 0.020, green: 0.588, blue: 0.412), Color(red: 0.063, green: 0.725, blue: 0.506)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .localProxy:
            return LinearGradient(
                colors: [Color(red: 0.145, green: 0.388, blue: 0.922), Color(red: 0.231, green: 0.510, blue: 0.965)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var modeName: String {
        switch modeManager.currentMode {
        case .monitor:
            return "mode.monitor".localized()
        case .localProxy:
            return "mode.localProxy".localized()
        }
    }

    private var statusText: String {
        switch modeManager.currentMode {
        case .monitor:
            let count = viewModel.monitorAccounts.count
            return String(format: "sidebar.modeBadge.accounts".localized(), count)
        case .localProxy:
            if viewModel.proxyManager.proxyStatus.running {
                return ":" + String(viewModel.proxyManager.port) + " - " + "status.running".localized()
            } else {
                return "status.stopped".localized()
            }
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if isHovered {
            QuotioTheme.Colors.cardElevated(for: colorScheme)
        } else {
            QuotioTheme.Colors.cardInset(for: colorScheme)
        }
    }
}

#Preview {
    CurrentModeBadge()
        .environment(QuotaViewModel())
        .padding()
        .frame(width: 200)
}
