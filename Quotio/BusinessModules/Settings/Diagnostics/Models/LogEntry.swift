import Foundation
import SwiftUI

// 诊断页使用的日志展示模型，完整保留嵌套级别、UUID 复用与未知时间，不在本批重做日志解析。

// MARK: - Log Entry

nonisolated struct LogEntry: Identifiable {
    let id: UUID
    let timestamp: Date?
    let level: LogLevel
    let message: String

    /// 无法识别的时间保持为空，不使用客户端接收时间冒充服务端事件时间。
    /// 增量刷新时允许复用标识，避免选中项和阅读位置随每次轮询重置。
    init(id: UUID = UUID(), timestamp: Date?, level: LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
    
    enum LogLevel: String {
        case info, warn, error, debug, unknown
        
        var color: Color {
            switch self {
            case .info: return .primary
            case .warn: return .orange
            case .error: return .red
            case .debug: return .gray
            case .unknown: return .secondary
            }
        }
    }
}
