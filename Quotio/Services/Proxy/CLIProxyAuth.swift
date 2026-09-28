//
//  CLIProxyAuth.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import AppKit

/// 命令行认证的参数与执行流程集中在此，避免混入代理启停逻辑。
// MARK: - CLI Auth Commands

enum AuthCommand: Equatable {
    case copilotLogin
    case kiroGoogleLogin
    case kiroAWSLogin
    case kiroAWSAuthCode
    case kiroImport

    var arguments: [String] {
        switch self {
        case .copilotLogin:
            return ["-github-copilot-login"]
        case .kiroGoogleLogin:
            return ["-kiro-google-login"]
        case .kiroAWSLogin:
            return ["-kiro-aws-login"]
        case .kiroAWSAuthCode:
            return ["-kiro-aws-authcode"]
        case .kiroImport:
            return ["-kiro-import"]
        }
    }

    var displayName: String {
        switch self {
        case .copilotLogin:
            return "GitHub Device Code"
        case .kiroGoogleLogin:
            return "Google OAuth"
        case .kiroAWSLogin:
            return "AWS Builder ID (Device Code)"
        case .kiroAWSAuthCode:
            return "AWS Builder ID (Browser)"
        case .kiroImport:
            return "Import from Kiro IDE"
        }
    }
}

struct AuthCommandResult {
    let success: Bool
    let message: String
    let deviceCode: String?
}

extension CLIProxyManager {

    func runAuthCommand(_ command: AuthCommand) async -> AuthCommandResult {
        terminateAuthProcess()

        guard isBinaryInstalled else {
            return AuthCommandResult(success: false, message: "CLIProxyAPI binary not found", deviceCode: nil)
        }

        return await withCheckedContinuation { continuation in
            let newAuthProcess = Process()
            newAuthProcess.executableURL = URL(fileURLWithPath: effectiveBinaryPath)
            newAuthProcess.arguments = ["-config", configPath] + command.arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            newAuthProcess.standardOutput = outputPipe
            newAuthProcess.standardError = errorPipe

            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            newAuthProcess.environment = environment

            // Thread-safe state container for concurrent access
            final class AuthState: @unchecked Sendable {
                private let lock = NSLock()
                private var _capturedOutput = ""
                private var _hasResumed = false

                var capturedOutput: String {
                    get { lock.withLock { _capturedOutput } }
                    set { lock.withLock { _capturedOutput = newValue } }
                }

                func appendOutput(_ str: String) {
                    lock.withLock { _capturedOutput += str }
                }

                func tryResume() -> Bool {
                    lock.withLock {
                        if _hasResumed { return false }
                        _hasResumed = true
                        return true
                    }
                }
            }

            let state = AuthState()

            @Sendable func safeResume(_ result: AuthCommandResult) {
                guard state.tryResume() else { return }
                continuation.resume(returning: result)
            }

            if case .copilotLogin = command {
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        state.appendOutput(str)
                    }
                }
            }

            newAuthProcess.terminationHandler = { [weak self] terminatedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil

                Task { @MainActor in
                    self?.authProcess = nil
                }

                let status = terminatedProcess.terminationStatus
                if status == 0 {
                    safeResume(AuthCommandResult(
                        success: true,
                        message: "Authentication completed successfully.",
                        deviceCode: nil
                    ))
                }
            }

            do {
                try newAuthProcess.run()

                Task { @MainActor in
                    self.authProcess = newAuthProcess
                }

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.0) {
                    guard newAuthProcess.isRunning else { return }

                    if case .copilotLogin = command {
                        if let code = self.extractDeviceCode(from: state.capturedOutput) {
                            DispatchQueue.main.async {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }

                            safeResume(AuthCommandResult(
                                success: true,
                                message: "🌐 Browser opened for GitHub authentication.\n\n📋 Code copied to clipboard:\n\n\(code)\n\nJust paste it in the browser!",
                                deviceCode: code
                            ))
                        } else {
                            safeResume(AuthCommandResult(
                                success: true,
                                message: "🌐 Browser opened for GitHub authentication.\n\nCheck your browser for the device code.",
                                deviceCode: nil
                            ))
                        }
                    } else {
                        safeResume(AuthCommandResult(
                            success: true,
                            message: "🌐 Browser opened for authentication.\n\nPlease complete the login in your browser.",
                            deviceCode: nil
                        ))
                    }
                }
            } catch {
                safeResume(AuthCommandResult(
                    success: false,
                    message: "Failed to start auth process: \(error.localizedDescription)",
                    deviceCode: nil
                ))
            }
        }
    }

    private nonisolated func extractDeviceCode(from output: String) -> String? {
        if let codeRange = output.range(of: "enter the code: "),
           let endRange = output[codeRange.upperBound...].range(of: "\n") {
            return String(output[codeRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        for line in output.components(separatedBy: "\n") {
            if line.contains("enter the code:") {
                let parts = line.components(separatedBy: "enter the code:")
                if parts.count > 1 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }
}
