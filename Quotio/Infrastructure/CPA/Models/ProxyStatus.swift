import Foundation

// CPA 运行状态值类型与进程基础设施归在一起；保留原有默认值和 endpoint 计算，不改变运行配置。

// MARK: - Proxy Status

nonisolated struct ProxyStatus: Codable {
    var running: Bool = false
    var port: UInt16 = 8317
    
    var endpoint: String {
        "http://localhost:\(port)/v1"
    }
}
