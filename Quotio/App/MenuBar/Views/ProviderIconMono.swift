//
//  ProviderIconMono.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏专用的单色提供商图标，供筛选区与账号卡片复用。
/// 只将完整类型改为模块内可见；保留原图标、颜色和尺寸，不合并到其他页面的 ProviderIcon。
// MARK: Monochrome Provider Icon

struct ProviderIconMono: View {
    let provider: AIProvider
    let size: CGFloat
    
    var body: some View {
        Group {
            if let assetName = provider.menuBarIconAsset,
               let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .colorMultiply(.primary)
            } else {
                Image(systemName: provider.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}
