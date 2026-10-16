//
//  AvailableModel.swift
//  Quotio
//

import Foundation

// 模型目录条目由客户端配置、仪表盘和模型目录转换共同使用，归入共享模型管理目录。
// 条目字段、可选展示平台与角色默认值保持兼容；候选只来自当前服务，目录刷新不替换或删除用户已经保存的模型。
// 目录值不代表账号路由，原先的 Codable、Hashable 与 nonisolated 契约保持一致。

// MARK: - Available Models for Routing

nonisolated struct AvailableModel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let isDefault: Bool
    /// 只记录目录明确返回的展示归属；provider 的历史 OpenAI 协议兜底不能充当真实平台。
    /// 可选字段允许旧缓存正常解码，它不表示服务账号，也不改变请求路由。
    var displayPlatform: String? = nil

    var displayName: String {
        name.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static let defaultModels: [ModelSlot: AvailableModel] = [
        // 角色槽在没有手动映射时仅保留原生角色引用，实际模型由 CLI 的版本、提供商与组织环境解析。
        // 不把某一版本的具体模型 ID 写死为已配置目标，避免 Default、子代理和选择弹层误报。
        .fable: AvailableModel(id: "fable", name: "fable", provider: "anthropic", isDefault: true),
        .opus: AvailableModel(id: "opus", name: "opus", provider: "anthropic", isDefault: true),
        .sonnet: AvailableModel(id: "sonnet", name: "sonnet", provider: "anthropic", isDefault: true),
        .haiku: AvailableModel(id: "haiku", name: "haiku", provider: "anthropic", isDefault: true)
    ]

}
