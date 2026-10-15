//
//  MenuNativeTooltip.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单跟踪期间使用的原生提示窗口。
/// 只开放 menuNativeTooltip 这一模块内 View 扩展方法；窗口单例、跟踪视图和桥接实现保持私有。
/// 保留原窗口层级、悬停定时与销毁行为，不与普通页面提示窗口合并。
private final class MenuTooltipWindow: NSWindow {
    static let shared = MenuTooltipWindow()

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .transient]
        ignoresMouseEvents = true

        let effectView = NSVisualEffectView()
        effectView.material = .toolTip
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 6

        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -5)
        ])

        contentView = effectView
    }

    func show(text: String, near view: NSView) {
        guard !text.isEmpty else {
            hide()
            return
        }

        label.stringValue = text
        label.sizeToFit()

        let labelSize = label.fittingSize
        let windowSize = NSSize(width: min(labelSize.width + 18, 360), height: labelSize.height + 10)

        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let viewFrame = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero

        var origin = NSPoint(
            x: viewFrame.midX - windowSize.width / 2,
            y: viewFrame.maxY + 5
        )

        if origin.x < screenFrame.minX {
            origin.x = screenFrame.minX
        }
        if origin.x + windowSize.width > screenFrame.maxX {
            origin.x = screenFrame.maxX - windowSize.width
        }
        if origin.y + windowSize.height > screenFrame.maxY {
            origin.y = viewFrame.minY - windowSize.height - 5
        }
        if origin.y < screenFrame.minY {
            origin.y = screenFrame.minY
        }

        setFrame(NSRect(origin: origin, size: windowSize), display: true)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

private final class MenuTooltipTrackingView: NSView {
    var text: String = ""

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        MenuTooltipWindow.shared.show(text: text, near: self)
    }

    override func mouseMoved(with event: NSEvent) {
        MenuTooltipWindow.shared.show(text: text, near: self)
    }

    override func mouseExited(with event: NSEvent) {
        MenuTooltipWindow.shared.hide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            MenuTooltipWindow.shared.hide()
        }
    }

    override func removeFromSuperview() {
        MenuTooltipWindow.shared.hide()
        super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct MenuNativeTooltipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> MenuTooltipTrackingView {
        let view = MenuTooltipTrackingView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: MenuTooltipTrackingView, context: Context) {
        nsView.text = text
    }

    static func dismantleNSView(_ nsView: MenuTooltipTrackingView, coordinator: ()) {
        MenuTooltipWindow.shared.hide()
    }
}

extension View {
    func menuNativeTooltip(_ text: String) -> some View {
        overlay(MenuNativeTooltipView(text: text))
    }
}
