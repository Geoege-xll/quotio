import XCTest
@testable import Quotio

/// 草稿和选项的回归不启动查询、不读取用户数据，直接验证常驻条件与附加条件的产品契约。
final class CPAUsageFilterDraftTests: XCTestCase {
    private var defaultDraft: CPAUsageFilterDraft {
        .init(selection: CPAUsageSelection(range: .all), dimension: .model, metric: .tokens)
    }

    func testHiddenCountExcludesEveryPersistentControlAndIncludesMetric() {
        var draft = defaultDraft
        XCTAssertEqual(draft.hiddenConditionCount, 0)
        draft.selection.range = .hours24
        draft.selection.provider = "a-custom-provider"
        draft.dimension = .apiKey
        XCTAssertEqual(draft.hiddenConditionCount, 0, "时间、提供商和分组已经常驻，不能计入更多徽章")
        draft.selection.model = "model"
        draft.selection.source = "source-hash"
        draft.selection.apiKey = "key-hash"
        draft.selection.outcome = .failed
        draft.metric = .requests
        XCTAssertEqual(draft.hiddenConditionCount, 5)
        draft.metric = .tokens
        XCTAssertEqual(draft.hiddenConditionCount, 4)
        draft.selection.range = .custom
        XCTAssertEqual(draft.hiddenConditionCount, 5, "自定义时间仅在更多筛选中展示，需要计入隐藏条件")
    }

    func testResetChangesOnlyDraftAndRestoresAllEightConditions() {
        var applied = defaultDraft
        applied.selection.range = .custom
        applied.selection.provider = "provider"
        applied.selection.model = "model"
        applied.selection.source = "source"
        applied.selection.apiKey = "key"
        applied.selection.outcome = .canceled
        applied.dimension = .provider
        applied.metric = .requests
        let original = applied
        var draft = applied
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 172_800)
        draft.reset(now: now, calendar: calendar)

        XCTAssertEqual(applied, original, "重置/放弃草稿不会改动已应用值")
        XCTAssertEqual(draft.selection.range, .all)
        XCTAssertEqual(draft.selection.start, calendar.startOfDay(for: now))
        XCTAssertEqual(draft.selection.end, now)
        XCTAssertEqual([draft.selection.provider, draft.selection.model, draft.selection.source, draft.selection.apiKey], ["", "", "", ""])
        XCTAssertEqual(draft.selection.outcome, .all)
        XCTAssertEqual(draft.dimension, .model)
        XCTAssertEqual(draft.metric, .tokens)
        XCTAssertEqual(draft.hiddenConditionCount, 0)
        applied = draft
        XCTAssertEqual(applied, draft, "应用交付完整快照，而不是逐项查询")
    }

    func testNormalizingReverseDatesDoesNotMutateOriginalSelection() {
        var draft = defaultDraft
        draft.selection.range = .custom
        draft.selection.start = Date(timeIntervalSince1970: 200)
        draft.selection.end = Date(timeIntervalSince1970: 100)
        let normalized = draft.normalized
        XCTAssertEqual(normalized.selection.range, .custom, "弹窗应用的自定义范围必须保留，不能被恢复为全部")
        XCTAssertEqual(normalized.selection.start.timeIntervalSince1970, 100)
        XCTAssertEqual(normalized.selection.end.timeIntervalSince1970, 200)
        XCTAssertEqual(draft.selection.start.timeIntervalSince1970, 200)
        XCTAssertEqual(draft.selection.end.timeIntervalSince1970, 100)
        XCTAssertEqual(normalized.normalized, normalized)
    }

    func testProviderChoicesDeduplicateSpecialRowsAndRetainActualIdentities() {
        let raw = [CPAUsageOption(id: "", title: "incorrect all"), .init(id: "claude", title: "Claude"),
                   .init(id: "claude", title: "duplicate"), .init(id: "__unknown__", title: "incorrect unknown"),
                   .init(id: "Custom", title: "自定义服务"), .init(id: "custom", title: "另一个服务")]
        let choices = CPAUsageFilterChoice.options(raw, selected: "missing", allTitle: "全部", unknownTitle: "未知")
        XCTAssertEqual(choices.map(\.id), ["", "claude", "Custom", "custom", "missing", "__unknown__"])
        XCTAssertEqual(choices.first?.title, "全部")
        XCTAssertEqual(choices.last?.title, "未知")
        XCTAssertEqual(choices.first { $0.id == "missing" }?.title, "missing", "暂时缺失的选择必须继续可见")
        XCTAssertEqual(choices.first { $0.id == "claude" }?.title, "Claude")
        XCTAssertEqual(choices.first?.description, "全部", "VoiceOver 不能使用空的原始 ID")
    }

    func testUnknownSelectionAndEmptyTitlesDoNotCreateDuplicateOrBlankSegments() {
        let choices = CPAUsageFilterChoice.options([.init(id: "private-provider", title: "")],
            selected: "__unknown__", allTitle: "All", unknownTitle: "Unknown")
        XCTAssertEqual(choices.filter { $0.id == "__unknown__" }.count, 1)
        XCTAssertEqual(choices.first { $0.id == "private-provider" }?.title, "private-provider")
        XCTAssertTrue(choices.allSatisfy { !$0.description.isEmpty })
        let empty = CPAUsageFilterChoice.options([], selected: "", allTitle: "All", unknownTitle: "Unknown")
        XCTAssertEqual(empty.map(\.id), ["", "__unknown__"])
    }
}
