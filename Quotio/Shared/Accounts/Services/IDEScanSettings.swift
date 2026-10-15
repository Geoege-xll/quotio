//
//  IDEScanSettings.swift
//  Quotio - IDE Scan Consent and Settings
//
//  Manages user consent for scanning IDE data files
//  Required for privacy: user must explicitly opt-in to scan
//

import Foundation

// 显式 IDE 扫描的选项、结果、提示和原同意状态宿主成组维护，供账号服务与扫描页面共用。
// 默认仍只允许 CLI 发现；Cursor／Trae 的本地数据读取必须由原显式勾选入口触发，不增加自动扫描。
// 保留同一个 manager、私有构造、全部字段和隐私路径；页面控件与实际获取任务仍归原宿主。

/// Options for IDE scanning - what data sources to scan
struct IDEScanOptions: Sendable {
    /// Scan Cursor IDE's local database for auth/quota
    /// Path: ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
    var scanCursor: Bool = false
    
    /// Scan Trae IDE's storage for auth/quota
    /// Path: ~/Library/Application Support/Trae/User/globalStorage/storage.json
    var scanTrae: Bool = false
    
    /// Scan for installed CLI tools (claude, codex, gemini, etc.)
    /// Uses: which command + /usr/local/bin, /opt/homebrew/bin
    var scanCLITools: Bool = true
    
    /// Returns true if any IDE scan option is enabled
    var hasIDEScanEnabled: Bool {
        scanCursor || scanTrae
    }
    
    /// Returns true if any scan option is enabled
    var hasAnyScanEnabled: Bool {
        scanCursor || scanTrae || scanCLITools
    }
    
    /// Default options - only CLI tools (non-invasive)
    static let defaultOptions = IDEScanOptions(
        scanCursor: false,
        scanTrae: false,
        scanCLITools: true
    )
    
    /// All options enabled
    static let allEnabled = IDEScanOptions(
        scanCursor: true,
        scanTrae: true,
        scanCLITools: true
    )
}

/// Result of an IDE scan operation
struct IDEScanResult: Sendable {
    let cursorFound: Bool
    let cursorEmail: String?
    let traeFound: Bool
    let traeEmail: String?
    let cliToolsFound: [String] // List of found CLI tool names
    let timestamp: Date
    
    static let empty = IDEScanResult(
        cursorFound: false,
        cursorEmail: nil,
        traeFound: false,
        traeEmail: nil,
        cliToolsFound: [],
        timestamp: Date()
    )
}

/// Manages IDE scan consent settings
/// User must explicitly trigger scan - no auto-scanning
@MainActor
@Observable
final class IDEScanSettingsManager {
    static let shared = IDEScanSettingsManager()
    
    /// Last scan result (not persisted - cleared on app restart)
    var lastScanResult: IDEScanResult?
    
    /// Whether a scan is currently in progress
    var isScanning: Bool = false
    
    /// Last error message from scan
    var lastError: String?
    
    private init() {}
    
    // MARK: - Scan State
    
    /// Clear the last scan result
    func clearScanResult() {
        lastScanResult = nil
        lastError = nil
    }
    
    /// Update scan result
    func updateScanResult(_ result: IDEScanResult) {
        lastScanResult = result
        lastError = nil
    }
    
    /// Set scanning state
    func setScanningState(_ scanning: Bool) {
        isScanning = scanning
        if scanning {
            lastError = nil
        }
    }
    
    /// Set error state
    func setError(_ error: String) {
        lastError = error
        isScanning = false
    }
}

// MARK: - Privacy Notice Helpers

extension IDEScanOptions {
    /// Get list of paths that will be accessed for the current options
    var accessedPaths: [String] {
        var paths: [String] = []
        
        if scanCursor {
            paths.append("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        }
        
        if scanTrae {
            paths.append("~/Library/Application Support/Trae/User/globalStorage/storage.json")
        }
        
        if scanCLITools {
            paths.append("/usr/local/bin, /opt/homebrew/bin (via 'which' command)")
        }
        
        return paths
    }
    
    /// Get privacy notice text for the current options
    var privacyNoticeItems: [(icon: String, title: String, detail: String)] {
        var items: [(icon: String, title: String, detail: String)] = []
        
        if scanCursor {
            items.append((
                icon: "cursor",
                title: "Cursor IDE",
                detail: "~/Library/Application Support/Cursor/"
            ))
        }
        
        if scanTrae {
            items.append((
                icon: "trae",
                title: "Trae IDE",
                detail: "~/Library/Application Support/Trae/"
            ))
        }
        
        if scanCLITools {
            items.append((
                icon: "terminal",
                title: "CLI Tools",
                detail: "Uses 'which' command to find installed tools"
            ))
        }
        
        return items
    }
}
