import Darwin
import Foundation
import Network

/// 多组真实 CLI 回归共用的 Anthropic HTTP/SSE 最小网关；锁只保护脱敏快照和独立准入目录。
/// 不转发请求。完整 body 处理完即释放，只记录模型、beta 与假密钥是否匹配。
final class ClaudeLoopbackGateway: @unchecked Sendable {
    struct Request: Sendable { let model: String; let beta: String; let usesFixtureKey: Bool }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ClaudeCompatibility.loopback", qos: .userInitiated)
    private let lock = NSLock()
    private var records: [Request] = []
    /// 默认 nil 保持既有用例的 HTTP 夹具行为；完整流程回归传入独立白名单。
    /// 白名单由测试情境定义，绝不由被测配置计划的解析结果反向生成，才能发现别名／1M 剥离错误。
    private var acceptedModels: Set<String>?
    /// 仅子代理回归启用：第一轮返回一次预置 Agent 调用，此后返回文本，不执行外部模型或真实工具。
    private let subagentType: String?
    var requests: [Request] { lock.withLock { records } }
    var url: String { "http://127.0.0.1:\(listener.port!.rawValue)" }

    init(subagentType: String? = nil, acceptedModels: Set<String>? = nil) throws {
        self.subagentType = subagentType
        self.acceptedModels = acceptedModels
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        // Network 要求 start 前安装接收器；监听就绪后才允许测试读取端口和启动 CLI。
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel(); throw URLError(.cannotConnectToHost)
        }
    }
    func stop() { listener.cancel() }

    /// 模拟账号停用／新增后真正发生变化的后端目录；不启动真实 CPA 或访问任何账号。
    func replaceAcceptedModels(_ models: Set<String>) { lock.withLock { acceptedModels = models } }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count < 4_194_304, error == nil else { connection.cancel(); return }
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let fields = lines.dropFirst().reduce(into: [String: String]()) { fields, line in
                    guard let colon = line.firstIndex(of: ":") else { return }
                    fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(fields["content-length"] ?? "0") ?? 0
                if bytes.count - boundary.upperBound >= length {
                    let body = Data(bytes[boundary.upperBound..<boundary.upperBound + length])
                    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                    let path = lines.first ?? ""
                    let model = json["model"] as? String ?? ""
                    var invokesSubagent = false
                    let acceptsModel = self.lock.withLock { self.acceptedModels?.contains(model) ?? true }
                    if path.contains("/v1/messages") && !path.contains("count_tokens") {
                        let auth = fields["x-api-key"] ?? fields["authorization"] ?? ""
                        self.lock.withLock {
                            invokesSubagent = self.subagentType != nil && self.records.isEmpty
                            self.records.append(.init(model: model, beta: fields["anthropic-beta"] ?? "",
                                usesFixtureKey: auth == "fixture-only-key" || auth == "Bearer fixture-only-key"))
                        }
                    }
                    if path.contains("/v1/models") {
                        // 返回 OpenAI 兼容目录，允许流程通过生产目录客户端取数，而非把夹具数组直接当结果。
                        let ids = self.lock.withLock { Array(self.acceptedModels ?? []).sorted() }
                        self.sendJSON(connection, object: ["object": "list", "data": ids.map {
                            ["id": $0, "object": "model", "owned_by": "fixture"]
                        }])
                    } else if !acceptsModel && path.contains("/v1/messages") {
                        self.sendJSON(connection, status: "400 Bad Request", object: ["type": "error", "error": [
                            "type": "invalid_request_error", "message": "Unknown fixture model: " + model
                        ]])
                    } else {
                        self.reply(connection, model: model, countTokens: path.contains("count_tokens"),
                                   invokesSubagent: invokesSubagent, streams: json["stream"] as? Bool ?? true)
                    }
                    return
                }
            }
            if ended { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
        }
    }

    private func sendJSON(_ connection: NWConnection, status: String = "200 OK", object: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func reply(_ connection: NWConnection, model: String, countTokens: Bool, invokesSubagent: Bool, streams: Bool) {
        if !countTokens && !streams {
            // /model 验证自定义型号会发非流式探测；同一网关也必须支持这条真实 CLI 路径。
            self.sendJSON(connection, object: ["id": "msg_fixture", "type": "message", "role": "assistant",
                "model": model, "content": [["type": "text", "text": "fixture"]], "stop_reason": "end_turn",
                "stop_sequence": NSNull(), "usage": ["input_tokens": 1, "output_tokens": 1]])
            return
        }
        let block: [String: Any] = invokesSubagent
            ? ["type": "tool_use", "id": "toolu_fixture", "name": "Agent", "input": [:]]
            : ["type": "text", "text": ""]
        let input: [String: Any] = ["description": "Isolated subagent fixture", "prompt": "Return fixture only.",
                                   "subagent_type": subagentType ?? "", "run_in_background": false]
        let delta: [String: Any] = invokesSubagent
            ? ["type": "input_json_delta", "partial_json": String(decoding: try! JSONSerialization.data(withJSONObject: input), as: UTF8.self)]
            : ["type": "text_delta", "text": "fixture"]
        let events: [(String, [String: Any])] = [
            ("message_start", ["type": "message_start", "message": ["id": "msg_fixture", "type": "message", "role": "assistant",
                "model": model, "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": ["input_tokens": 1, "output_tokens": 0]]]),
            ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": block]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": delta]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
            ("message_delta", ["type": "message_delta", "delta": ["stop_reason": invokesSubagent ? "tool_use" : "end_turn", "stop_sequence": NSNull()], "usage": ["output_tokens": 1]]),
            ("message_stop", ["type": "message_stop"])]
        let body = countTokens ? "{\"input_tokens\":1}" : events.map { event, object in
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return "event: \(event)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }.joined()
        let response = "HTTP/1.1 200 OK\r\nContent-Type: \(countTokens ? "application/json" : "text/event-stream")\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// 真实交互式 Claude CLI 的有限生命周期夹具，不模拟它的 settings.json 写入逻辑。
/// 只在临时目录预置 onboarding，并按实际屏幕确认自身临时工作区，再通过 PTY 输入 /model。
/// 模型选择与保存工作完全交给 CLI，不由夹具模拟它的设置文件重写。
/// 用例结束或超时仅清理本夹具创建的 PID，不能用 pkill 影响用户正在运行的终端会话。
final class ClaudeInteractiveWorkflowSession {
    static let executable = "/opt/homebrew/bin/claude"
    private let process = Process()
    private let terminal: FileHandle
    private var transcript = Data()
    private let settings: URL
    private let workingRoot: URL
    private var stopped = false
    private(set) var savedByInteractiveCommand = false

    /// 所有网络出站默认拒绝，只给本地假网关开放 loopback。
    /// 同时禁止触碰真实 Claude 用户目录和 Keychain；不修改 HOME、CODEX_HOME 或父进程环境。
    private static var sandboxProfile: String {
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        func literal(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let paths = [realHome.appendingPathComponent(".claude").path,
                     realHome.appendingPathComponent(".claude.json").path,
                     realHome.appendingPathComponent("Library/Keychains").path]
        return "(version 1) (allow default) (deny network-outbound) "
            // SBPL 的 remote ip 只接受 * 或 localhost；不能写字面 IPv4 地址导致整个隔离器拒绝启动。
            + "(allow network-outbound (remote ip \"localhost:*\")) "
            + paths.map { "(deny file-read* file-write* (subpath \(literal($0))))" }.joined(separator: " ")
    }

    /// 严格列出子进程环境，避免 CI／开发终端已有的角色、OAuth、代理、MCP 或遥测设置流入用例。
    /// CLAUDE_CONFIG_DIR 同时决定当前 CLI 的 settings.json 与全局 .claude.json，不借用真实登录。
    /// 地址与认证只从生产应用写出的 settings.env 读取，不能额外导出 API_KEY／BASE_URL，
    /// 否则即使配置生成器写错连接，测试也可能被环境兜底掩盖，还会触发双认证来源警告。
    /// gatewayURL 仅为保留现有调用签名，刻意不进入环境；原 loopback 出站沙箱仍是网络隔离边界。
    static func environment(root: URL, directory: URL, gatewayURL: String) -> [String: String] {
        ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "TMPDIR": root.path, "SHELL": "/bin/zsh",
         "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "COLUMNS": "120", "LINES": "40",
         "CLAUDE_CONFIG_DIR": directory.path,
         "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
         "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
         "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"]
    }

    /// 只记录 CLI 自己使用的初始同意状态；绝不把被测 model／modelPicker／管理标记写入这份状态。
    /// 路径依据当前 CLI 的 CLAUDE_CONFIG_DIR 契约，避免跑到真实 ~/.claude.json 完成向导。
    static func prepareGlobalState(directory: URL, root: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state: [String: Any] = ["hasCompletedOnboarding": true, "theme": "dark", "numStartups": 1,
            "autoUpdates": false, "autoConnectIde": false,
            "customApiKeyResponses": ["approved": ["fixture-only-key"], "rejected": []],
            "projects": [root.path: ["hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true,
                                    "projectOnboardingSeenCount": 1, "mcpServers": [:]]]]
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(".claude.json"), options: .atomic)
    }

    init(root: URL, directory: URL, gatewayURL: String) throws {
        let canonicalRoot = root.resolvingSymlinksInPath()
        let canonicalTemporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        // 这个交互夹具只允许确认自己刚创建的临时工作区；拒绝任何用户项目或外部配置路径。
        guard canonicalRoot.deletingLastPathComponent().path == canonicalTemporary.path,
              canonicalRoot.lastPathComponent.hasPrefix("ClaudeConfigurationWorkflow-"),
              directory.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot.path + "/") else {
            throw NSError(domain: "ClaudeInteractiveWorkflow", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "交互式回归只允许使用自身创建的临时工作区"])
        }
        workingRoot = canonicalRoot
        settings = directory.appendingPathComponent("settings.json")
        try Self.prepareGlobalState(directory: directory, root: root)
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Self.posixError() }
        terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let childTerminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            try? childTerminal.close(); try? terminal.close(); throw Self.posixError()
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.sandboxProfile, Self.executable, "--setting-sources", "user",
                             // 当前 CLI 的 MCP 配置要求显式 mcpServers 对象；空根对象会在启动阶段校验失败。
                             "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "",
                             "--system-prompt", "Local fixture only."]
        process.currentDirectoryURL = root
        process.environment = Self.environment(root: root, directory: directory, gatewayURL: gatewayURL)
        process.standardInput = childTerminal
        process.standardOutput = childTerminal
        process.standardError = childTerminal
        do { try process.run() }
        catch { try? childTerminal.close(); try? terminal.close(); throw error }
        // Process 已为子进程复制从端描述符；父进程必须关闭自己的从端，以便退出后读到 EOF。
        try childTerminal.close()
    }

    deinit { stop() }

    var text: String {
        String(decoding: transcript, as: UTF8.self)
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{001B}\\][^\u{0007}]*\u{0007}", with: "", options: .regularExpression)
    }

    /// Ink 可能用 CSI 移动光标代替空格，也会按终端宽度折行；匹配语义时统一去掉空白。
    /// 原始脱敏输出仍保留在 text 用于失败证据，不能靠放宽断言伪造正常保存回执。
    private var compactText: String { text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) }

    /// 真实 CLI 的页脚随权限模式变化：当前版本可显示“← for agents”，并非始终“? for shortcuts”。
    /// 必须同时出现输入箭头与主输入页特有页脚，不能把信任对话框的选择箭头当成可输入模型命令。
    private var hasNormalInputScreen: Bool {
        let output = compactText
        return output.contains("❯") && ["forshortcuts", "shift+tabtocycle", "foragents"].contains { output.contains($0) }
    }

    /// 通过普通 /model 命令走正常 userSettings 提交；没有 --model 标志，也不手工重写 settings.json。
    /// 同时等待落盘和“已保存为后续默认”的回执，防止仅改当前会话却让测试误判成功。
    func saveDefaultModel(_ selector: String) throws {
        try prepareNormalInput()
        try send("/model " + selector)
        // 与终端实际输入一致，确认键独立发送，避免整段数据被 CLI 的批量粘贴识别吞掉回车。
        Thread.sleep(forTimeInterval: 0.1)
        try send("\r")
        try wait(timeout: 20, reason: "等待 /model 正常保存默认模型") {
            guard let data = try? Data(contentsOf: self.settings),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["model"] as? String == selector else { return false }
            return self.compactText.contains("savedasyourdefaultfornewsessions")
        }
        savedByInteractiveCommand = true
        try send("/exit")
        Thread.sleep(forTimeInterval: 0.1)
        try send("\r")
        try wait(timeout: 8, reason: "等待交互式 CLI 退出") { !self.process.isRunning }
        drain()
    }

    /// 当前 CLI 的项目信任可能写入新存储，旧 global projects 预置不一定会生效。
    /// 只对 init 已校验的自身临时 root，且屏幕明确显示同一路径时，执行真正的信任选择。
    /// 这不是跳过／屏蔽向导；确认后仍等待正常输入页，并由后续 /model 真实提交配置。
    private func prepareNormalInput() throws {
        try wait(timeout: 20, reason: "等待临时工作区信任或正常输入提示") {
            self.hasNormalInputScreen
                || (self.compactText.contains("Accessingworkspace:") && self.compactText.contains("Yes,Itrustthisfolder"))
        }
        if hasNormalInputScreen { return }
        let rootOnScreen = workingRoot.path.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard process.currentDirectoryURL?.resolvingSymlinksInPath().path == workingRoot.path,
              compactText.contains(rootOnScreen) else {
            throw NSError(domain: "ClaudeInteractiveWorkflow", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "拒绝确认不属于当前临时工作区的信任屏幕：\n" + String(text.suffix(12000))])
        }
        // 本机 CLI 2.1.292 的信任组件有 150ms 输入保护（J2），由 held→settled 更换 remountKey。
        // 第一帧就按 Down 会先选中 Yes，又被保护期的重挂载复位到 No；随后 Enter 因而拒绝信任。
        // 受控 PTY 复现已证实等待 400ms 后一次 Down/Enter 即可正常确认；这里等待稳定后才首次输入，
        // 不循环点击、不绕过信任，也不修改 CLI 保护开关或用户全局信任数据库。
        Thread.sleep(forTimeInterval: 0.4)
        drain()
        if compactText.contains("❯No,exit") {
            try send("\u{001B}[B")
            Thread.sleep(forTimeInterval: 0.15)
        } else if !compactText.contains("❯Yes,Itrustthisfolder") {
            throw NSError(domain: "ClaudeInteractiveWorkflow", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "临时工作区信任选择状态无法确认：\n" + String(text.suffix(12000))])
        }
        try send("\r")
        try wait(timeout: 20, reason: "等待临时工作区信任后的正常输入页") {
            self.hasNormalInputScreen
        }
    }

    /// 新启动的 --print 进程不指定模型，必须读取刚才交互保存、随后经账号同步保留的真实用户设置。
    /// 实际 HTTP 请求由独立白名单网关判断，不能只以 CLI 成功退出作为配置正确的证据。
    static func runSavedDefault(root: URL, directory: URL, gatewayURL: String) throws -> (status: Int32, text: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", sandboxProfile, executable, "--bare", "--setting-sources", "user",
            "--no-session-persistence", "--tools", "", "--print", "--output-format", "json", "--max-turns", "1",
            "--system-prompt", "Local fixture only.", "Reply fixture."]
        process.currentDirectoryURL = root
        process.environment = environment(root: root, directory: directory, gatewayURL: gatewayURL)
        process.standardOutput = output; process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            // 非交互读取也要有硬截止；只操作当前 Process 的 PID，不依赖 CLI 响应 SIGTERM。
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        guard process.processIdentifier > 0 else { try? terminal.close(); return }
        if process.isRunning {
            process.terminate()
            let limit = Date().addingTimeInterval(2)
            while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        drain()
        try? terminal.close()
    }

    private func wait(timeout: TimeInterval, reason: String, predicate: () -> Bool) throws {
        let limit = Date().addingTimeInterval(timeout)
        repeat {
            drain()
            if predicate() { return }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.025)
        } while Date() < limit
        drain()
        if predicate() { return }
        throw NSError(domain: "ClaudeInteractiveWorkflow", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: reason + "失败；CLI 输出：\n" + String(text.suffix(12000))])
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(terminal.fileDescriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            transcript.append(contentsOf: buffer.prefix(count))
            // 输入完全是临时夹具，仍限制内存与失败附件大小，避免重复终端重绘无限积累。
            if transcript.count > 1_048_576 { transcript.removeFirst(transcript.count - 1_048_576) }
        }
    }

    private func send(_ value: String) throws {
        let bytes = Data(value.utf8)
        try bytes.withUnsafeBytes { raw in
            guard Darwin.write(terminal.fileDescriptor, raw.baseAddress, raw.count) == raw.count else { throw Self.posixError() }
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
