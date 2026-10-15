//
//  AvailableModel.swift
//  Quotio
//

import Foundation

// 模型目录条目由客户端配置、仪表盘和模型目录转换共同使用，归入共享模型管理目录。
// 完整保留条目字段、可选展示平台、内置列表与角色默认值；移动源码不刷新、替换或删除用户已经保存的模型。
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

    /// 仅用于非 Pi 配置页的历史候选兜底，不表示实时目录或当前账号已支持这些模型。
    /// 保留旧列表兼容原选择流程；实时目录和连接测试仍各自遵循原契约。
    static let allModels: [AvailableModel] = [
        // Claude models
        AvailableModel(id: "gemini-claude-opus-4-6-thinking", name: "gemini-claude-opus-4-6-thinking", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-opus-4-5-thinking", name: "gemini-claude-opus-4-5-thinking", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-sonnet-4-5", name: "gemini-claude-sonnet-4-5", provider: "anthropic", isDefault: false),
        AvailableModel(id: "gemini-claude-sonnet-4-5-thinking", name: "gemini-claude-sonnet-4-5-thinking", provider: "anthropic", isDefault: false),
        // Gemini models
        AvailableModel(id: "gemini-3-pro-preview", name: "gemini-3-pro-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-3-pro-image-preview", name: "gemini-3-pro-image-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-3-flash-preview", name: "gemini-3-flash-preview", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-flash-lite", name: "gemini-2.5-flash-lite", provider: "google", isDefault: false),
        AvailableModel(id: "gemini-2.5-computer-use-preview-10-2025", name: "gemini-2.5-computer-use-preview-10-2025", provider: "google", isDefault: false),
        // GPT models
        AvailableModel(id: "gpt-5.3-codex", name: "gpt-5.3-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.2", name: "gpt-5.2", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.2-codex", name: "gpt-5.2-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1", name: "gpt-5.1", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex", name: "gpt-5.1-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex-max", name: "gpt-5.1-codex-max", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5.1-codex-mini", name: "gpt-5.1-codex-mini", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5", name: "gpt-5", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-5-codex-mini", name: "gpt-5-codex-mini", provider: "openai", isDefault: false),
        AvailableModel(id: "gpt-oss-120b-medium", name: "gpt-oss-120b-medium", provider: "openai", isDefault: false),
    ]
}

