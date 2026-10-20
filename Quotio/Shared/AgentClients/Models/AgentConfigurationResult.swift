//
//  AgentConfigurationResult.swift
//  Quotio
//

import Foundation

// 配置输出、应用结果与连接测试结果是界面和基础设施之间传递的值类型，统一在共享客户端模型目录维护。
// 保留嵌套 ConfigFormat、成功与失败工厂、默认参数以及所有可选路径字段，不改变手动复制、备份反馈或连接诊断行为。
// 仅拆分源码文件；类型名、成员初始化器及 Sendable、nonisolated 约束均保持原样。

// MARK: - Raw Configuration Output (for Manual Mode)

nonisolated struct RawConfigOutput: Sendable {
    let format: ConfigFormat
    let content: String
    let filename: String?
    let targetPath: String?
    let instructions: String

    enum ConfigFormat: String, Sendable {
        case shellExport = "shell"
        case toml = "toml"
        case json = "json"
        case yaml = "yaml"
    }
}

// MARK: - Configuration Result

nonisolated struct AgentConfigResult: Sendable {
    let success: Bool
    let configType: AgentConfigType
    let mode: ConfigurationMode
    var configPath: String?
    var authPath: String?
    var shellConfig: String?
    var rawConfigs: [RawConfigOutput]
    var instructions: String
    var modelsConfigured: Int
    var error: String?
    var backupPath: String?
    /// 仅在一次自动迁移尚未完成 Shell 阶段时用于安全回滚；不持久化、不进入诊断报告。
    var claudeRollback: ClaudeConfigurationRollback? = nil
    /// Claude 的后续动作由同一操作计划决定，官方恢复也必须撤下原受管 Shell 段。
    var claudeShellAction: ClaudeShellProfileAction? = nil

    static func success(
        type: AgentConfigType,
        mode: ConfigurationMode,
        configPath: String? = nil,
        authPath: String? = nil,
        shellConfig: String? = nil,
        rawConfigs: [RawConfigOutput] = [],
        instructions: String,
        modelsConfigured: Int = 3,
        backupPath: String? = nil
    ) -> AgentConfigResult {
        AgentConfigResult(
            success: true,
            configType: type,
            mode: mode,
            configPath: configPath,
            authPath: authPath,
            shellConfig: shellConfig,
            rawConfigs: rawConfigs,
            instructions: instructions,
            modelsConfigured: modelsConfigured,
            error: nil,
            backupPath: backupPath
        )
    }

    static func failure(error: String) -> AgentConfigResult {
        AgentConfigResult(
            success: false,
            configType: .environment,
            mode: .automatic,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "",
            modelsConfigured: 0,
            error: error,
            backupPath: nil
        )
    }
}


// MARK: - Connection Test Result

nonisolated struct ConnectionTestResult: Sendable {
    let success: Bool
    let message: String
    let latencyMs: Int?
    let modelResponded: String?
}

/// 原配置服务创建的事务凭据，原 VM 仅在后续 Shell 失败时交还同一服务。
/// 回滚前必须比较 written，避免覆盖其他进程随后写入的新配置；首次文件用 nil 表示不存在。
nonisolated struct ClaudeConfigurationRollback: Sendable {
    let original: Data?
    let written: Data
    let reportPath: String?
}
