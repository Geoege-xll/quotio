//
//  LocalPathsSection.swift
//  Quotio
//

// 本地二进制、配置与认证目录展示分区，PathLabel 与唯一使用它的分区共同维护。
// 路径仍直接读取原环境中的代理管理器；复制按钮继续写同一系统剪贴板，
// 本次文件归位不迁移用户数据，也不增加新的路径状态或文件操作。

import SwiftUI
import AppKit

// MARK: - Local Paths Section

struct LocalPathsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    var body: some View {
        Section {
            LabeledContent("settings.binary".localized()) {
                PathLabel(path: viewModel.proxyManager.effectiveBinaryPath)
            }
            
            LabeledContent("settings.config".localized()) {
                PathLabel(path: viewModel.proxyManager.configPath)
            }
            
            LabeledContent("settings.authDir".localized()) {
                PathLabel(path: viewModel.proxyManager.authDir)
            }
        } header: {
            Label("settings.paths".localized(), systemImage: "folder")
        }
    }
}

// MARK: - Path Label

struct PathLabel: View {
    let path: String
    
    var body: some View {
        HStack {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}

