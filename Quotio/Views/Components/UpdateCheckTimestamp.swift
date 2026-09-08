import SwiftUI

/// 检查时间是一个已完成事件，直接格式化为日期和分钟即可。
/// 不使用 relative/timer Text、TimelineView 或定时器，因此停留页面不会为秒数变化反复刷新 UI。
struct UpdateCheckTimestamp: View {
    @Environment(\.locale) private var locale
    let date: Date

    var body: some View {
        Text(verbatim: date.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
            .monospacedDigit()
            .help(date.formatted(.dateTime.year().month().day().hour().minute().second().locale(locale)))
    }
}
