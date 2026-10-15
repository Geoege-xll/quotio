//
//  MenuItemHostingView.swift
//  Quotio
//

import AppKit
import SwiftUI

/// SwiftUI 与 NSMenuItem 的尺寸适配入口。
/// 尺寸桥接仍由原根视图持有，并弱引用承载视图；合并测量通知及菜单跟踪 RunLoop 的时序保持原样。
/// NSMenu 以实际 frame 布局，SwiftUI 内容变化不会自动调整菜单项高度。
/// 仅动态内容启用测量，并在垂直方向采用理想尺寸，避免旧 frame 压缩新增的行。
@MainActor
func makeMenuItemHostingView<Content: View>(rootView: Content, resizesToFitContent: Bool = false) -> NSView {
    guard resizesToFitContent else { return NSHostingView(rootView: rootView) }
    let sizeBridge = MenuItemSizeBridge()
    let measuredView = rootView
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            sizeBridge.scheduleResize(to: size)
        }
    let hostingView = NSHostingView(rootView: measuredView)
    sizeBridge.hostingView = hostingView
    return hostingView
}

@MainActor
private final class MenuItemSizeBridge {
    // SwiftUI 根视图持有此桥接对象；反向弱引用防止菜单关闭后承载视图无法释放。
    weak var hostingView: NSView?
    private var pendingSize: CGSize?

    func scheduleResize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        let alreadyScheduled = pendingSize != nil
        pendingSize = size
        guard !alreadyScheduled else { return }
        // 合并同轮布局通知，并延后修改 AppKit frame，避免在 SwiftUI 布局中递归更新。
        // common modes 保证菜单展开、事件跟踪期间也能执行尺寸同步。
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let size = self.pendingSize
                self.pendingSize = nil
                guard let hostingView = self.hostingView, let size, hostingView.frame.size != size else { return }
                hostingView.setFrameSize(size)
            }
        }
    }
}
