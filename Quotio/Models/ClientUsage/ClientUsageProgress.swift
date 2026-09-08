import Foundation

/// 扫描进度只包含数量与字节，不暴露会话路径、账号或正文。来源可独立完成，不被慢来源拖住。
nonisolated struct ClientUsageProgress: Sendable, Equatable {
    let source: ClientUsageSource
    var filesCompleted: Int = 0
    var filesTotal: Int = 0
    var bytesRead: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesReused: Int = 0
}

/// 来源扫描器接收节流进度回调；磁盘操作在后台任务执行，回调不能触碰SwiftUI状态。
typealias ClientUsageProgressHandler = @Sendable (ClientUsageProgress) -> Void

/// 仅在内存中传递的刷新事件，页面以来源区分扫描、保存与完成。
nonisolated enum ClientUsageRefreshEvent: Sendable {
    case progress(ClientUsageProgress)
    case saving(ClientUsageSource)
    case completed(ClientUsageSource, ClientUsageDisplaySnapshot)
    case failed(ClientUsageSource)
}

/// 页面进度状态与统计是否有历史独立：取消扫描不清空已经完成并保存的来源。
nonisolated struct ClientUsageActivity: Sendable {
    enum Phase: Sendable, Equatable { case queued, scanning, saving, complete, failed, cancelled }
    var phase: Phase = .queued
    var progress: ClientUsageProgress
}
