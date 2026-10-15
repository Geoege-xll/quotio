//
//  WarpConnectionSheet.swift
//  Quotio
//
//  Dedicated connection sheet for Warp AI Terminal.
//

import SwiftUI

struct WarpConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let token: WarpService.WarpToken?
    let onSave: (String, String) -> Void

    @State private var name: String = ""
    @State private var tokenString: String = ""

    private var isEditing: Bool {
        token != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formContentSection
                }
                .padding(20)
            }

            footerView
        }
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .frame(width: 460, height: 370)
        .onAppear {
            if let token = token {
                name = token.name
                tokenString = token.token
            }
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            Image("warp")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "warp.connection.edit".localized() : "warp.connection.title".localized())
                    .font(.headline)

                Text("warp.connection.subtitle".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            QuotioCircularIconButton(systemImage: "xmark") {
                dismiss()
            }
            .accessibilityLabel("action.cancel".localized())
        }
        .padding(20)
    }

    private var formContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("customProviders.providerName".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                QuotioCapsuleTextField("warp.name.placeholder".localized(), text: $name, systemImage: "tag")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("warp.token.label".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let docsURL = URL(string: "https://docs.warp.dev/platform/cli#generating-api-keys") {
                        Link(destination: docsURL) {
                            HStack(spacing: 4) {
                                Text("warp.token.get".localized())
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.caption)
                        }
                    }
                }

                QuotioCapsuleSecureField("warp.token.placeholder".localized(), text: $tokenString, systemImage: "key")

                Text("warp.token.description".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .quotioInsetCard()
    }

    private var footerView: some View {
        HStack {
            Button("action.cancel".localized()) {
                dismiss()
            }
            .buttonStyle(.quotioSecondaryCapsule)
            .keyboardShortcut(.escape)

            Spacer()

            Button(isEditing ? "action.save".localized() : "action.connect".localized()) {
                onSave(name, tokenString)
                dismiss()
            }
            .buttonStyle(.quotioPrimaryCapsule)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || tokenString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
    }
}
