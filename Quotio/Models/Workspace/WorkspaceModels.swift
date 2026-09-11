//
//  WorkspaceModels.swift
//  Quotio - Workspace Models for Sessions, Skills & Storage
//

import Foundation
import SwiftUI

// MARK: - Workspace Tab

public nonisolated enum WorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case storage = "storage"
    case skills = "skills"
    case sessions = "sessions"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .storage: return "workspace.tab.storage".localizedStatic()
        case .skills: return "workspace.tab.skills".localizedStatic()
        case .sessions: return "workspace.tab.sessions".localizedStatic()
        }
    }

    public var icon: String {
        switch self {
        case .storage: return "internaldrive.fill"
        case .skills: return "puzzlepiece.extension.fill"
        case .sessions: return "bubble.left.and.bubble.right.fill"
        }
    }
}

// MARK: - Workspace Skill Sub Tab

public nonisolated enum WorkspaceSkillSubTab: String, CaseIterable, Identifiable, Sendable {
    case installed = "installed"
    case discover = "discover"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .installed: return "已纳管技能"
        case .discover: return "从 GitHub 发现"
        }
    }

    public var icon: String {
        switch self {
        case .installed: return "folder.badge.gearshape"
        case .discover: return "shippingbox.fill"
        }
    }
}

// MARK: - Workspace Agent

public nonisolated enum WorkspaceAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case opencode = "opencode"
    case pi = "pi"
    case agy = "agy"

    public static let gemini = agy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        case .agy: return "Antigravity"
        }
    }

    public var systemIcon: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal"
        case .pi: return "terminal.fill"
        case .agy: return "sparkles"
        }
    }

    public var color: Color {
        switch self {
        case .claude: return Color(hex: "D97706") ?? .orange
        case .codex: return Color(hex: "10A37F") ?? .green
        case .opencode: return Color(hex: "8B5CF6") ?? .purple
        case .pi: return Color(hex: "F97316") ?? .orange
        case .agy: return Color(hex: "4285F4") ?? .blue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "gemini" {
            self = .agy
        } else if let agent = WorkspaceAgent(rawValue: raw) {
            self = agent
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown agent: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Session Models

public nonisolated enum WorkspaceMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
    case system

    public var displayName: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool: return "Tool"
        case .system: return "System"
        }
    }

    public var icon: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .tool: return "wrench.and.screwdriver.fill"
        case .system: return "gearshape.fill"
        }
    }
}

public nonisolated struct WorkspaceSessionMessage: Identifiable, Sendable {
    public let id: String
    public let role: WorkspaceMessageRole
    public let content: String
    public let timestamp: Date?
    public let toolCalls: [String]?

    public init(id: String = UUID().uuidString, role: WorkspaceMessageRole, content: String, timestamp: Date? = nil, toolCalls: [String]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCalls = toolCalls
    }
}

public nonisolated struct WorkspaceSession: Identifiable, Sendable {
    public let id: String
    public let agent: WorkspaceAgent
    public let title: String
    public let summary: String?
    public let projectDirectory: String?
    public let projectName: String
    public let createdAt: Date?
    public let lastActiveAt: Date
    public let filePath: String
    public let fileSizeBytes: Int64
    public let messageCount: Int
    public let resumeCommand: String
    public let parentSessionID: String?
    public let isSubagent: Bool

    public init(
        id: String,
        agent: WorkspaceAgent,
        title: String,
        summary: String? = nil,
        projectDirectory: String? = nil,
        projectName: String,
        createdAt: Date? = nil,
        lastActiveAt: Date,
        filePath: String,
        fileSizeBytes: Int64,
        messageCount: Int,
        resumeCommand: String,
        parentSessionID: String? = nil,
        isSubagent: Bool? = nil
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.summary = summary
        self.projectDirectory = projectDirectory
        self.projectName = projectName
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.messageCount = messageCount
        self.resumeCommand = resumeCommand
        self.parentSessionID = parentSessionID
        self.isSubagent = isSubagent ?? (parentSessionID != nil)
    }
}

// MARK: - Skill Models

public nonisolated struct SkillRepo: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(owner)/\(name)" }
    public let owner: String
    public let name: String
    public let branch: String
    public var isEnabled: Bool

    public init(owner: String, name: String, branch: String = "main", isEnabled: Bool = true) {
        self.owner = owner
        self.name = name
        self.branch = branch
        self.isEnabled = isEnabled
    }
}

