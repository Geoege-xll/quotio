//
//  AgentSessionProviderProtocol.swift
//  Quotio
//

import Foundation

/// 原会话客户端协议按完整声明归位，保留 public、nonisolated、Sendable 和 @concurrent 方法契约。
/// 具体 Provider 仍在通用执行器执行磁盘／数据库工作，不因分文件推断为 MainActor 或新增状态宿主。
/// 客户端磁盘协议必须显式退出模块默认的 MainActor 隔离，否则非隔离 struct 的协议实现
/// 仍会被推断为主线程方法，扫描、SQLite 等锁和删除文件都会阻塞界面。
/// @concurrent 同时约束具体实现：即使从主线程直接调用 Provider，也要切换到通用执行器。
public nonisolated protocol AgentSessionProviderProtocol: Sendable {
    var agent: WorkspaceAgent { get }
    @concurrent func scanSessions() async -> [WorkspaceSession]
    @concurrent func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage]
    @concurrent func deleteSession(_ session: WorkspaceSession) async throws -> Bool
}

