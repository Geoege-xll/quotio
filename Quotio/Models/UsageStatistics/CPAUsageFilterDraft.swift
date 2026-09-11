import Foundation

/// “更多筛选”的完整值快照。面板只编辑副本，关闭或重置草稿不会写入页面正在使用的条件。
/// 应用时一次提交这个值，再由仪表盘入口同步更新查询条件、分组和指标。
nonisolated struct CPAUsageFilterDraft: Hashable, Sendable {
    var selection: CPAUsageSelection
    var dimension: CPAUsageDimension
    var metric: CPAUsageChartMetric

    /// 常驻区展示预设时间、分组和提供商；自定义时间仅在完整面板中编辑，因此也计入隐藏条件。
    /// 指标默认 Tokens，切换成请求数也算一个附加条件，避免收起后隐藏实际统计口径。
    var hiddenConditionCount: Int {
        [selection.provider, selection.model, selection.source, selection.apiKey].filter { !$0.isEmpty }.count
            + (selection.outcome == .all ? 0 : 1) + (metric == .tokens ? 0 : 1)
            + (selection.range == .custom ? 1 : 0)
            + (dimension == .model ? 0 : 1)
    }

    mutating func reset(now: Date = Date(), calendar: Calendar = .current) {
        selection = CPAUsageSelection(range: .all, start: calendar.startOfDay(for: now), end: now)
        dimension = .model
        metric = .tokens
    }

    /// 旧状态可能含反向起止；只在草稿/应用边界归一，防止原生 DatePicker 构造无效区间。
    var normalized: Self {
        var value = self
        if selection.start > selection.end {
            value.selection.start = selection.end
            value.selection.end = selection.start
        }
        return value
    }
}

/// 供胶囊与原生选项共用的稳定展示项。description 返回可读标题，兼容项目分段控件的
/// VoiceOver 标签逻辑，避免把“全部”的空 ID 或 range 枚举原始 case 读给用户。
nonisolated struct CPAUsageFilterChoice: Hashable, Identifiable, Sendable, CustomStringConvertible {
    let id: String
    let title: String
    var description: String { title }

    /// 保留数据库给出的提供商/模型真实身份，不依模型名推断品牌，不合并不同大小写的筛选 ID。
    /// 后台选项可能暂时缺失当前选择，补入原值以确保界面不会悄悄显示成“全部”。
    static func options(_ source: [CPAUsageOption], selected: String, allTitle: String, unknownTitle: String) -> [Self] {
        var values = [Self(id: "", title: allTitle)]
        var seen: Set<String> = ["", "__unknown__"]
        for item in source where seen.insert(item.id).inserted {
            values.append(Self(id: item.id, title: item.title.isEmpty ? item.id : item.title))
        }
        if !selected.isEmpty, selected != "__unknown__", seen.insert(selected).inserted {
            values.append(Self(id: selected, title: selected))
        }
        values.append(Self(id: "__unknown__", title: unknownTitle))
        return values
    }
}