public nonisolated struct WorkspaceSkill: Identifiable, Codable, Sendable {
    public var id: String { directory }
    public let name: String
    public let description: String
    public let directory: String
    public let readmeURL: String?
    public let repoOwner: String?
    public let repoName: String?
    public let repoBranch: String?
    /// 仓库内真实目录路径，与本地目录名分开保存，避免嵌套技能安装到错误来源。
    public let repositoryRelativePath: String?
    public let installedAt: Date?
    public var updatedAt: Date?
    public var contentHash: String?
    public var enabledAgents: Set<WorkspaceAgent>

    /// 检查更新时间是否真实有效（排查 0001 年 distantPast 与 1970 年等占位时间戳）
    public var isValidUpdatedAt: Bool {
        guard let updatedAt else { return false }
        return updatedAt.timeIntervalSince1970 > 86400
    }

    public init(
        name: String,
        description: String,
        directory: String,
        readmeURL: String? = nil,
        repoOwner: String? = nil,
        repoName: String? = nil,
        repoBranch: String? = nil,
        installedAt: Date? = nil,
        updatedAt: Date? = nil,
        contentHash: String? = nil,
        enabledAgents: Set<WorkspaceAgent> = [],
        repositoryRelativePath: String? = nil
    ) {
        self.name = name
        self.description = description
        self.directory = directory
        self.readmeURL = readmeURL
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.repoBranch = repoBranch
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.contentHash = contentHash
        self.enabledAgents = enabledAgents
        self.repositoryRelativePath = repositoryRelativePath
    }
}

public nonisolated struct DiscoverableSkill: Identifiable, Sendable {
    public var id: String { "\(repoOwner)/\(repoName)@\(repoBranch):\(repositoryRelativePath ?? directory)" }
    public let name: String
    public let description: String
    public let directory: String
    public let repoOwner: String
    public let repoName: String
    public let repoBranch: String
    public let readmeURL: String?
    /// 空字符串表示仓库根目录；nil 仅用于兼容旧调用，安装时必须先无歧义定位。
    public let repositoryRelativePath: String?

    public init(
        name: String,
        description: String,
        directory: String,
        repoOwner: String,
        repoName: String,
        repoBranch: String = "main",
        readmeURL: String? = nil,
        repositoryRelativePath: String? = nil
    ) {
        self.name = name
        self.description = description
        self.directory = directory
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.repoBranch = repoBranch
        self.readmeURL = readmeURL
        self.repositoryRelativePath = repositoryRelativePath
    }
}

public nonisolated struct UnmanagedSkill: Identifiable, Sendable {
    public var id: String { "\(agent.rawValue):\(directoryPath)" }
    public let name: String
    public let agent: WorkspaceAgent
    public let directoryPath: String

    public init(name: String, agent: WorkspaceAgent, directoryPath: String) {
        self.name = name
        self.agent = agent
        self.directoryPath = directoryPath
    }
}

// MARK: - Storage Models

public nonisolated struct AgentStorageUsage: Identifiable, Sendable {
    public var id: String { agent.rawValue }
    public let agent: WorkspaceAgent
    public let sessionBytes: Int64
    public let sessionCount: Int
    public let cacheBytes: Int64
    public let logBytes: Int64

    public var totalBytes: Int64 {
        sessionBytes + cacheBytes + logBytes
    }

    public init(
        agent: WorkspaceAgent,
        sessionBytes: Int64 = 0,
        sessionCount: Int = 0,
        cacheBytes: Int64 = 0,
        logBytes: Int64 = 0
    ) {
        self.agent = agent
        self.sessionBytes = sessionBytes
        self.sessionCount = sessionCount
        self.cacheBytes = cacheBytes
        self.logBytes = logBytes
    }
}

public nonisolated struct WorkspaceStorageReport: Sendable {
    public let items: [AgentStorageUsage]
    public let quotioAppBytes: Int64
    public let oldSessionsBytes: Int64
    public let oldSessionsCount: Int

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.totalBytes } + quotioAppBytes
    }

    public var totalCacheBytes: Int64 {
        items.reduce(0) { $0 + $1.cacheBytes }
    }

    public init(
        items: [AgentStorageUsage] = [],
        quotioAppBytes: Int64 = 0,
        oldSessionsBytes: Int64 = 0,
        oldSessionsCount: Int = 0
    ) {
        self.items = items
        self.quotioAppBytes = quotioAppBytes
        self.oldSessionsBytes = oldSessionsBytes
        self.oldSessionsCount = oldSessionsCount
    }
}
