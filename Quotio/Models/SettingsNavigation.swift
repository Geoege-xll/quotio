import Foundation

/// 分类与搜索目标使用系统导航栈；应用模式归属首页，复杂配置可继续 Push。
/// 不创建第二份可编辑配置，也不在路由中保存密钥或其他用户输入。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, menuBar, usage, notifications, service, requests, security, maintenance

    var id: String { rawValue }
    var title: String { "settings.navigation.\(rawValue).title".localized() }
    var subtitle: String { "settings.navigation.\(rawValue).subtitle".localized() }
    var isCPAOnly: Bool { self == .service || self == .requests }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .usage: "chart.bar.xaxis"
        case .notifications: "bell"
        case .service: "server.rack"
        case .requests: "arrow.triangle.branch"
        case .security: "lock.shield"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    var topics: [SettingsTopic] {
        switch self {
        case .general: [.startup, .language, .appearance]
        case .menuBar: [.menuBar]
        case .usage: [.quota, .usage, .refresh]
        case .notifications: [.notifications]
        case .service: [.server, .upstream]
        case .requests: [.aliases, .requestPolicy]
        case .security: [.privacy, .yubiKey, .managementKey]
        case .maintenance: [.logging, .workaround, .paths, .maintenanceLinks]
        }
    }
}

/// 每个搜索条目对应一个实际配置分组。保留中英文技术同义词，
/// 例如搜索“思考强度”与 reasoning 均进入 CPA 模型别名，而不是客户端模型槽。
enum SettingsTopic: String, CaseIterable, Identifiable {
    case mode, startup, language, appearance, menuBar, quota, usage, refresh, notifications
    case server, upstream, aliases, requestPolicy, privacy, yubiKey, managementKey
    case logging, workaround, paths, maintenanceLinks

    var id: String { rawValue }
    var title: String { titleKey.localized() }
    var titleKey: String {
        switch self {
        case .mode: "settings.appMode"
        case .startup: "settings.launchAtLogin"
        case .language: "settings.language"
        case .appearance: "settings.appearance.title"
        case .menuBar: "settings.navigation.menuBar.title"
        case .quota: "settings.quota.display"
        case .usage: "settings.usageDisplay.title"
        case .refresh: "settings.refresh"
        case .notifications: "settings.notifications"
        case .server: "settings.proxyServer"
        case .upstream: "settings.upstreamProxy.title"
        case .aliases: "cpaAliases.title"
        case .requestPolicy: "settings.navigation.requestPolicy"
        case .privacy: "settings.privacy"
        case .yubiKey: "settings.yubikey.title"
        case .managementKey: "settings.managementKey"
        case .logging: "settings.logging"
        case .workaround: "troubleshooting.title"
        case .paths: "settings.paths"
        case .maintenanceLinks: "settings.navigation.maintenanceLinks"
        }
    }

    var category: SettingsCategory {
        switch self {
        case .mode, .startup, .language, .appearance: .general
        case .menuBar: .menuBar
        case .quota, .usage, .refresh: .usage
        case .notifications: .notifications
        case .server, .upstream: .service
        case .aliases, .requestPolicy: .requests
        case .privacy, .yubiKey, .managementKey: .security
        case .logging, .workaround, .paths, .maintenanceLinks: .maintenance
        }
    }

    private var keywords: String {
        switch self {
        case .mode: "运行模式 监控 本地代理 operating mode monitor local proxy"
        case .startup: "开机 登录 启动 launch login startup"
        case .language: "语言 中文 英文 language locale"
        case .appearance: "外观 浅色 深色 跟随系统 appearance theme dark light"
        case .menuBar: "菜单栏 Dock 图标 数量 排列 彩色 单色 menubar icon paired metrics"
        case .quota: "配额 额度 已用 剩余 样式 百分比 quota remaining used display"
        case .usage: "用量 合计 模型 聚合 tokens usage aggregation total"
        case .refresh: "刷新 频率 间隔 手动 refresh cadence interval manual"
        case .notifications: "通知 提醒 阈值 授权 低额度 冷却 崩溃 更新 notification threshold cooling crash"
        case .server: "端口 监听 地址 自动启动 局域网 隧道 重启 port endpoint bind tunnel network restart"
        case .upstream: "上游代理 网络 HTTP HTTPS SOCKS proxy url upstream"
        case .aliases: "模型别名 思考强度 默认思考 reasoning effort thinking alias CPA"
        case .requestPolicy: "路由 轮询 填充 账号切换 预览模型 额度耗尽 重试 间隔 routing round robin fill retry fallback"
        case .privacy: "隐私 敏感信息 隐藏 匿名 数据 遥测 privacy sensitive anonymous telemetry"
        case .yubiKey: "硬件 密钥 凭据 保险库 保护 yubikey piv vault credential security"
        case .managementKey: "管理 密钥 复制 重新生成 轮换 management key regenerate rotate"
        case .logging: "日志 文件 请求 调试 logging file request debug"
        case .workaround: "兼容 修复 恢复 故障 排查 workaround troubleshoot base url restore"
        case .paths: "路径 二进制 配置 认证 目录 文件 path binary config auth directory"
        case .maintenanceLinks: "存储 数据 清理 缓存 统计 内存 版本 更新 上游 同步 源码 关于 日志 查看 storage data cache memory cleanup statistics version update upstream sync source about logs"
        }
    }

    func matches(_ query: String) -> Bool {
        let haystack = [title, category.title, category.subtitle, keywords].joined(separator: " ")
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { haystack.localizedStandardContains(String($0)) }
    }
}

struct SettingsDestination: Hashable {
    let category: SettingsCategory
    var topic: SettingsTopic? = nil
}

/// 辅助页面同样进入设置导航栈，不通过修改主侧栏选中项绕过系统返回。
enum SettingsAuxiliaryPage: Hashable {
    case aliases, agents, logs, about, upstreamUpdates, storageData
}
