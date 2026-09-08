import Foundation
import Darwin

/// Pi 的安装位置与会话目录互不绑定：Homebrew、npm 和独立发行包都使用同一套数据协议。
/// 只检查明确的 bin 目录和 Node 版本目录，不启动交互 shell、不执行包管理器，也不扫描整个用户目录。
nonisolated struct PiAgentInstallation {
    let homeDirectory: String
    let environment: [String: String]
    var systemBinaryDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    var binaryDirectories: [String] {
        var directories = (environment["PATH"] ?? "").components(separatedBy: ":").filter { !$0.isEmpty }
        // 显式安装前缀优先于系统兜底；pnpm 的全局可执行文件直接位于 PNPM_HOME。
        for (key, suffix) in [("HOMEBREW_PREFIX", "/bin"), ("NPM_CONFIG_PREFIX", "/bin"),
                              ("npm_config_prefix", "/bin"), ("PNPM_HOME", ""), ("BUN_INSTALL", "/bin"),
                              ("VOLTA_HOME", "/bin"), ("ASDF_DATA_DIR", "/shims")] {
            if let value = environment[key], !value.isEmpty { directories.append(value + suffix) }
        }
        directories += systemBinaryDirectories
        directories += ["~/.local/bin", "~/bin", "~/.npm-global/bin", "~/.npm/bin", "~/.bun/bin",
                        "~/Library/pnpm", "~/.local/share/pnpm", "~/.yarn/bin", "~/.config/yarn/global/node_modules/.bin",
                        "~/.volta/bin", "~/.asdf/shims", "~/.local/share/mise/shims"]
        let nvm = environment["NVM_DIR"] ?? "~/.nvm"
        directories += versionedDirectories(root: nvm + "/versions/node", suffix: "/bin")
        // fnm 在 macOS 的默认目录与 Linux 不同，同时兼容 XDG 与早期 ~/.fnm 安装。
        let fnmRoots = [environment["FNM_DIR"], environment["XDG_DATA_HOME"].map { $0 + "/fnm" },
                        "~/Library/Application Support/fnm", "~/.local/share/fnm", "~/.fnm"].compactMap { $0 }
        for root in fnmRoots {
            directories += versionedDirectories(root: root + "/node-versions", suffix: "/installation/bin")
        }
        var seen = Set<String>()
        return directories.map { PiSessionPaths.expand($0, homeDirectory: homeDirectory) }.filter { seen.insert($0).inserted }
    }

    func findBinary() -> String? {
        binaryDirectories.map { $0 + "/pi" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// GUI 的 PATH 常缺少 node/npm。保留调用者已有环境，把选中的 Pi 所在目录放在首位，
    /// 版本探测与插件安装复用此环境，避免「检测到脚本，却无法通过 /usr/bin/env node 启动」。
    func processEnvironment(binaryPath: String) -> [String: String] {
        var result = environment
        let directory = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
        result["PATH"] = ([directory] + binaryDirectories).joined(separator: ":")
        return result
    }

    /// npm、新旧命名空间和 Homebrew 的 JS 安装均可直接从实际包读取版本。
    /// 解析符号链接后只向上检查少量 package.json，避免依赖 GUI 是否能找到 Node。
    func packageVersion(binaryPath: String) -> String? {
        var directory = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let file = directory.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: file),
               let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = package["name"] as? String,
               ["@earendil-works/pi-coding-agent", "@mariozechner/pi-coding-agent"].contains(name),
               let version = package["version"] as? String {
                return Self.validVersion(version)
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    /// 独立二进制及包管理器包装脚本没有可读的包元数据时，才运行只读版本命令。
    /// 子进程设置硬超时，输出限制为短版本号；退出错误或 node 报错不能显示成版本号。
    func version(binaryPath: String) async -> String? {
        if let version = packageVersion(binaryPath: binaryPath) { return version }
        let processEnvironment = processEnvironment(binaryPath: binaryPath)
        return await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["--version"]
            process.environment = processEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timeout = DispatchWorkItem {
                // 仅终止本次创建的探测进程；不查找或操作用户已经运行的 Pi 会话。
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
            defer { timeout.cancel() }
            process.waitUntilExit()
            // 不等待包装器后代进程关闭管道，也不无限收集异常输出；大输出阻塞同样受上面的超时约束。
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1, process.terminationStatus == 0,
                  let data = try? pipe.fileHandleForReading.read(upToCount: 1025), data.count <= 1024,
                  let output = String(data: data, encoding: .utf8) else { return nil }
            return Self.validVersion(output)
        }.value
    }

    private static func validVersion(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 发行版通常仅输出 SemVer；也兼容带 pi/v 前缀的包装器，拒绝错误信息和任意多行正文。
        guard value.range(of: #"^(?:pi\s+)?v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?$"#,
                          options: .regularExpression) != nil else { return nil }
        return value
    }

    private func versionedDirectories(root: String, suffix: String) -> [String] {
        let expanded = PiSessionPaths.expand(root, homeDirectory: homeDirectory)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: expanded) else { return [] }
        // 使用数字比较，v22 应优先于 v9；字符串逆序会选中旧 Node，导致新版 Pi 无法启动。
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { expanded + "/" + $0 + suffix }
    }
}
