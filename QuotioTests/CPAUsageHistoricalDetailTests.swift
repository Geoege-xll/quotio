import XCTest
@testable import Quotio

/// 只构造旧日汇总和真实请求，验证两类数据保持身份边界，以及价格估算的可知范围。
final class CPAUsageHistoricalDetailTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var day: Date { ISO8601DateFormatter().date(from: "2026-09-07T00:00:00Z")! }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ id: String, model: String = "m", provider: String = "p", input: Int = 100,
                        output: Int = 20, cached: Int = 0, total: Int? = nil) -> UsageRecord {
        UsageRecord(timestamp: day.addingTimeInterval(3600), provider: provider, model: model, requestID: id,
                    tokens: .init(input: input, output: output, cached: cached, total: total))
    }

    private func historicalLedger(_ records: [UsageRecord]) throws -> UsageLedger {
        let url = try directory().appendingPathComponent("ledger.json")
        var buckets: [String: UsageBucket] = [:]
        for record in records {
            let empty = UsageBucket(day: calendar.startOfDay(for: record.timestamp), provider: record.provider, model: record.model)
            var bucket = buckets[empty.id] ?? empty
            bucket.add(record); buckets[bucket.id] = bucket
        }
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = Array(buckets.values)
        snapshot.recentRecordIDs = records.compactMap(\.deduplicationID)
        snapshot.firstCollectedAt = day; snapshot.lastCollectedAt = day.addingTimeInterval(12 * 3600)
        try JSONEncoder().encode(snapshot).write(to: url)
        return UsageLedger(url: url, calendar: calendar)
    }

    func testHistoricalRowsAndOptionsDoNotBecomeEventMetricsOrPages() async throws {
        let ledger = try historicalLedger([record("old-a"), record("old-b", model: "other", provider: "other")])
        let result = try await ledger.queryEvents(CPAUsageQuery(page: 5, pageSize: 1))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertFalse(result.hasStoredEvents)
        XCTAssertEqual(result.metrics.requests, 0); XCTAssertEqual(result.metrics.tokens, 0)
        XCTAssertEqual(result.page, 1); XCTAssertEqual(result.totalPages, 1)
        XCTAssertEqual(result.historicalRequests, 2); XCTAssertEqual(result.allHistoricalRequests, 2)
        XCTAssertEqual(result.historicalBuckets.count, 2)
        XCTAssertEqual(result.historicalBuckets.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertEqual(Set(result.providers.map(\.id)), Set(["p", "other"]))
        XCTAssertEqual(Set(result.models.map(\.id)), Set(["m", "other"]))
    }

    func testRequestPagesContainTwentyRowsWhileMetricsCoverAllMatches() async throws {
        let ledger = try historicalLedger([])
        _ = try await ledger.ingest((0..<45).map { record("event-\($0)") }, collectedAt: day.addingTimeInterval(7200))
        var seen: Set<String> = []
        // 真实请求直接由数据库 LIMIT/OFFSET 分页，每一页的摘要都必须覆盖全部 45 次请求。
        for (page, count) in [(1, 20), (2, 20), (3, 5)] {
            let result = try await ledger.queryEvents(CPAUsageQuery(page: page, pageSize: CPAUsageTablePage.size))
            XCTAssertEqual(result.events.count, count)
            XCTAssertEqual(result.metrics.requests, 45)
            XCTAssertEqual(result.metrics.tokens, 45 * 120)
            XCTAssertEqual(result.totalPages, 3)
            seen.formUnion(result.events.map(\.id))
        }
        XCTAssertEqual(seen.count, 45)
    }

    func testHistoricalAndPricePaginationPreserveCompleteTotals() async throws {
        let ledger = try historicalLedger((0..<45).map { record("history-\($0)", model: "model-\($0)") })
        for index in 0..<45 {
            try await ledger.savePrice(CPAModelPrice(model: "model-\(index)", input: 1, output: 1))
        }
        let history = try await ledger.queryEvents(CPAUsageQuery())
        let pricing = try await ledger.queryPricing(CPAUsageQuery())
        // 这两类结果已经按模型／日期聚合；只切展示行，完整历史总量与费用仍取原查询结果。
        for (page, count) in [(1, 20), (2, 20), (3, 5)] {
            let range = CPAUsageTablePage(totalCount: 45, number: page)
            XCTAssertEqual(range.rows(from: history.historicalBuckets).count, count)
            XCTAssertEqual(range.rows(from: pricing.rows).count, count)
        }
        XCTAssertEqual(history.historicalRequests, 45)
        XCTAssertEqual(pricing.summary.metrics.requests, 45)
        XCTAssertEqual(pricing.summary.metrics.tokens, 45 * 120)
        XCTAssertEqual(pricing.pricedRequests, 45)
        XCTAssertEqual(try XCTUnwrap(pricing.estimatedCost), 45 * 0.00012, accuracy: 0.000000001)
    }

    func testHistoryCoverageDistinguishesUnsupportedFiltersFromNoMatch() async throws {
        let ledger = try historicalLedger([record("old-a"), record("old-b")])
        for query in [CPAUsageQuery(source: "known-source"), CPAUsageQuery(apiKey: "known-key"),
                      CPAUsageQuery(outcome: .failed),
                      CPAUsageQuery(start: day.addingTimeInterval(3600), end: day.addingTimeInterval(7200))] {
            let result = try await ledger.queryEvents(query)
            XCTAssertEqual(result.historicalRequests, 0)
            XCTAssertEqual(result.omittedHistoricalRequests, 2)
            XCTAssertEqual(result.allHistoricalRequests, 2)
        }
        let unrelated = try await ledger.queryEvents(CPAUsageQuery(model: "not-present"))
        XCTAssertEqual(unrelated.historicalRequests, 0)
        XCTAssertEqual(unrelated.omittedHistoricalRequests, 0)
        XCTAssertEqual(unrelated.allHistoricalRequests, 2)
        // 已知历史缺少来源标识，可以在“未知来源”下显示真实日汇总。
        let unknown = try await ledger.queryEvents(CPAUsageQuery(source: "__unknown__"))
        XCTAssertEqual(unknown.historicalRequests, 2)
    }

    func testStoredEventsAreDetectedEvenWhenCurrentFilterHasNoMatch() async throws {
        let ledger = try historicalLedger([record("history")])
        _ = try await ledger.ingest([record("new", model: "new-model")], collectedAt: day.addingTimeInterval(7200))
        let result = try await ledger.queryEvents(CPAUsageQuery(model: "not-present"))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.hasStoredEvents, "空页不能被误标为从未保存过任何请求明细")
        XCTAssertEqual(result.metrics.requests, 0)
        XCTAssertEqual(result.allHistoricalRequests, 1)
        let all = try await ledger.queryEvents(CPAUsageQuery())
        XCTAssertEqual(all.events.count, 1)
        XCTAssertEqual(all.metrics.requests, 1)
        XCTAssertEqual(all.historicalRequests, 1)
    }

    func testUnpricedHistoricalModelRemainsVisibleAndPriceEditRecalculatesIt() async throws {
        let ledger = try historicalLedger([record("old-a"), record("old-b")])
        let unknown = try await ledger.queryPricing(CPAUsageQuery())
        XCTAssertEqual(unknown.rows.count, 1)
        XCTAssertEqual(unknown.rows.first?.model, "m")
        XCTAssertNil(unknown.rows.first?.price); XCTAssertNil(unknown.estimatedCost)
        XCTAssertEqual(unknown.summary.metrics.requests, 2)
        XCTAssertEqual(unknown.summary.historicalRequests, 2)
        XCTAssertEqual(unknown.rows.first?.historicalRequests, 2)
        XCTAssertTrue(unknown.hasPartialEstimate)

        try await ledger.savePrice(CPAModelPrice(model: "m", input: 2, output: 4))
        let priced = try await ledger.queryPricing(CPAUsageQuery())
        XCTAssertEqual(priced.pricedRequests, 2)
        XCTAssertFalse(priced.hasPartialEstimate)
        XCTAssertEqual(try XCTUnwrap(priced.estimatedCost), 0.00056, accuracy: 0.000000001)
        XCTAssertEqual(priced.summary.metrics.tokens, 240)

        try await ledger.savePrice(CPAModelPrice(model: "m", input: 0, output: 0))
        let zero = try await ledger.queryPricing(CPAUsageQuery())
        XCTAssertEqual(zero.estimatedCost, 0)
        XCTAssertEqual(zero.pricedRequests, 2)
        XCTAssertFalse(zero.hasPartialEstimate)
    }

    func testCachedHistoryAddsOnlyKnownCostAndDoesNotClaimCompleteRequestCoverage() async throws {
        let ledger = try historicalLedger([record("history", cached: 80)])
        _ = try await ledger.ingest([record("event")], collectedAt: day.addingTimeInterval(7200))
        // 即使缓存两类单价都存在，历史也没有读写拆分，不能擅自选一种应用。
        try await ledger.savePrice(CPAModelPrice(model: "m", input: 2, output: 4, cacheRead: 1, cacheWrite: 3))
        let result = try await ledger.queryPricing(CPAUsageQuery())
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows.first?.requests, 2)
        XCTAssertEqual(result.rows.first?.historicalRequests, 1)
        XCTAssertEqual(result.pricedRequests, 1)
        XCTAssertTrue(result.rows.first?.hasPartialEstimate == true)
        XCTAssertTrue(result.hasPartialEstimate)
        // 历史普通输入 20*2 + 输出 20*4，加真实事件 100*2 + 20*4，缓存费用未计入。
        XCTAssertEqual(try XCTUnwrap(result.estimatedCost), 0.0004, accuracy: 0.000000001)
        XCTAssertEqual(result.summary.metrics.requests, 2)
        XCTAssertEqual(result.summary.historicalRequests, 1)
    }

    func testKnownPartialZeroIsDistinctFromUnknownCostAndMissingComponents() async throws {
        let cachedLedger = try historicalLedger([record("cache-only", input: 100, output: 0, cached: 100)])
        try await cachedLedger.savePrice(CPAModelPrice(model: "m", input: 1, output: 1))
        let partial = try await cachedLedger.queryPricing(CPAUsageQuery())
        XCTAssertEqual(partial.estimatedCost, 0, "已知普通输入和输出恰好为零，仍应保留金额下界")
        XCTAssertEqual(partial.pricedRequests, 0)
        XCTAssertTrue(partial.hasPartialEstimate)

        let incompleteLedger = try historicalLedger([record("total-only", input: 0, output: 0, total: 100)])
        try await incompleteLedger.savePrice(CPAModelPrice(model: "m", input: 1, output: 1))
        let unknown = try await incompleteLedger.queryPricing(CPAUsageQuery())
        XCTAssertNil(unknown.estimatedCost, "仅总量已知而无计价分量时不能显示免费")
        XCTAssertEqual(unknown.pricedRequests, 0)
        XCTAssertTrue(unknown.hasPartialEstimate)
    }

    func testZeroTokenHistoryCanBeCompletelyEstimatedAndInconsistentTotalsCannot() async throws {
        let ledger = try historicalLedger([record("zero", model: "zero", input: 0, output: 0),
                                           record("inconsistent", model: "other", total: 150)])
        try await ledger.savePrice(CPAModelPrice(model: "zero", input: 1, output: 1))
        try await ledger.savePrice(CPAModelPrice(model: "other", input: 1, output: 1))
        let zero = try await ledger.queryPricing(CPAUsageQuery(model: "zero"))
        XCTAssertEqual(zero.estimatedCost, 0); XCTAssertEqual(zero.pricedRequests, 1)
        XCTAssertFalse(zero.hasPartialEstimate)
        let inconsistent = try await ledger.queryPricing(CPAUsageQuery(model: "other"))
        XCTAssertEqual(inconsistent.pricedRequests, 0)
        XCTAssertTrue(inconsistent.hasPartialEstimate)
        XCTAssertEqual(try XCTUnwrap(inconsistent.estimatedCost), 0.00012, accuracy: 0.000000001)
    }

    func testPricingMergesCaseInsensitiveModelsAcrossHistoryEventsAndProviders() async throws {
        let ledger = try historicalLedger([record("upper", model: "MODEL-A", provider: "one"),
                                           record("lower", model: "model-a", provider: "two")])
        _ = try await ledger.ingest([record("new", model: "Model-A", provider: "three")], collectedAt: day.addingTimeInterval(7200))
        try await ledger.savePrice(CPAModelPrice(model: "model-a", input: 1, output: 1))
        let all = try await ledger.queryPricing(CPAUsageQuery())
        XCTAssertEqual(all.rows.count, 1)
        XCTAssertEqual(all.rows.first?.requests, 3)
        XCTAssertEqual(all.rows.first?.historicalRequests, 2)
        XCTAssertEqual(all.summary.metrics.tokens, 360)
        XCTAssertEqual(all.pricedRequests, 3)
        XCTAssertFalse(all.hasPartialEstimate)
        XCTAssertEqual(try XCTUnwrap(all.estimatedCost), 0.00036, accuracy: 0.000000001)
        let selected = try await ledger.queryPricing(CPAUsageQuery(provider: "two", model: "MoDeL-a"))
        XCTAssertEqual(selected.rows.count, 1)
        XCTAssertEqual(selected.rows.first?.requests, 1)
        XCTAssertEqual(selected.rows.first?.historicalRequests, 1)
        XCTAssertEqual(selected.pricedRequests, 1)
    }

    func testNonASCIIModelsKeepSeparatePricesBeforeAndAfterHistoricalMerge() async throws {
        // 先验证纯事件路径：即使没有历史桶，合并层也不能把 SQL 的两行重建成一行。
        // 再加入历史验证相同身份规则贯穿目录、筛选与费用，ASCII 字母仍忽略大小写。
        for includesHistory in [false, true] {
            let history = includesHistory ? [record("old-upper", model: "Élite"), record("old-lower", model: "élite")] : []
            let ledger = try historicalLedger(history)
            _ = try await ledger.ingest([record("new-upper", model: "Élite"), record("new-lower", model: "élite")],
                                        collectedAt: day.addingTimeInterval(7200))
            try await ledger.savePrice(CPAModelPrice(model: "Élite", input: 1, output: 1))
            try await ledger.savePrice(CPAModelPrice(model: "élite", input: 2, output: 2))
            let result = try await ledger.queryPricing(CPAUsageQuery())
            let requests = includesHistory ? 2 : 1
            XCTAssertEqual(result.rows.count, 2)
            XCTAssertEqual(result.summary.metrics.requests, 2 * requests)
            XCTAssertEqual(result.summary.metrics.tokens, 240 * requests)
            XCTAssertEqual(Set(result.summary.models.map(\.id)), Set(["Élite", "élite"]))
            for (model, unitPrice) in [("Élite", 1.0), ("élite", 2.0)] {
                let row = try XCTUnwrap(result.rows.first { $0.model == model })
                XCTAssertEqual(row.requests, requests)
                XCTAssertEqual(row.tokens, 120 * requests)
                XCTAssertEqual(row.historicalRequests, includesHistory ? 1 : 0)
                XCTAssertEqual(row.price?.input, unitPrice)
                XCTAssertEqual(row.pricedRequests, requests)
                XCTAssertFalse(row.hasPartialEstimate)
                XCTAssertEqual(try XCTUnwrap(row.estimatedCost), Double(requests) * 0.00012 * unitPrice, accuracy: 0.000000001)
            }
            XCTAssertEqual(try XCTUnwrap(result.estimatedCost), Double(requests) * 0.00036, accuracy: 0.000000001)
            let selected = try await ledger.queryPricing(CPAUsageQuery(model: "ÉLITE"))
            XCTAssertEqual(selected.rows.count, 1)
            XCTAssertEqual(selected.rows.first?.model, "Élite")
            XCTAssertEqual(selected.summary.metrics.requests, requests)
            XCTAssertEqual(selected.summary.historicalRequests, includesHistory ? 1 : 0)
            let catalogue = try await ledger.filterOptions()
            XCTAssertEqual(Set(catalogue.models.map(\.id)), Set(["Élite", "élite"]))
        }
    }

    func testContradictoryHistoricalTokenComponentsCannotProduceCostLowerBound() async throws {
        // 分量总和大于总量、缓存大于输入分别破坏计价依据；不能夹到零后继续显示 ≥ 金额。
        for invalid in [record("components-exceed-total", input: 100, output: 20, total: 100),
                        record("cache-exceeds-input", input: 100, output: 20, cached: 101, total: 120)] {
            let ledger = try historicalLedger([invalid])
            try await ledger.savePrice(CPAModelPrice(model: "m", input: 1, output: 1, cacheRead: 1, cacheWrite: 1))
            let result = try await ledger.queryPricing(CPAUsageQuery())
            let row = try XCTUnwrap(result.rows.first)
            XCTAssertEqual(row.requests, 1)
            XCTAssertEqual(row.historicalRequests, 1)
            XCTAssertNil(row.estimatedCost)
            XCTAssertNil(result.estimatedCost)
            XCTAssertEqual(row.pricedRequests, 0)
            XCTAssertEqual(result.pricedRequests, 0)
            XCTAssertTrue(row.hasPartialEstimate)
            XCTAssertTrue(result.hasPartialEstimate)
        }
    }

    func testPricingReportsOmittedHistoryForUnsupportedSourceFilter() async throws {
        let ledger = try historicalLedger([record("old")])
        let result = try await ledger.queryPricing(CPAUsageQuery(source: "known-source"))
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.summary.metrics.requests, 0)
        XCTAssertEqual(result.summary.historicalRequests, 0)
        XCTAssertEqual(result.omittedHistoricalRequests, 1)
        XCTAssertEqual(result.summary.omittedHistoricalRequests, 1)
        XCTAssertTrue(result.hasPartialEstimate)
        XCTAssertNil(result.estimatedCost)
        XCTAssertEqual(result.summary.models.map(\.id), ["m"], "历史模型选项只受时间范围影响")
    }
    func testFullFilterCatalogueIncludesHistoryOutsideCurrentWindowWithoutLoadingMetrics() async throws {
        let ledger = try historicalLedger([record("history", model: "old-model", provider: "old-provider")])
        let now = day.addingTimeInterval(2 * 86400)
        var context = CPAUsageContext()
        context.sourceID = "new-source"; context.apiKeyID = "new-key"; context.apiKeyLabel = "Test Key"
        let recent = UsageRecord(timestamp: now.addingTimeInterval(-3600), provider: "new-provider", model: "new-model",
                                 requestID: "recent-event", tokens: .init(input: 10, output: 5), context: context)
        _ = try await ledger.ingest([recent], collectedAt: now)
        let page = try await ledger.queryEvents(CPAUsageQuery(start: now.addingTimeInterval(-4 * 3600), end: now))
        XCTAssertEqual(page.models.map(\.id), ["new-model"], "页面仍只提供当前 4 小时的选项")
        XCTAssertEqual(page.historicalRequests, 0)
        let catalogue = try await ledger.filterOptions()
        XCTAssertEqual(Set(catalogue.models.map(\.id)), Set(["old-model", "new-model"]))
        XCTAssertEqual(Set(catalogue.providers.map(\.id)), Set(["old-provider", "new-provider"]))
        XCTAssertEqual(catalogue.sources.map(\.id), ["new-source"])
        XCTAssertEqual(catalogue.apiKeys.map(\.id), ["new-key"])
        let unchanged = try await ledger.queryEvents(CPAUsageQuery(start: now.addingTimeInterval(-4 * 3600), end: now))
        XCTAssertEqual(unchanged.models.map(\.id), ["new-model"], "全目录查询不能改写已应用页面的时间范围")
        XCTAssertEqual(unchanged.metrics.requests, 1)
    }

}
