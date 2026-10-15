import SwiftUI

/// 提示框只观察共享删除状态，不在 View 生命周期中启动删除任务，避免重复展示造成重复删除。
/// 进行中禁止手动关闭；全部成功由 ViewModel 自动收起，失败结果由用户阅读后关闭。
struct WorkspaceSessionDeletionProgressSheet: View {
    let viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress = viewModel.sessionDeletionProgress {
                WorkspaceSessionDeletionProgressContent(progress: progress)
                if progress.isFinished {
                    HStack {
                        Spacer()
                        Button("关闭") {
                            viewModel.dismissSessionDeletionProgress()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("sessionDeletionResultClose")
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .interactiveDismissDisabled(viewModel.isDeletingSessions)
        .accessibilityIdentifier("sessionDeletionProgressSheet")
    }
}

/// 独立展示视图便于验证各阶段；计时仅在小范围 TimelineView 更新，不使整个会话列表每秒重绘。
struct WorkspaceSessionDeletionProgressContent: View {
    let progress: WorkspaceSessionDeletionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill((progress.isFinished ? QuotioTheme.Colors.warning : Color.accentColor).opacity(0.12))
                        .frame(width: 36, height: 36)
                    if progress.isFinished {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(QuotioTheme.Colors.warning)
                    } else {
                        SmallProgressView(size: 20)
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(progress.title)
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("sessionDeletionPhase")
                    Text(progress.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !progress.currentSessionTitle.isEmpty, progress.phase == .deleting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("正在处理 · \(progress.currentAgentName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(progress.currentSessionTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .help(progress.currentSessionTitle)
                        .accessibilityIdentifier("sessionDeletionCurrentSession")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .quotioInsetCard(cornerRadius: QuotioTheme.Radius.md, padding: 12)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !progress.isFinished {
                    // 单项内部没有可验证的文件百分比，使用持续动画；批量仅按真实完成项推进。
                    if progress.phase == .deleting, progress.totalCount > 1 {
                        ProgressView(value: Double(progress.processedCount), total: Double(progress.totalCount))
                            .accessibilityLabel("会话删除进度")
                            .accessibilityValue("已处理 \(progress.processedCount) 项，共 \(progress.totalCount) 项")
                    } else {
                        ProgressView().progressViewStyle(.linear)
                            .accessibilityLabel(progress.title)
                    }
                }
                HStack {
                    if progress.totalCount > 0 {
                        Text("已处理 \(progress.processedCount) / \(progress.totalCount) 项")
                            .accessibilityIdentifier("sessionDeletionCount")
                    }
                    Spacer()
                    if let finishedAt = progress.finishedAt {
                        Text(progress.elapsedText(at: finishedAt))
                            .accessibilityIdentifier("sessionDeletionElapsed")
                    } else {
                        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                            Text(progress.elapsedText(at: context.date))
                                .accessibilityIdentifier("sessionDeletionElapsed")
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            if progress.isFinished {
                Text("成功 \(progress.result.succeededCount) 项，失败 \(progress.result.failures.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                ScrollView {
                    Text(progress.result.failures.joined(separator: "\n\n"))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .quotioInsetCard(cornerRadius: QuotioTheme.Radius.md, padding: 12)
                .accessibilityIdentifier("sessionDeletionFailures")
            } else if progress.includesDescendants {
                Text("主会话及其关联子任务合并为一项处理。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
