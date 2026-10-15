import AppKit
import CryptoKit
import Foundation

actor MonitorOAuthCoordinator {
    static let shared = MonitorOAuthCoordinator()

    private let githubClientID = "Iv1.b507a08c87ecfe98"
    private var activeTask: Task<MonitorAccount, Error>?
    private var activeTaskRevision: UInt64?
    private var callbackServer: MonitorOAuthCallbackServer?
    private var claudePending: (state: String, verifier: String, revision: UInt64)?
    // Claude 手动交换没有独立后台 Task，继续由原调用任务执行；同步世代只负责拒绝过期提交。
    // VM 在关闭／重试的首次挂起前推进世代，保险库与元数据在实际写入临界段复核同一个值。
    nonisolated private let claudeRevision = MonitorStateRevision()
    private let session: URLSession
    private let claudeVault: MonitorCredentialVault
    private let openClaudeURL: @MainActor @Sendable (URL) -> Bool
    private let waitForGitHubPoll: @Sendable (Int) async throws -> Void

    /// 正常应用仍使用原共享网络、保险库及系统浏览器；回归可注入离线会话和内存保险库。
    /// 依赖只读，不改变 shared、pending、activeTask 或凭据状态的原所有者。
    init(session: URLSession = .shared, claudeVault: MonitorCredentialVault = .shared,
         openClaudeURL: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) },
         waitForGitHubPoll: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.session = session
        self.claudeVault = claudeVault
        self.openClaudeURL = openClaudeURL
        self.waitForGitHubPoll = waitForGitHubPoll
    }

    /// 新授权与取消共用同步失效入口；不必排队等待正在交换 token 的 actor 方法返回。
    @discardableResult
    nonisolated func advanceClaudeSession() -> UInt64 { claudeRevision.advance() }

    private func requireClaudeSession(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard claudeRevision.current == revision else { throw CancellationError() }
    }

    func login(provider: AIProvider, revision requestedRevision: UInt64? = nil, githubHost: GitHubHost? = nil) async throws -> MonitorAccount {
        guard githubHost == nil || provider == .copilot else { throw MonitorOAuthError.invalidResponse }
        let revision = requestedRevision ?? advanceClaudeSession()
        try requireClaudeSession(revision)
        let task: Task<MonitorAccount, Error>
        switch provider {
        case .copilot:
            task = Task { try await githubDeviceFlow(host: githubHost ?? .githubCom, revision: revision) }
        case .kiro:
            task = Task { try await kiroDeviceFlow() }
        case .codex, .antigravity:
            task = Task { try await browserPKCEFlow(provider: provider) }
        default:
            throw MonitorOAuthError.flowNotImplemented(provider.displayName)
        }
        activeTask?.cancel()
        activeTask = task
        activeTaskRevision = revision
        defer {
            if activeTaskRevision == revision { activeTask = nil; activeTaskRevision = nil }
        }
        return try await task.value
    }

    func cancel(throughClaudeRevision revision: UInt64? = nil) {
        // 取消分别判断任务和 pending 的所属世代：旧设备授权仍须停止，新 Claude pending 不能清除。
        // 不能因“当前 Claude 已换代”整段返回，否则会漏掉仍在等待的旧 activeTask。
        let cutoff = revision ?? advanceClaudeSession()
        if let activeTaskRevision, activeTaskRevision <= cutoff {
            activeTask?.cancel()
            activeTask = nil
            self.activeTaskRevision = nil
            callbackServer?.stop()
            callbackServer = nil
        }
        if let pending = claudePending, pending.revision <= cutoff { claudePending = nil }
    }

    func beginClaudeLogin(revision requestedRevision: UInt64? = nil) async throws -> (url: URL, state: String) {
        let revision = requestedRevision ?? advanceClaudeSession()
        try requireClaudeSession(revision)
        let state = UUID().uuidString
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"),
            URLQueryItem(name: "redirect_uri", value: "https://platform.claude.com/oauth/code/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw MonitorOAuthError.browserOpenFailed
        }
        let opened = await openClaudeURL(url)
        // 打开浏览器也会让出 actor；取消或新一轮开始后不能重新挂回旧 pending。
        try requireClaudeSession(revision)
        guard opened else { throw MonitorOAuthError.browserOpenFailed }
        claudePending = (state, verifier, revision)
        return (url, state)
    }

    func completeClaudeLogin(code rawCode: String, expectedState: String? = nil) async throws -> MonitorAccount {
        guard let pending = claudePending else { throw MonitorOAuthError.expired }
        // UI 的旧提交不能借用新一轮 PKCE verifier；直接调用仍兼容原无 expectedState 的入口。
        if let expectedState, expectedState != pending.state { throw CancellationError() }
        try requireClaudeSession(pending.revision)
        defer {
            // 旧请求无论成功、失败或取消，都只能清理自己捕获的 pending。
            if claudePending?.revision == pending.revision, claudePending?.state == pending.state {
                claudePending = nil
            }
        }
        let pieces = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = pieces.first, !code.isEmpty else { throw MonitorOAuthError.invalidResponse }
        if pieces.count == 2, pieces[1] != pending.state { throw MonitorOAuthError.stateMismatch }
        let tokens = try await postJSON(
            url: "https://platform.claude.com/v1/oauth/token",
            body: [
                "grant_type": "authorization_code",
                "code": code,
                "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                "redirect_uri": "https://platform.claude.com/oauth/code/callback",
                "code_verifier": pending.verifier,
                "state": pending.state,
            ]
        )
        try requireClaudeSession(pending.revision)
        guard let accessToken = tokens["access_token"] as? String else { throw MonitorOAuthError.invalidResponse }
        let accountJSON = tokens["account"] as? [String: Any]
        let email = accountJSON?["email_address"] as? String ?? "Claude"
        let accountID = accountJSON?["uuid"] as? String
        let account = MonitorAccount.make(
            provider: .claude,
            accountKey: email,
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: nil,
            accountID: accountID,
            expiresAt: (tokens["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) },
            extra: [:]
        )
        // 不只在网络返回时判断：跨保险库／元数据 actor 排队后，真正写入前仍须同步校验。
        try await claudeVault.save(credential, metadata: account, revision: pending.revision, state: claudeRevision)
        try requireClaudeSession(pending.revision)
        return account
    }

    private struct BrowserConfiguration: Sendable {
        let authorizationURL: String
        let tokenURL: String
        let clientID: String
        let clientSecret: String?
        let scopes: String
        let preferredPort: UInt16?
        let callbackPath: String
        let extraAuthorizationValues: [String: String]
    }

    private func browserPKCEFlow(provider: AIProvider) async throws -> MonitorAccount {
        let config = try browserConfiguration(provider)
        let server = MonitorOAuthCallbackServer()
        callbackServer = server
        defer {
            server.stop()
            if callbackServer === server { callbackServer = nil }
        }
        let port = try await server.start(preferredPort: config.preferredPort)
        let callbackHost = provider == .codex ? "localhost" : "127.0.0.1"
        let redirectURI = "http://\(callbackHost):\(port)\(config.callbackPath)"
        let state = UUID().uuidString
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        guard var components = URLComponents(string: config.authorizationURL) else {
            throw MonitorOAuthError.invalidResponse
        }
        var values = config.extraAuthorizationValues
        values.merge([
            "client_id": config.clientID,
            "redirect_uri": redirectURI,
            "response_type": "code",
            "scope": config.scopes,
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        ]) { _, new in new }
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let authorizationURL = components.url else { throw MonitorOAuthError.invalidResponse }
        guard await MainActor.run(body: { NSWorkspace.shared.open(authorizationURL) }) else {
            throw MonitorOAuthError.browserOpenFailed
        }

        let callback = try await server.waitForCallback()
        let code = try Self.authorizationCode(from: callback, expectedState: state)
        var exchange = [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let secret = config.clientSecret { exchange["client_secret"] = secret }
        let tokens = try await postForm(url: config.tokenURL, values: exchange)
        return try await saveBrowserCredential(provider: provider, tokens: tokens)
    }

    private func browserConfiguration(_ provider: AIProvider) throws -> BrowserConfiguration {
        switch provider {
        case .codex:
            return BrowserConfiguration(
                authorizationURL: "https://auth.openai.com/oauth/authorize",
                tokenURL: "https://auth.openai.com/oauth/token",
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                clientSecret: nil,
                scopes: "openid profile email offline_access",
                preferredPort: 1455,
                callbackPath: "/auth/callback",
                extraAuthorizationValues: [
                    "codex_cli_simplified_flow": "true",
                    "id_token_add_organizations": "true",
                    "originator": "codex_cli_rs",
                ]
            )
        case .antigravity:
            return googleConfiguration(
                clientID: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
                clientSecret: "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"
            )
        default:
            throw MonitorOAuthError.flowNotImplemented(provider.displayName)
        }
    }

    private func googleConfiguration(clientID: String, clientSecret: String) -> BrowserConfiguration {
        BrowserConfiguration(
            authorizationURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: "https://oauth2.googleapis.com/token",
            clientID: clientID,
            clientSecret: clientSecret,
            scopes: "openid email profile https://www.googleapis.com/auth/cloud-platform",
            preferredPort: nil,
            callbackPath: "/oauth2callback",
            extraAuthorizationValues: ["access_type": "offline", "prompt": "consent"]
        )
    }

    private func saveBrowserCredential(provider: AIProvider, tokens: [String: Any]) async throws -> MonitorAccount {
        guard let accessToken = tokens["access_token"] as? String else { throw MonitorOAuthError.invalidResponse }
        let idToken = tokens["id_token"] as? String
        let refreshToken = tokens["refresh_token"] as? String
        let expiresIn = (tokens["expires_in"] as? NSNumber)?.doubleValue
        var email = MonitorIdentity.jwtString(idToken, claim: "email")
        var accountID: String?
        if provider == .codex {
            accountID = MonitorIdentity.jwtNestedString(
                idToken,
                namespace: "https://api.openai.com/auth",
                claim: "chatgpt_account_id"
            )
        } else {
            let user = try? await googleUserInfo(accessToken: accessToken)
            email = email ?? user?.email
            accountID = user?.id
        }
        let key = email ?? accountID ?? "\(provider.displayName) \(UUID().uuidString.prefix(8))"
        let account = MonitorAccount.make(
            provider: provider,
            accountKey: key,
            displayName: email ?? key,
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            extra: [:]
        )
        try await MonitorCredentialVault.shared.save(credential, metadata: account)
        return account
    }

    private func googleUserInfo(accessToken: String) async throws -> (email: String?, id: String?) {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorOAuthError.invalidResponse
        }
        return (json["email"] as? String, json["id"] as? String)
    }

    private func githubDeviceFlow(host: GitHubHost, revision: UInt64) async throws -> MonitorAccount {
        try requireClaudeSession(revision)
        let device = try await postForm(
            url: host.webURL("/login/device/code").absoluteString,
            values: ["client_id": githubClientID, "scope": "read:user"], github: true
        )
        try requireClaudeSession(revision)
        guard let deviceCode = device["device_code"] as? String,
              let userCode = device["user_code"] as? String,
              let verification = device["verification_uri"] as? String,
              !deviceCode.isEmpty, !userCode.isEmpty, userCode.count <= 128,
              !userCode.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              verification == host.webURL("/login/device").absoluteString,
              let verificationURL = URL(string: verification) else {
            throw MonitorOAuthError.invalidResponse
        }

        // 复用原浏览器注入边界，不新增授权协调器或任务宿主；验证码只能在所选主机的页面确认。
        _ = await openClaudeURL(verificationURL)
        try requireClaudeSession(revision)
        let interval = max(5, device["interval"] as? Int ?? 5)
        let expiresIn = device["expires_in"] as? Int ?? 900
        guard (1...3600).contains(expiresIn), interval <= 3600 else { throw MonitorOAuthError.invalidResponse }
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        await MainActor.run {
            NotificationCenter.default.post(
                name: .monitorOAuthDeviceCode,
                object: nil,
                userInfo: ["code": userCode, "url": verification, "revision": revision, "provider": AIProvider.copilot.rawValue]
            )
        }

        var pollInterval = interval
        while Date() < deadline {
            try Task.checkCancellation()
            try await waitForGitHubPoll(pollInterval)
            try requireClaudeSession(revision)
            guard Date() < deadline else { throw MonitorOAuthError.expired }
            let response = try await postForm(
                url: host.webURL("/login/oauth/access_token").absoluteString,
                values: [
                    "client_id": githubClientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ], github: true
            )
            try requireClaudeSession(revision)
            if let token = response["access_token"] as? String {
                guard !token.isEmpty else { throw MonitorOAuthError.invalidResponse }
                return try await saveGitHubCredential(token, host: host, revision: revision)
            }
            switch response["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": pollInterval += 5
            case "expired_token": throw MonitorOAuthError.expired
            case "access_denied": throw CancellationError()
            default: throw MonitorOAuthError.invalidResponse
            }
        }
        throw MonitorOAuthError.expired
    }

    private func saveGitHubCredential(_ token: String, host: GitHubHost, revision: UInt64) async throws -> MonitorAccount {
        try requireClaudeSession(revision)
        var request = URLRequest(url: host.apiURL("/user"))
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await GitHubHTTP.data(for: request, using: session)
        try requireClaudeSession(revision)
        guard let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String, !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MonitorOAuthError.invalidResponse
        }
        let account = MonitorAccount.make(
            provider: .copilot,
            accountKey: host.accountKey(login),
            displayName: host.accountKey(login),
            source: .quotioKeychain,
            credentialReference: "keychain",
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: token,
            refreshToken: nil,
            idToken: nil,
            accountID: String(describing: json["id"] ?? login),
            expiresAt: nil,
            extra: host.isGitHubCom ? [:] : ["github_host": host.value]
        )
        // 与 Claude 复用现有保险库依赖和同步世代；取消、换企业或新授权后，旧响应不能新增凭据。
        try requireClaudeSession(revision)
        try await claudeVault.save(credential, metadata: account, revision: revision, state: claudeRevision)
        try requireClaudeSession(revision)
        return account
    }

    private func kiroDeviceFlow() async throws -> MonitorAccount {
        let region = "us-east-1"
        let base = "https://oidc.\(region).amazonaws.com"
        let registration = try await postJSON(
            url: "\(base)/client/register",
            body: [
                "clientName": "Quotio Monitor",
                "clientType": "public",
                "scopes": ["codewhisperer:completions", "codewhisperer:analysis", "codewhisperer:conversations"],
            ]
        )
        guard let clientID = registration["clientId"] as? String,
              let clientSecret = registration["clientSecret"] as? String else {
            throw MonitorOAuthError.invalidResponse
        }
        let device = try await postJSON(
            url: "\(base)/device_authorization",
            body: [
                "clientId": clientID,
                "clientSecret": clientSecret,
                "startUrl": "https://view.awsapps.com/start",
            ]
        )
        guard let deviceCode = device["deviceCode"] as? String,
              let userCode = device["userCode"] as? String,
              let verification = (device["verificationUriComplete"] as? String) ?? (device["verificationUri"] as? String),
              let verificationURL = URL(string: verification) else {
            throw MonitorOAuthError.invalidResponse
        }
        _ = await MainActor.run { NSWorkspace.shared.open(verificationURL) }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .monitorOAuthDeviceCode,
                object: nil,
                userInfo: ["code": userCode, "url": verification]
            )
        }
        var interval = max(5, device["interval"] as? Int ?? 5)
        let deadline = Date().addingTimeInterval(TimeInterval(device["expiresIn"] as? Int ?? 600))
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))
            let result: [String: Any]
            do {
                result = try await postJSON(
                    url: "\(base)/token",
                    body: [
                        "clientId": clientID,
                        "clientSecret": clientSecret,
                        "deviceCode": deviceCode,
                        "grantType": "urn:ietf:params:oauth:grant-type:device_code",
                    ]
                )
            } catch MonitorOAuthError.provider(let code) where code == "authorization_pending" {
                continue
            } catch MonitorOAuthError.provider(let code) where code == "slow_down" {
                interval += 5
                continue
            }
            guard let accessToken = result["accessToken"] as? String,
                  let refreshToken = result["refreshToken"] as? String else {
                throw MonitorOAuthError.invalidResponse
            }
            let expiresAt = Date().addingTimeInterval(TimeInterval(result["expiresIn"] as? Int ?? 3600))
            let identity = await KiroQuotaFetcher().authenticatedAccountIdentity(
                accessToken: accessToken,
                expiresAt: expiresAt,
                clientID: clientID,
                clientSecret: clientSecret,
                region: region
            )
            let accountKey = Self.kiroAccountKey(identity: identity, clientID: clientID)
            let account = MonitorAccount.make(
                provider: .kiro,
                accountKey: accountKey,
                displayName: identity ?? "AWS Builder ID",
                source: .quotioKeychain,
                credentialReference: "keychain",
                canDelete: true
            )
            let credential = MonitorOAuthCredential(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: nil,
                accountID: identity,
                expiresAt: expiresAt,
                extra: [
                    "authMethod": "IdC",
                    "clientId": clientID,
                    "clientSecret": clientSecret,
                    "region": region,
                ]
            )
            try await MonitorCredentialVault.shared.save(credential, metadata: account)
            return account
        }
        throw MonitorOAuthError.expired
    }

    nonisolated static func kiroAccountKey(identity: String?, clientID: String) -> String {
        if let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty {
            return identity
        }
        return "AWS Builder ID • " + String(MonitorIdentity.fingerprint(clientID).prefix(8))
    }

    private func postJSON(url: String, body: [String: Any]) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else { throw MonitorOAuthError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorOAuthError.invalidResponse
        }
        guard 200...299 ~= http.statusCode else {
            throw MonitorOAuthError.provider(
                (json["error"] as? String) ?? (json["errorCode"] as? String) ?? "http_\(http.statusCode)"
            )
        }
        return json
    }

    private func postForm(url: String, values: [String: String], github: Bool = false) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else { throw MonitorOAuthError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = values
            .map { "\($0.key.monitorFormEncoded)=\($0.value.monitorFormEncoded)" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let result: (Data, URLResponse)
        if github { result = try await GitHubHTTP.data(for: request, using: session) }
        else { result = try await session.data(for: request) }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorOAuthError.invalidResponse
        }
        return json
    }

    nonisolated private static func randomURLSafeString(byteCount: Int) -> String {
        base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    nonisolated static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              values.first(where: { $0.name == "state" })?.value == expectedState else {
            throw MonitorOAuthError.stateMismatch
        }
        guard let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MonitorOAuthError.invalidResponse
        }
        return code
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Notification.Name {
    static let monitorOAuthDeviceCode = Notification.Name("MonitorOAuth.deviceCode")
}

nonisolated enum MonitorOAuthError: LocalizedError {
    case flowNotImplemented(String)
    case invalidResponse
    case expired
    case stateMismatch
    case browserOpenFailed
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .flowNotImplemented(let provider): "Quotio-managed login for \(provider) is not available yet. Sign in with the provider's native CLI and refresh Monitor Only."
        case .invalidResponse: "The OAuth provider returned an invalid response."
        case .expired: "The device authorization expired. Please try again."
        case .stateMismatch: "The OAuth callback state did not match the login request."
        case .browserOpenFailed: "Quotio could not open the OAuth page in your browser."
        case .provider(let code): "The OAuth provider returned \(code)."
        }
    }
}

private extension String {
    nonisolated var monitorFormEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
