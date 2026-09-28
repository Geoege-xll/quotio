//
//  ProxyReleasePageParser.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation

/// 仅负责解析 GitHub 官方发行页；下载与版本安装由 CLIProxyManager 控制。
nonisolated enum ProxyReleasePageParser {
    struct ListedRelease: Sendable, Equatable {
        let tag: String
        let prerelease: Bool
    }

    static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 429 || (response.statusCode == 403 && (
            response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil
        ))
    }

    static func listedReleases(in html: String, repository: String) -> [ListedRelease] {
        let pattern = #"<section\b[^>]*\bid="release-([^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var seen = Set<String>()

        return matches.enumerated().compactMap { index, match in
            guard let tagRange = Range(match.range(at: 1), in: html),
                  let start = Range(match.range, in: html)?.lowerBound else { return nil }
            let tag = String(html[tagRange])
            guard ProxyVersionInfo(version: tag, sha256: "").isSupportedMajorVersion,
                  seen.insert(tag).inserted else { return nil }
            let end = index + 1 < matches.count
                ? Range(matches[index + 1].range, in: html)?.lowerBound ?? html.endIndex
                : html.endIndex
            let section = html[start..<end]
            // 只接受本发行条目自己的资产入口；页面其它位置的同名链接不能决定版本状态。
            guard section.contains("/\(repository)/releases/expanded_assets/\(tag)") else { return nil }
            // GitHub 的预发布是发行元数据，与标签是否带后缀无关；标记位于条目标题旁。
            // 只查看标题区域，避免发行说明中的普通文字误判版本状态。
            let header = String(section.prefix(4_096))
            let prerelease = header.range(
                of: #"(?is)<span\b[^>]*\bLabel--warning\b[^>]*>\s*Pre-release\s*</span>"#,
                options: .regularExpression
            ) != nil
            return ListedRelease(tag: tag, prerelease: prerelease)
        }
    }

    static func nextPage(in html: String, repository: String) -> Int? {
        let path = NSRegularExpression.escapedPattern(for: "/\(repository)/releases?page=")
        // 仅信任官方发行列表中标为 next_page 的站内链接，不跟随页面中的任意网址。
        for anchor in captures(#"(<a\b[^>]*>)"#, in: html) {
            guard anchor.range(of: #"\bnext_page\b"#, options: .regularExpression) != nil,
                  let number = captures(#"href=""# + path + #"([0-9]+)""#, in: anchor).first,
                  let page = Int(number) else { continue }
            return page
        }
        return nil
    }

    static func release(tag: String, html: String, repository: String, prerelease: Bool = false) -> GitHubRelease? {
        guard ProxyVersionInfo(version: tag, sha256: "").isSupportedMajorVersion else { return nil }
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let prefix = "/\(repository)/releases/download/\(encodedTag)/"
        let pathPattern = #"href="("# + NSRegularExpression.escapedPattern(for: prefix) + #"[^"<>\s]+)""#
        var assets: [GitHubAsset] = []

        for row in html.components(separatedBy: "</li>") {
            guard let path = captures(pathPattern, in: row).first else { continue }
            let name = String(path.dropFirst(prefix.count))
            guard !name.isEmpty else { continue }
            let digest = captures(#"(sha256:[a-fA-F0-9]{64})(?![a-fA-F0-9])"#, in: row).first
            assets.append(GitHubAsset(
                name: name,
                browserDownloadUrl: "https://github.com" + path,
                digest: digest,
                size: 0,
                contentType: nil
            ))
        }

        guard !assets.isEmpty else { return nil }
        return GitHubRelease(
            tagName: tag, name: nil, body: nil, assets: assets,
            prerelease: prerelease, publishedAt: nil
        )
    }

    @MainActor
    static func collectAvailableVersions(
        from candidates: [ListedRelease],
        limit: Int,
        fetch: (ListedRelease) async throws -> ProxyVersionInfo?
    ) async throws -> [ProxyVersionInfo] {
        guard limit > 0 else { return [] }
        var versions: [ProxyVersionInfo] = []
        var firstFailure: Error?
        for candidate in candidates {
            try Task.checkCancellation()
            guard versions.count < limit else { break }
            do {
                if let version = try await fetch(candidate) { versions.append(version) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单个发行版可能尚未上传资产；继续检查其余候选，不能让列表整体消失。
                if firstFailure == nil { firstFailure = error }
            }
        }
        try Task.checkCancellation()
        if versions.isEmpty { throw firstFailure ?? ProxyUpgradeError.noVersionAvailable }
        return versions
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
