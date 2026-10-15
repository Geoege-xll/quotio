import SwiftUI

/// Settings 高级选项与 Accounts 账号权重共用的文本数值输入，按已有双业务使用方归位。
/// 仅编辑调用方提供的 Binding；不增加本地草稿、不主动解析或保存，保留原标签、帮助和可访问性。
/// 权重与高级设置的不同校验及提交时机仍由各自原宿主决定，不在共享控件中合并。
/// 高级数值保留完整文本草稿，提交时统一校验；读取已有大值时不受 Stepper 上限夹取。
/// 每个输入都有可见标签，0 的含义在对应行解释，避免把“无限制”和“关闭”混为一谈。
struct CPASettingsNumberRow: View {
    let titleKey: String
    @Binding var text: String
    var helpKey: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(titleKey.localized()) {
                TextField(titleKey.localized(), text: $text)
                    // 原生 Form 会显示 TextField 自带标签；外层已有可见标签，隐藏内部标签避免重复挤占右列。
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 130)
                    .accessibilityIdentifier(titleKey)
                    .accessibilityLabel(titleKey.localized())
            }
            if let helpKey {
                Text(helpKey.localized()).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
