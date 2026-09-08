//
//  SidebarHeaderView.swift
//  Quotio
//
//  Profile/Identity header in sidebar showing App Icon, Name, and Version.
//

import SwiftUI
import AppKit

struct SidebarHeaderView: View {
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "Quotio"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "v\(version)"
    }

    private var appIcon: NSImage {
        NSImage(named: "AppIconImage")
            ?? NSApp.applicationIconImage
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Direct App Icon (no artificial circular mask, authentic macOS squircle)
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)

            // App Name & Version
            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(appVersion)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 0)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
    }
}
