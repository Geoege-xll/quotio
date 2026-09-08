//
//  SidebarSquircleIcon.swift
//  Quotio
//
//  Standardized Apple 26 colorful squircle icons and comfortable taller sidebar labels.
//

import SwiftUI

struct SidebarSquircleIcon: View {
    let page: NavigationPage
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(page.sidebarGradient)
                .frame(width: size, height: size)
                .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)

            Image(systemName: page.sidebarSymbol)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Refined Sidebar Item Label

struct SidebarLabel: View {
    let title: String
    let page: NavigationPage
    var body: some View {
        HStack(spacing: 10) {
            SidebarSquircleIcon(page: page, size: 22)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

// MARK: - NavigationPage Sidebar Presentation Tokens

extension NavigationPage {
    /// SF Symbol customized for solid squircle visibility
    var sidebarSymbol: String {
        switch self {
        case .dashboard:
            return "gauge.with.dots.needle.33percent"
        case .usageStatistics:
            return "chart.xyaxis.line"
        case .callAnalytics:
            return "function"
        case .quota:
            return "chart.bar.fill"
        case .providers:
            return "person.2.fill"
        case .agents:
            return "terminal.fill"
        case .apiKeys:
            return "key.horizontal.fill"
        case .logs:
            return "doc.text.fill"
        case .settings:
            return "gearshape.fill"
        case .about:
            return "info.circle.fill"
        }
    }

    /// Vibrant gradients aligned with Apple 26 system settings palette & HTML prototype
    var sidebarGradient: LinearGradient {
        switch self {
        case .dashboard:
            // #2563eb -> #3b82f6
            return LinearGradient(
                colors: [Color(red: 0.145, green: 0.388, blue: 0.922), Color(red: 0.231, green: 0.510, blue: 0.965)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .usageStatistics:
            // #059669 -> #10b981
            return LinearGradient(
                colors: [Color(red: 0.020, green: 0.588, blue: 0.412), Color(red: 0.063, green: 0.725, blue: 0.506)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .callAnalytics:
            // #6366f1 -> #8b5cf6
            return LinearGradient(
                colors: [Color(red: 0.388, green: 0.400, blue: 0.945), Color(red: 0.545, green: 0.361, blue: 0.965)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .quota:
            // #ea580c -> #f97316
            return LinearGradient(
                colors: [Color(red: 0.918, green: 0.345, blue: 0.047), Color(red: 0.976, green: 0.451, blue: 0.086)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .providers:
            // #0891b2 -> #06b6d4
            return LinearGradient(
                colors: [Color(red: 0.031, green: 0.569, blue: 0.698), Color(red: 0.024, green: 0.714, blue: 0.831)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .agents:
            // #334155 -> #475569
            return LinearGradient(
                colors: [Color(red: 0.200, green: 0.255, blue: 0.333), Color(red: 0.278, green: 0.333, blue: 0.412)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .apiKeys:
            // #d97706 -> #f59e0b
            return LinearGradient(
                colors: [Color(red: 0.851, green: 0.467, blue: 0.024), Color(red: 0.961, green: 0.620, blue: 0.043)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .logs:
            // #e11d48 -> #f43f5e
            return LinearGradient(
                colors: [Color(red: 0.882, green: 0.114, blue: 0.282), Color(red: 0.957, green: 0.247, blue: 0.369)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .settings:
            // #4b5563 -> #6b7280
            return LinearGradient(
                colors: [Color(red: 0.294, green: 0.333, blue: 0.388), Color(red: 0.420, green: 0.447, blue: 0.502)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .about:
            // #0284c7 -> #38bdf8
            return LinearGradient(
                colors: [Color(red: 0.008, green: 0.518, blue: 0.780), Color(red: 0.220, green: 0.741, blue: 0.973)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}
