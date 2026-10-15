import Foundation

/// Pi 安装、配置、技能清单和两类本地统计实际共用的路径契约，统一维护已有环境覆盖及默认目录。
/// 仅按显式 home／environment 计算原路径，不创建目录、不扫描文件，也不读取 auth.json。
/// 统计时间解析留 Analytics；此接入契约不引用业务时钟、统计模型或页面状态。
nonisolated enum PiSessionPaths {
    static func expand(_ path: String, homeDirectory: String) -> String {
        let expanded = path == "~" ? homeDirectory
            : (path.hasPrefix("~/") ? homeDirectory + String(path.dropFirst()) : path)
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: homeDirectory, isDirectory: true))
            .standardizedFileURL.path
    }

    static func agentDirectory(homeDirectory: String, environment: [String: String]) -> String {
        let value = environment["PI_CODING_AGENT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return expand(value.isEmpty ? homeDirectory + "/.pi/agent" : value, homeDirectory: homeDirectory)
    }

    static func sessionRoots(homeDirectory: String, environment: [String: String]) -> [String] {
        var roots = [agentDirectory(homeDirectory: homeDirectory, environment: environment) + "/sessions"]
        if let value = environment["PI_CODING_AGENT_SESSION_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            roots.append(expand(value, homeDirectory: homeDirectory))
        }
        return Array(Set(roots)).sorted()
    }

}
