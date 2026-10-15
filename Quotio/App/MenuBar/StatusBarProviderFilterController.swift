//
//  StatusBarProviderFilterController.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 原生菜单的提供商筛选协调器。
/// 保留原可观察实例、菜单弱引用及按身份登记的范围；筛选仍只切换既有菜单项的可见性。
// 上游 73c383e：保持菜单项身份稳定，使提供商筛选不会关闭菜单。
@MainActor
@Observable
final class StatusBarProviderFilterController {
    enum Scope {
        case provider(AIProvider)
        case allProvidersOnly
    }

    var selectedProvider: AIProvider?

    @ObservationIgnored private weak var menu: NSMenu?
    @ObservationIgnored private var scopes: [ObjectIdentifier: Scope] = [:]
    @ObservationIgnored private let onSelectionChanged: (AIProvider?) -> Void

    init(
        selectedProvider: AIProvider?,
        onSelectionChanged: @escaping (AIProvider?) -> Void
    ) {
        self.selectedProvider = selectedProvider
        self.onSelectionChanged = onSelectionChanged
    }

    /// 预先登记菜单项的筛选范围，切换提供商时只修改可见性，保留 AppKit 跟踪状态。
    func register(_ item: NSMenuItem, scope: Scope) {
        scopes[ObjectIdentifier(item)] = scope
        item.isHidden = !isVisible(scope)
    }

    /// 菜单构建后会把项目搬到状态栏的实际菜单，必须重新绑定最终容器。
    func activate(in menu: NSMenu) {
        self.menu = menu
        applySelection()
    }

    func select(_ provider: AIProvider?) {
        guard selectedProvider != provider else { return }
        selectedProvider = provider
        applySelection()
        onSelectionChanged(provider)
    }

    /// 不删除或重建 NSMenuItem，避免 SwiftUI 按钮点击过程中菜单被 AppKit 关闭。
    private func applySelection() {
        guard let menu else { return }
        for item in menu.items {
            guard let scope = scopes[ObjectIdentifier(item)] else { continue }
            item.isHidden = !isVisible(scope)
        }
        menu.update()
    }

    private func isVisible(_ scope: Scope) -> Bool {
        switch scope {
        case .provider(let provider):
            selectedProvider == nil || selectedProvider == provider
        case .allProvidersOnly:
            selectedProvider == nil
        }
    }
}
