import SwiftUI

/// Antigravity 全部模型明细弹窗，弹窗是否显示仍由 AccountQuotaContent 的原 @State 决定。
/// 对照上游 PR #558，只接收调用方已经读取的展示值，不再隐式读取设置环境或全局单例。
/// 这样弹窗和懒加载卡片使用同一份偏好，也能在未装配应用环境的独立宿主中安全布局；
/// 设置的所有权、模型原始名称排序及 dismiss 仍留在原来的宿主和展示流程中。
struct AntigravityModelsDetailSheet: View {
    let email: String
    let models: [ModelQuota]
    let displayMode: QuotaDisplayMode
    let hideSensitiveInfo: Bool

    @Environment(\.dismiss) private var dismiss

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
            // 邮箱只占标题区可用宽度，防止长账号反过来撑大弹窗，挤出关闭按钮。
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("quota.allModels".localized())
                        .font(.headline)
                    Text(email.masked(if: hideSensitiveInfo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                .accessibilityLabel("action.close".localized())
                .help("action.close".localized())
            }
            .padding()

            Divider()
                .opacity(0.5)

            // 账号在弹窗打开期间刷新成空列表时仍展示明确状态，不把“无数据”误画成 0%。
            // 非空列表继续使用两列懒加载和原排序；仅内容滚动，标题与关闭操作始终可见。
            if models.isEmpty {
                Text("dashboard.noQuotaData".localized())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sortedModels) { model in
                            ModelDetailCard(model: model, displayMode: displayMode)
                        }
                    }
                    .padding()
                }
                .scrollContentBackground(.hidden)
            }
        }
        // 保留原最小尺寸，并给独立 sheet 明确的初始提议尺寸，避免由模型数量或长名称决定
        // 开窗大小。后续尺寸由窗口提供，滚动内容不回写尺寸状态，不形成测量／布局反馈环。
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 440)
        .background(.background)
        // 使用内容的明确理想尺寸创建 sheet，避免 automatic 的表单提议尺寸在空列表
        // 首次呈现时又被尺寸观察回调修正，进而在 NSHostingView.layout 内再次调整窗口。
        // fitted 仍允许用户缩放，原最小尺寸、滚动及显示状态所有权都不改变。
        .presentationSizing(.fitted)
    }
}

/// 仅供本弹窗使用的模型详情卡片，保留 private，避免将局部展示实现扩散为公共组件。
private struct ModelDetailCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelQuota
    let displayMode: QuotaDisplayMode

    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: displayMode)
    }

    private var remainingPercent: Double {
        // 保留上游未知哨兵，避免详情页与主卡片对同一模型分别显示耗尽和未知。
        model.percentage
    }

    var body: some View {
        let displayPercent = displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor = displayHelper.statusColor(remainingPercent: remainingPercent)

        VStack(alignment: .leading, spacing: 8) {
            // 保留模型原始名称；名称长度只影响截断，不参与弹窗宽度反向计算。
            Text(model.name)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // 只读取当前单元格宽度来绘制进度，不产生状态写入；未知值继续不绘制额度填充。
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

            // 保留已用／剩余模式的原换算和重置时间格式，不在弹窗另建额度计算规则。
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
