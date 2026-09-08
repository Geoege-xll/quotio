import SwiftUI

/// 复用设置页原生分组表单。上游发行信息和代码比较均为维护入口，不提供替换当前应用的动作。
struct UpstreamUpdatesScreen: View {
    @State private var checker = UpstreamReleaseChecker()
    @State private var checkRequest = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("updates.upstream.repository".localized(), value: AppReleaseConfiguration.upstreamRepository)
                LabeledContent("updates.upstream.currentApp".localized(), value: AppIdentity.versionDescription)
                HStack {
                    Button("settings.checkNow".localized()) { checkRequest += 1 }
                        .disabled(checker.isChecking)
                        .accessibilityIdentifier("checkUpstreamUpdatesButton")
                    if checker.isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    if let date = checker.lastChecked { UpdateCheckTimestamp(date: date).foregroundStyle(.secondary) }
                }
                if let key = checker.errorKey {
                    Label(key.localized(), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("updates.upstream.title".localized())
            } footer: {
                Text("updates.upstream.help".localized())
            }

            if let release = checker.release {
                Section {
                    LabeledContent("updates.upstream.latest".localized(), value: release.tag)
                    if let date = release.publishedAt {
                        LabeledContent("updates.upstream.published".localized()) { UpdateCheckTimestamp(date: date) }
                    }
                    Link("updates.upstream.releaseNotes".localized(), destination: release.releaseURL)
                    if let notes = release.notes, !notes.isEmpty {
                        // GitHub 发布正文作为普通文本展示，保留选择复制；不将外部文本解释为操作指令。
                        Text(verbatim: String(notes.prefix(12_000)))
                            .font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("updates.upstream.latest".localized()) }
            } else if checker.lastChecked != nil {
                Section { Text("updates.upstream.noRelease".localized()).foregroundStyle(.secondary) }
            }

            Section {
                Link("updates.upstream.source".localized(), destination: AppReleaseConfiguration.upstreamURL)
                Link("updates.upstream.compare".localized(), destination: AppReleaseConfiguration.repositoryURL.appendingPathComponent("compare"))
            } header: { Text("updates.upstream.sync".localized()) }
        }
        .formStyle(.grouped)
        .modifier(SettingsPageBackground())
        .navigationTitle("updates.upstream.title".localized())
        .task(id: checkRequest) {
            // task 随离开页面取消；同一次页面展示不会因为秒数、布局或其他设置变化反复请求。
            if checkRequest == 0 { await checker.checkIfNeeded() }
            else { await checker.check() }
        }
    }
}
