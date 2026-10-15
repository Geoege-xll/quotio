import Foundation

// 代理地址校验是网络配置的纯规则；保留支持协议、端口要求、空值和尾斜线处理。
// 本批不改变校验算法或运行时 proxyURL，只让配置页和网络工厂共用明确入口。

// MARK: - Proxy URL Validation

nonisolated enum ProxyURLValidationResult: Equatable {
    case valid
    case empty
    case invalidScheme
    case invalidURL
    case missingHost
    case missingPort
    case invalidPort
    
    var isValid: Bool {
        self == .valid || self == .empty
    }
    
    var localizationKey: String? {
        switch self {
        case .valid, .empty:
            return nil
        case .invalidScheme:
            return "settings.proxy.error.invalidScheme"
        case .invalidURL:
            return "settings.proxy.error.invalidURL"
        case .missingHost:
            return "settings.proxy.error.missingHost"
        case .missingPort:
            return "settings.proxy.error.missingPort"
        case .invalidPort:
            return "settings.proxy.error.invalidPort"
        }
    }
}

nonisolated enum ProxyURLValidator {
    static let supportedSchemes = ["socks5", "http", "https"]
    
    static func validate(_ urlString: String) -> ProxyURLValidationResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            return .empty
        }
        
        let hasValidScheme = supportedSchemes.contains { scheme in
            trimmed.lowercased().hasPrefix("\(scheme)://")
        }
        
        guard hasValidScheme else {
            return .invalidScheme
        }
        
        guard let url = URL(string: trimmed) else {
            return .invalidURL
        }
        
        guard let host = url.host, !host.isEmpty else {
            return .missingHost
        }
        
        // socks5 requires explicit port
        if url.scheme?.lowercased() == "socks5" {
            guard let port = url.port else {
                return .missingPort
            }
            guard port >= 1 && port <= 65535 else {
                return .invalidPort
            }
        } else if let port = url.port {
            guard port >= 1 && port <= 65535 else {
                return .invalidPort
            }
        }
        
        return .valid
    }
    
    static func sanitize(_ urlString: String) -> String {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        
        return trimmed
    }
}
