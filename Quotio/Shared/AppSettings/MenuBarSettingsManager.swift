//
//  MenuBarSettingsManager.swift
//  Quotio
//

import Foundation
import SwiftUI

// 菜单栏颜色选项与完整偏好管理器集中存放；其余共享选项按职责分文件，不拆分持久化所有权。
// 只保留原来的 MenuBarSettingsManager.shared，一个管理器继续持有全部既有存储属性与观察入口。
// UserDefaults 键、初始化次序、didSet、旧账号迁移、数量裁剪和用户选择标记均逐字沿用原实现，
// 不因文件拆分重置偏好、创建第二个设置实例或改变回调/写入时机。

// MARK: - Color Mode

/// Color mode for menu bar quota display
enum MenuBarColorMode: String, Codable, CaseIterable, Identifiable {
    case colored = "colored"       // Green/Yellow/Red based on quota %
    case monochrome = "monochrome" // White/Gray only
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .colored: return "settings.menubar.colored"
        case .monochrome: return "settings.menubar.monochrome"
        }
    }
}

// MARK: - Settings Manager

/// Manager for menu bar display settings with persistence
@MainActor
@Observable
final class MenuBarSettingsManager {
    static let shared = MenuBarSettingsManager()
    
    private let defaults: UserDefaults
    private let selectedItemsKey = "menuBarSelectedQuotaItems"
    private let colorModeKey = "menuBarColorMode"
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let showQuotaKey = "menuBarShowQuota"
    private let menuBarMaxItemsKey = "menuBarMaxItems"
    private let quotaDisplayModeKey = "quotaDisplayMode"
    private let quotaDisplayStyleKey = "quotaDisplayStyle"
    // Retain the key introduced by #493 so existing user preferences carry forward.
    private let stackPairedQuotaMetricsKey = "menuBarStackClaudeQuotaWindows"
    private let hideSensitiveInfoKey = "hideSensitiveInfo"
    private let totalUsageModeKey = "totalUsageMode"
    private let modelAggregationModeKey = "modelAggregationMode"
    private let hasUserModifiedMenuBarKey = "hasUserModifiedMenuBar"
    private let selectedTerminalBundleIDKey = "selectedTerminalBundleID"

    static let minMenuBarItems = 1
    static let maxMenuBarItems = 10
    static let defaultMenuBarMaxItems = 3

