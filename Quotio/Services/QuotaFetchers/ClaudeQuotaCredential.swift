// 移植自 Quotio d70adc6 / c29922a（MIT），适配 QuotioPlus 的凭据存储与旧架构。
import Darwin
import Foundation

/// CLI 拥有的令牌只能观察；刷新会消耗单次 refresh token，可能使 Claude Code 退出登录。
nonisolated enum ClaudeCredentialOwnership {
    static func configDirectory(environment: [String: String]) -> String {
        let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSString(string: configured?.isEmpty == false ? configured! : "~/.claude").expandingTildeInPath
    }

    /// macOS 的 /tmp、/var、/etc 是系统别名；只规范化这些别名，其余链接仍由安全打开拒绝。
    static func canonicalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        for alias in ["/etc", "/tmp", "/var"]
        where standardized == alias || standardized.hasPrefix(alias + "/") {
            return "/private" + standardized
        }
        return standardized
    }

    static func allowsRefresh(file: SecureClaudeCredentialFile, environment: [String: String]) -> Bool {
        let directory = canonicalPath(configDirectory(environment: environment))
        // 硬链接也可能共享 CLI 的刷新令牌，因此多名称文件一律保持只读。
        return file.referenceCount == 1 && file.path != directory && !file.path.hasPrefix(directory + "/")
    }
}

/// 凭据快照保留来源；去重后仍能把刷新结果写回确切的自有文件或保险库条目。
nonisolated struct ClaudeQuotaCredential: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case external
        case file(String)
        case vault(MonitorAccount)
    }
    let accountKey: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    var allowsRefresh: Bool
    var source: Source = .external

    static func load(data: Data, allowsRefresh: Bool, source: Source = .external) -> Self? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = json["claudeAiOauth"] as? [String: Any]
        guard let access = nonEmpty((json["access_token"] as? String) ?? (oauth?["accessToken"] as? String)) else { return nil }
        let account = nonEmpty((json["email"] as? String) ?? (oauth?["email"] as? String)) ?? "Claude Code"
        let refresh = nonEmpty((json["refresh_token"] as? String) ?? (oauth?["refreshToken"] as? String))
        let expiry: Date?
        if let milliseconds = (oauth?["expiresAt"] as? NSNumber)?.doubleValue {
            expiry = milliseconds.isFinite ? Date(timeIntervalSince1970: milliseconds / 1000) : nil
        } else if let value = json["expired"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiry = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        } else {
            expiry = nil
        }
        return Self(accountKey: account, accessToken: access, refreshToken: refresh,
                    expiresAt: expiry, allowsRefresh: allowsRefresh, source: source)
    }

    static func load(path: String, environment: [String: String]) -> Self? {
        guard let file = SecureClaudeCredentialFile(path: path), let data = file.read() else { return nil }
        return load(data: data, allowsRefresh: ClaudeCredentialOwnership.allowsRefresh(file: file, environment: environment),
                    source: .file(file.path))
    }

    /// 必须先收集所有外部刷新令牌再按账号去重，否则复制到自有目录的 CLI 令牌会错误获得刷新权限。
    /// 账号名不同也不能改变令牌归属；优先选择可独立刷新的自有凭据，其次选择尚未过期的可读凭据。
    static func uniqueByAccountKey(_ credentials: [Self], now: Date = Date()) -> [Self] {
        let externalTokens = Set(credentials.compactMap { $0.allowsRefresh ? nil : $0.refreshToken })
        var positions: [String: Int] = [:]
        var result: [Self] = []
        for var credential in credentials {
            if let token = credential.refreshToken, externalTokens.contains(token) {
                credential.allowsRefresh = false
            }
            if let index = positions[credential.accountKey] {
                let selected = result[index]
                let canRefresh = credential.allowsRefresh && credential.refreshToken != nil
                let selectedCanRefresh = selected.allowsRefresh && selected.refreshToken != nil
                let usable = credential.expiresAt.map { $0 > now } ?? true
                let selectedUsable = selected.expiresAt.map { $0 > now } ?? true
                if (canRefresh && !selectedCanRefresh) || (!selectedCanRefresh && usable && !selectedUsable) {
                    result[index] = credential
                }
            } else {
                positions[credential.accountKey] = result.count
                result.append(credential)
            }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

/// 绑定已验证的文件及父目录描述符，避免“校验路径后再按路径读取”留下链接替换窗口。
nonisolated final class SecureClaudeCredentialFile {
  let path: String
  let referenceCount: UInt64

  private let parentDescriptor: Int32
  private let descriptor: Int32
  private let name: String
  private let device: dev_t
  private let inode: ino_t

  init?(path: String) {
    let standardized = ClaudeCredentialOwnership.canonicalPath(path)
    let components = URL(fileURLWithPath: standardized).pathComponents.dropFirst()
    guard let name = components.last, name != ".", name != ".." else { return nil }

    // 逐级使用 O_NOFOLLOW 打开父目录，拒绝经任意符号链接抵达的凭据。
    var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { return nil }
    for component in components.dropLast() {
      let next = component.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      Darwin.close(parent)
      guard next >= 0 else { return nil }
      parent = next
    }

    let file = name.withCString {
      Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    guard file >= 0 else {
      Darwin.close(parent)
      return nil
    }
    var status = stat()
    guard Darwin.fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(file)
      Darwin.close(parent)
      return nil
    }

    self.path = standardized
    self.referenceCount = UInt64(status.st_nlink)
    self.parentDescriptor = parent
    self.descriptor = file
    self.name = name
    self.device = status.st_dev
    self.inode = status.st_ino
  }

  deinit {
    Darwin.close(descriptor)
    Darwin.close(parentDescriptor)
  }

  func read() -> Data? {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    return try? handle.readToEnd() ?? Data()
  }

  // 保存时再次校验文件身份，使用同一父目录描述符写入 0600 临时文件并原子替换。
  func replaceAtomically(with data: Data) -> Bool {
    var current = stat()
    let unchanged = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW) == 0
    }
    guard unchanged, current.st_mode & S_IFMT == S_IFREG,
      current.st_dev == device, current.st_ino == inode, current.st_nlink == 1
    else { return false }

    let temporaryName = ".\(name).\(UUID().uuidString).tmp"
    let temporary = temporaryName.withCString {
      Darwin.openat(
        parentDescriptor, $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o600)
      )
    }
    guard temporary >= 0 else { return false }

    var succeeded = data.withUnsafeBytes { buffer -> Bool in
      guard let base = buffer.baseAddress else { return true }
      var written = 0
      while written < buffer.count {
        let count = Darwin.write(temporary, base.advanced(by: written), buffer.count - written)
        if count <= 0 {
          if errno == EINTR { continue }
          return false
        }
        written += count
      }
      return Darwin.fsync(temporary) == 0
    }
    if Darwin.close(temporary) != 0 { succeeded = false }

    if succeeded {
      succeeded = temporaryName.withCString { source in
        name.withCString { destination in
          Darwin.renameat(parentDescriptor, source, parentDescriptor, destination) == 0
        }
      }
    }
    if !succeeded {
      temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
    }
    return succeeded
  }
}
