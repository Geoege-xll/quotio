//
//  String+PrivacyMasking.swift
//  Quotio
//

import Foundation

// 隐私脱敏属于多个页面、菜单栏与账号展示共用的字符串格式化能力，独立存放于 Shared/Formatting。
// 本次仅迁移完整 String 扩展；邮箱域名保留方式、长度上限和条件脱敏规则沿用原实现，
// 不读取或创建新的设置实例，是否脱敏仍由调用方传入的既有用户偏好决定。

// MARK: - Privacy String Extension

extension String {
    /// Masks sensitive information with asterisks (*)
    /// Email: `john.doe@gmail.com` → `********@*****.com`
    /// Other: `account-name` → `************`
    func masked() -> String {
        // Check if it's an email
        if self.contains("@") {
            let components = self.split(separator: "@", maxSplits: 1)
            if components.count == 2 {
                let localPart = String(repeating: "*", count: min(components[0].count, 8))
                let domainParts = components[1].split(separator: ".", maxSplits: 1)
                if domainParts.count == 2 {
                    let domainName = String(repeating: "*", count: min(domainParts[0].count, 5))
                    return "\(localPart)@\(domainName).\(domainParts[1])"
                }
                return "\(localPart)@\(String(repeating: "*", count: 5))"
            }
        }
        
        // For non-email strings, mask entirely but keep reasonable length
        let maskedLength = min(self.count, 12)
        return String(repeating: "*", count: max(maskedLength, 4))
    }
    
    /// Conditionally masks the string based on a flag
    func masked(if shouldMask: Bool) -> String {
        shouldMask ? masked() : self
    }
}

