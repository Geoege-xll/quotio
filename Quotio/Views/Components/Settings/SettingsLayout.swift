import SwiftUI

/// 设置导航与各级表单共用产品画板色，仅替换页面底色，不覆盖系统控件、
/// 分组容器及导航栏材质。隐藏滚动背景后，Push 前后不会出现另一套灰色页面底。
struct SettingsPageBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(QuotioTheme.Colors.canvasBackground(for: colorScheme).ignoresSafeArea())
    }
}

/// 设置中的枚举选项统一使用系统 Picker，保留原来的选项集合和 Binding。
/// 只负责标签与数据连接，不覆盖系统的圆角、焦点、键盘操作或菜单外观。
struct SettingsChoiceControl<Option: Hashable>: View {
    let titleKey: String
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    init(_ titleKey: String, options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.titleKey = titleKey
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        } label: {
            Text(titleKey.isEmpty ? title(selection) : titleKey.localized())
        }
        .pickerStyle(.menu)
    }
}
