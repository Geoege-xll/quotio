//
//  MonitorIdentity.swift
//  Quotio
//

import Foundation
import CryptoKit

/// 原监控身份辅助；保留指纹、路径展开、JSON 与 JWT 读取规则。
/// 仅接收原文件内共享的空白裁剪规则，不向 String 全局扩展接口，也不引入状态或缓存。
nonisolated enum MonitorIdentity {
    /// 接收原可选链输入：nil 或裁剪后为空继续返回 nil，非空文本返回原 whitespace/newline 裁剪结果。
    /// 与原私有 String.nilIfBlank 的规则一致，供账号显示回退和发现条件复用，不改变账号身份或路径策略。
    static func nilIfBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func json(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func jwtString(_ token: String?, claim: String) -> String? {
        jwtPayload(token)?[claim] as? String
    }

    static func jwtNestedString(_ token: String?, namespace: String, claim: String) -> String? {
        (jwtPayload(token)?[namespace] as? [String: Any])?[claim] as? String
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

