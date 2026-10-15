//
//  YubiKeySettingsSection.swift
//  Quotio
//

// YubiKey 设置完整分区，身份、设备、状态投影与提示继续由本视图持有。
// 原私有 VaultStatus、配置完成重试和硬件刷新 Task 同整体迁移，
// 保留原导航、用户选用流程和密钥保护边界，不建立第二套硬件状态来源。

import SwiftUI
import AppKit

// MARK: - YubiKey Settings Section

struct YubiKeySettingsSection: View {
    /// What Quotio is configured to do right now, which is the first thing this
    /// section has to answer.
    private enum VaultStatus: Equatable {
        case notConfigured
        case active(name: String, fingerprint: String, secrets: Int)
        case keyMissing(fingerprint: String, secrets: Int)
    }

    @State private var identities: [YubiKeyPIVIdentity] = []
    @State private var devices: [YubiKeyPIVDevice] = []
    @State private var status: VaultStatus = .notConfigured
    @State private var yubiKeyConnected = false
    @State private var selectedID = ""
    @State private var selectedDeviceID = ""
    @State private var statusMessage: String?

    private var isConfigured: Bool {
        status != .notConfigured
    }

    var body: some View {
        Section {
            statusView
            actionsView

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("settings.yubikey.refresh".localized()) {
                // A stale message outlives the state it described, so drop it
                // rather than let it contradict the status row.
                statusMessage = nil
                Task { await refresh() }
            }
        } header: {
            Label("settings.yubikey.title".localized(), systemImage: "key.viewfinder")
        } footer: {
            Text("settings.yubikey.help".localized())
        }
        .task { await refresh() }

    }

    /// Exactly one story per state: adopt a key that already exists, or create
    /// one. Anything the status row already says is not repeated here.
    @ViewBuilder
    private var actionsView: some View {
        switch status {
        case .active:
            // Only worth offering when there is something else to switch to.
            if identities.count > 1 {
                identityPicker
                Button("settings.yubikey.change".localized()) { select() }
                    .disabled(selectedID.isEmpty)
            }

        case .keyMissing:
            // The status row already says which key to insert; nothing to do here.
            EmptyView()

        case .notConfigured:
            if !identities.isEmpty {
                identityPicker
                Button("settings.yubikey.use".localized()) { select() }
                    .disabled(selectedID.isEmpty)
            }

            // Still offered alongside an existing identity: that identity may
            // belong to another application, and provisioning would otherwise
            // be unreachable.
            if !devices.isEmpty {
                Picker("settings.yubikey.setupPicker".localized(), selection: $selectedDeviceID) {
                    ForEach(devices) { device in
                        Text(device.name + " (" + device.serial + ")").tag(device.id)
                    }
                }
                // 硬件配置页面使用系统 Push，成功后仍执行原有身份刷新和选用流程。
                if let device = devices.first(where: { $0.id == selectedDeviceID }) {
                    NavigationLink {
                        YubiKeyProvisioningSheet(device: device, usesNavigation: true) {
                            await completeProvisioning()
                        }
                    } label: {
                        Text("settings.yubikey.setup".localized())
                    }
                } else {
                    Button("settings.yubikey.setup".localized()) {}.disabled(true)
                }
            }

            if identities.isEmpty, devices.isEmpty {
                Label(
                    yubiKeyConnected
                        ? "settings.yubikey.detected".localized()
                        : "settings.yubikey.insert".localized(),
                    systemImage: yubiKeyConnected ? "key.badge.exclamationmark" : "key.slash"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var identityPicker: some View {
        Picker("settings.yubikey.identityPicker".localized(), selection: $selectedID) {
            ForEach(identities) { identity in
                Text(identity.name + " (" + String(identity.fingerprint.prefix(12)) + ")")
                    .tag(identity.id)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .notConfigured:
            Label("settings.yubikey.status.inactive".localized(), systemImage: "lock.open")
                .foregroundStyle(.secondary)

        case let .active(name, fingerprint, secrets):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(format: "settings.yubikey.status.active".localized(), name),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                Text(String(format: "settings.yubikey.status.activeDetail".localized(),
                            String(fingerprint.prefix(12)), secrets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .keyMissing(fingerprint, secrets):
            VStack(alignment: .leading, spacing: 4) {
                Label("settings.yubikey.status.missing".localized(), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(String(format: "settings.yubikey.status.missingDetail".localized(),
                            String(fingerprint.prefix(12)), secrets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func select() {
        guard let identity = identities.first(where: { $0.id == selectedID }) else { return }
        if YubiKeySecretVault.select(identity) {
            statusMessage = "settings.yubikey.selected".localized()
        } else {
            statusMessage = "settings.yubikey.changeBlocked".localized()
        }
        Task { await refresh() }
    }

    private func completeProvisioning() async {
        // macOS republishes the token's identities asynchronously, so the new key
        // is not always visible the instant ykman exits.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            await refresh()
            if !identities.isEmpty { break }
        }

        // ykman succeeded, so the key holds a Quotio identity — but macOS has
        // not surfaced it. Say so, rather than point at a picker that is empty
        // precisely because there is nothing to put in it.
        guard !identities.isEmpty else {
            statusMessage = "settings.yubikey.setupUnpublished".localized()
            return
        }

        // Another key is already protecting secrets; this one stays unused
        // until an explicit migration exists.
        guard !isConfigured else {
            statusMessage = "settings.yubikey.setupUnusedKeyConfigured".localized()
            return
        }

        // The new identity protects nothing yet. Adopt it so setup ends in a
        // state the status row reports as active instead of silently leaving it
        // idle. With several candidates, the choice stays with the user — and
        // only then does "choose the key below" describe a picker that exists.
        let provisioned = identities.first { $0.name == YubiKeySecretVault.identityName }
            ?? (identities.count == 1 ? identities.first : nil)
        if let provisioned, YubiKeySecretVault.select(provisioned) {
            statusMessage = "settings.yubikey.setupSucceeded".localized()
            await refresh()
        } else {
            statusMessage = "settings.yubikey.setupSucceededSelect".localized()
        }
    }

    private func refresh() async {
        let result = await Task.detached(priority: .userInitiated) {
            let identities = YubiKeySecretVault.availableIdentities()
            return (
                connected: YubiKeySecretVault.isYubiKeyConnected(),
                devices: YubiKeySecretVault.provisionableDevices(),
                identities: identities,
                selected: YubiKeySecretVault.identity(matching: identities),
                fingerprint: YubiKeySecretVault.selectedFingerprint,
                secrets: YubiKeySecretVault.protectedSecretCount
            )
        }.value

        yubiKeyConnected = result.connected
        devices = result.devices
        identities = result.identities
        if selectedDeviceID.isEmpty { selectedDeviceID = devices.first?.id ?? "" }

        switch (result.fingerprint, result.selected) {
        case let (_, .some(identity)):
            status = .active(name: identity.name, fingerprint: identity.fingerprint, secrets: result.secrets)
            selectedID = identity.id
        case let (.some(fingerprint), nil):
            status = .keyMissing(fingerprint: fingerprint, secrets: result.secrets)
            if selectedID.isEmpty { selectedID = identities.first?.id ?? "" }
        case (nil, nil):
            status = .notConfigured
            if selectedID.isEmpty { selectedID = identities.first?.id ?? "" }
        }
    }
}

