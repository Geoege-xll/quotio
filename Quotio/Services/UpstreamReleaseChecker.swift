import Foundation
import Observation

/// 上游只读发行信息，不使用本地应用版本推断“已同步”：二开版本号与合并源码状态并不等价。
nonisolated struct UpstreamRelease: Decodable, Equatable, Sendable {
    let tag: String
    let name: String?
    let publishedAt: Date?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, publishedAt = "published_at", notes = "body"
    }

    var releaseURL: URL { AppReleaseConfiguration.upstreamReleasesURL.appendingPathComponent("tag").appendingPathComponent(tag) }

    static func decode(_ data: Data, statusCode: Int) throws -> Self? {
        // 仓库尚无稳定发行版是正常空态，不能显示为已经与上游同步。
        if statusCode == 404 { return nil }
        guard statusCode == 200 else { throw CheckError.http(statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(Self.self, from: data)
        guard !release.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckError.invalidResponse }
        return release
    }

    enum CheckError: Error { case http(Int), invalidResponse }
}

/// 只在打开维护页或点击检查时请求，任务由视图生命周期管理；不启动轮询或调用 Sparkle。
/// 加载失败时保留上次成功的结果和时间，重试不闪成空页。
@MainActor @Observable
final class UpstreamReleaseChecker {
    private(set) var release: UpstreamRelease?
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    private(set) var errorKey: String?
    @ObservationIgnored private let load: @Sendable () async throws -> UpstreamRelease?

    init(load: @escaping @Sendable () async throws -> UpstreamRelease? = UpstreamReleaseChecker.fetchLatest) {
        self.load = load
    }

    func checkIfNeeded() async {
        guard lastChecked == nil, errorKey == nil else { return }
        await check()
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        errorKey = nil
        defer { isChecking = false }
        do {
            let result = try await load()
            try Task.checkCancellation()
            release = result
            lastChecked = Date()
        } catch is CancellationError {
            // 离开页面取消时不发布错误，也不覆盖已展示的成功结果。
        } catch let error as URLError where error.code == .cancelled {
        } catch UpstreamRelease.CheckError.http(let status) where status == 403 || status == 429 {
            errorKey = "updates.upstream.rateLimited"
        } catch {
            errorKey = "updates.upstream.failed"
        }
    }

    private nonisolated static func fetchLatest() async throws -> UpstreamRelease? {
        var request = URLRequest(url: AppReleaseConfiguration.upstreamAPIURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Quotio-Maintenance", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpstreamRelease.CheckError.invalidResponse }
        return try UpstreamRelease.decode(data, statusCode: response.statusCode)
    }
}
