import SwiftUI

struct MonitorAPIKeyConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let provider: AIProvider
    let account: MonitorAccount?
    let onSave: (String, String) async throws -> Void

    @State private var label = ""
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var isEditing: Bool { account != nil }
    private var localizationPrefix: String {
        switch provider {
        case .factoryDroid: "factory"
        case .amp: "amp"
        default: "openrouter"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formContentSection

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(20)
            }

            footerView
        }
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .frame(width: 460, height: 380)
        .onAppear { label = account?.accountKey ?? "" }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 16) {
            ProviderIcon(provider: provider, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(isEditing ? "connection.edit" : "connection.title"))
                    .font(.headline)
                Text(localized("connection.subtitle"))
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

    // MARK: - Form Content

    private var formContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("customProviders.providerName".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                QuotioCapsuleTextField(localized("label.placeholder"), text: $label, systemImage: "tag")
                    .disabled(isEditing)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("apiKey.label"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                QuotioCapsuleSecureField(localized("apiKey.placeholder"), text: $apiKey, systemImage: "key")

                Text(localized(isEditing ? "apiKey.rotateHint" : "apiKey.hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .quotioInsetCard()
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("action.cancel".localized()) {
                dismiss()
            }
            .buttonStyle(.quotioSecondaryCapsule)
            .keyboardShortcut(.escape)
            .disabled(isSaving)

            Spacer()

            if isSaving {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 8)
            }

            Button(isEditing ? "action.save".localized() : "action.connect".localized()) {
                Task { await save() }
            }
            .buttonStyle(.quotioPrimaryCapsule)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || isSaving)
        }
        .padding(20)
    }

    private func localized(_ suffix: String) -> String {
        (localizationPrefix + "." + suffix).localized()
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(label, apiKey)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