    /// Whether to show menu bar icon at all
    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: showMenuBarIconKey) }
    }

    /// Whether to show quota in menu bar (only effective when showMenuBarIcon is true)
    var showQuotaInMenuBar: Bool {
        didSet { defaults.set(showQuotaInMenuBar, forKey: showQuotaKey) }
    }

    /// Maximum number of items to display in menu bar
    var menuBarMaxItems: Int {
        didSet {
            defaults.set(menuBarMaxItems, forKey: menuBarMaxItemsKey)
            enforceMaxItems()
        }
    }
    
    /// Selected items to display
    var selectedItems: [MenuBarQuotaItem] {
        didSet { saveSelectedItems() }
    }
    
    /// Color mode (colored vs monochrome)
    var colorMode: MenuBarColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: colorModeKey) }
    }
    
    /// Quota display mode (used vs remaining)
    var quotaDisplayMode: QuotaDisplayMode {
        didSet { defaults.set(quotaDisplayMode.rawValue, forKey: quotaDisplayModeKey) }
    }
    
    /// Visual style for quota display
    var quotaDisplayStyle: QuotaDisplayStyle {
        didSet { defaults.set(quotaDisplayStyle.rawValue, forKey: quotaDisplayStyleKey) }
    }

    /// Whether providers with a stable metric pair use the compact stacked layout.
    var stackPairedQuotaMetrics: Bool {
        didSet { defaults.set(stackPairedQuotaMetrics, forKey: stackPairedQuotaMetricsKey) }
    }
    
    /// Whether to hide sensitive information (emails, account names)
    var hideSensitiveInfo: Bool {
        didSet { defaults.set(hideSensitiveInfo, forKey: hideSensitiveInfoKey) }
    }
    
    /// Total usage calculation mode (session-only vs combined)
    var totalUsageMode: TotalUsageMode {
        didSet { defaults.set(totalUsageMode.rawValue, forKey: totalUsageModeKey) }
    }
    
    /// Model aggregation mode (lowest vs average)
    var modelAggregationMode: ModelAggregationMode {
        didSet { defaults.set(modelAggregationMode.rawValue, forKey: modelAggregationModeKey) }
    }

    /// Selected terminal bundle ID for launching CLI sessions (default "auto")
    var selectedTerminalBundleID: String {
        didSet { defaults.set(selectedTerminalBundleID, forKey: selectedTerminalBundleIDKey) }
    }

    /// Whether user has manually modified the menu bar selection
    /// When true, autoSelectNewAccounts will not add new items
    private(set) var hasUserModifiedMenuBar: Bool {
        didSet { defaults.set(hasUserModifiedMenuBar, forKey: hasUserModifiedMenuBarKey) }
    }

    /// Check if adding another item would exceed the warning threshold
    /// Warning shows when approaching the limit (at maxItems - 1)
    var shouldWarnOnAdd: Bool {
        let threshold = max(menuBarMaxItems - 1, 1)
        return selectedItems.count >= threshold && selectedItems.count < menuBarMaxItems
    }

    /// Check if selection has reached the maximum items
    var isAtMaxItems: Bool {
        selectedItems.count >= menuBarMaxItems
    }
    
    /// 正常应用仍使用 standard；展示回归可注入独立 suite，验证隐私及三种样式，
    /// 所有测试写入只发生在该 suite，不覆盖用户现有菜单栏选择或展示偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Show menu bar icon - default true if not set
        if defaults.object(forKey: showMenuBarIconKey) == nil {
            defaults.set(true, forKey: showMenuBarIconKey)
        }
        self.showMenuBarIcon = defaults.bool(forKey: showMenuBarIconKey)
        
        // Show quota in menu bar - default true if not set
        if defaults.object(forKey: showQuotaKey) == nil {
            defaults.set(true, forKey: showQuotaKey)
        }
        self.showQuotaInMenuBar = defaults.bool(forKey: showQuotaKey)
        
        if defaults.object(forKey: menuBarMaxItemsKey) == nil {
            defaults.set(Self.defaultMenuBarMaxItems, forKey: menuBarMaxItemsKey)
        }

        self.colorMode = MenuBarColorMode(rawValue: defaults.string(forKey: colorModeKey) ?? "") ?? .colored
        self.quotaDisplayMode = QuotaDisplayMode(rawValue: defaults.string(forKey: quotaDisplayModeKey) ?? "") ?? .used
        self.quotaDisplayStyle = QuotaDisplayStyle(rawValue: defaults.string(forKey: quotaDisplayStyleKey) ?? "") ?? .card
        if defaults.object(forKey: stackPairedQuotaMetricsKey) == nil {
            defaults.set(true, forKey: stackPairedQuotaMetricsKey)
        }
        self.stackPairedQuotaMetrics = defaults.bool(forKey: stackPairedQuotaMetricsKey)
        self.selectedItems = Self.loadSelectedItems(from: defaults, key: selectedItemsKey)

        // Load and clamp menuBarMaxItems, then persist the clamped value
        let loadedMax = defaults.integer(forKey: menuBarMaxItemsKey)
        let clampedMax = Self.clampedMenuBarMax(loadedMax)
        self.menuBarMaxItems = clampedMax
        if loadedMax != clampedMax {
            defaults.set(clampedMax, forKey: menuBarMaxItemsKey)
        }

        self.hideSensitiveInfo = defaults.bool(forKey: hideSensitiveInfoKey)
        self.totalUsageMode = TotalUsageMode(rawValue: defaults.string(forKey: totalUsageModeKey) ?? "") ?? .sessionOnly
        self.modelAggregationMode = ModelAggregationMode(rawValue: defaults.string(forKey: modelAggregationModeKey) ?? "") ?? .lowest
        self.selectedTerminalBundleID = defaults.string(forKey: selectedTerminalBundleIDKey) ?? "auto"
        self.hasUserModifiedMenuBar = defaults.bool(forKey: hasUserModifiedMenuBarKey)

        enforceMaxItems()
    }
    
    private func saveSelectedItems() {
        if let data = try? JSONEncoder().encode(selectedItems) {
            defaults.set(data, forKey: selectedItemsKey)
        }
    }
    
    private static func loadSelectedItems(from defaults: UserDefaults, key: String) -> [MenuBarQuotaItem] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([MenuBarQuotaItem].self, from: data) else {
            return []
        }
        return AuthFileIdentity.rekeyMenuBarItems(items.filter { $0.provider != "gemini-cli" }, aliases: [:])
    }
    
    func addItem(_ item: MenuBarQuotaItem) {
        guard !selectedItems.contains(item) else { return }
        guard selectedItems.count < menuBarMaxItems else { return }
        if !showQuotaInMenuBar {
            showQuotaInMenuBar = true
        }
        if !showMenuBarIcon {
            showMenuBarIcon = true
        }
        selectedItems.append(item)
    }
    
    /// Remove an item (marks as user-modified to prevent auto-add)
    func removeItem(_ item: MenuBarQuotaItem) {
        selectedItems.removeAll { $0.id == item.id }
        hasUserModifiedMenuBar = true
    }

    /// Check if item is selected
    func isSelected(_ item: MenuBarQuotaItem) -> Bool {
        selectedItems.contains(item)
    }

    /// Toggle item selection (marks as user-modified to prevent auto-add)
    func toggleItem(_ item: MenuBarQuotaItem) {
        hasUserModifiedMenuBar = true
        if isSelected(item) {
            selectedItems.removeAll { $0.id == item.id }
        } else {
            addItem(item)
        }
    }
    
    /// Remove items that no longer exist in quota data
    func pruneInvalidItems(validItems: [MenuBarQuotaItem]) {
        let validIds = Set(validItems.map(\.id))
        selectedItems.removeAll { !validIds.contains($0.id) }
    }
    
    func autoSelectNewAccounts(availableItems: [MenuBarQuotaItem]) {
        // Don't auto-add if user has manually modified the menu bar selection
        guard !hasUserModifiedMenuBar else { return }

        enforceMaxItems()
        let existingIds = Set(selectedItems.map(\.id))
        let newItems = availableItems.filter { !existingIds.contains($0.id) }

        let remainingSlots = menuBarMaxItems - selectedItems.count
        if remainingSlots > 0 {
            let itemsToAdd = Array(newItems.prefix(remainingSlots))
            selectedItems.append(contentsOf: itemsToAdd)
        }
    }

    @discardableResult
    private func enforceMaxItems() -> Bool {
        guard selectedItems.count > menuBarMaxItems else { return false }
        selectedItems = Array(selectedItems.prefix(menuBarMaxItems))
        return true
    }

    private static func clampedMenuBarMax(_ value: Int) -> Int {
        min(max(value, minMenuBarItems), maxMenuBarItems)
    }
}
