import SwiftUI

/// 模型槽中的启动模型选择器：参考 Magpie 双列选择面板设计。
/// 左侧为垂直服务商导航侧边栏（全部、跟随角色预设、各主流服务商图标），右侧为该服务商提供的模型与别名列表。
/// 顶部提供极简集成搜索过滤框；弹层仅在用户明确选择时提交 Binding，关闭弹层不改写已有配置。
struct AgentDefaultModelPicker: View {
    let agent: CLIAgent
    @Binding var selectedModel: String
    let availableModels: [AvailableModel]
    let isFetchingModels: Bool
    let onRefresh: () -> Void
    var slotModels: [ModelSlot: String] = [:]
    var aliases: [CPAModelAlias] = []
    var showsHeader: Bool = true
    /// 模型槽表格只呈现紧凑选择按钮，说明与名称由同一行的其他列负责，避免重复撑高行。
    var isCompact: Bool = false
    /// 实际模型输入禁止引用角色，防止把 opus 自身写回 Opus 映射产生循环。
    /// 默认模型、菜单和子代理仍允许角色引用，并可以使用各自的无障碍标签。
    var allowsRoleSelection = true
    var selectionLabelKey = "agents.defaultModel"

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var search = ""
    @State private var selectedCategory: PickerCategory = .all

    // MARK: - Picker Category
    enum PickerCategory: Hashable, Identifiable {
        case all
        case roles
        case provider(AIProvider)
        case other

        var id: String {
            switch self {
            case .all: return "all"
            case .roles: return "roles"
            case .provider(let p): return p.rawValue
            case .other: return "other"
            }
        }

        var title: String {
            switch self {
            case .all: return "cpaAliases.allProviders".localized()
            case .roles: return "cpaAliases.followRole".localized()
            case .provider(let p): return p.displayName
            case .other: return "usage.replica.other".localized()
            }
        }
    }

    private var candidatePolicy: AgentModelCandidatePolicy {
        AgentModelCandidatePolicy(agent: agent, models: availableModels, aliases: aliases,
                                  selectedModel: selectedModel, allowsRoleSelection: allowsRoleSelection, slotModels: slotModels)
    }

    private var selectedSlot: ModelSlot? {
        candidatePolicy.selectedRole
    }

    private var selectedAlias: CPAModelAlias? {
        candidatePolicy.confirmedAliases.first { $0.alias == selectedModel }
    }

    private func model(for slot: ModelSlot) -> String {
        // 新增的 Fable 是可选映射：未指定目标时说明由 CLI 解析，不能展示硬编码的官方模型 ID。
        // 这里仅改变选择器的只读说明；提交给 Binding 的值仍是原来的角色标识 fable。
        if slot == .fable, slotModels[slot]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return "agents.claude.fable.nativeDefault".localized()
        }
        return candidatePolicy.resolvedTarget(for: slot)?.selector
            ?? slotModels[slot] ?? AvailableModel.defaultModels[slot]?.name ?? slot.rawValue
    }

    private var requestModel: String {
        if let selectedSlot {
            let target = model(for: selectedSlot)
            // 显式 role[1m] 只覆盖本次选择；说明也应带上它，不能只读角色自身的开关。
            return AgentConfiguration.normalizedClaudeModelID(selectedModel).uses1M
                ? AgentConfiguration.normalizedClaudeModelID(target).base + "[1m]" : target
        }
        if selectedModel.isEmpty {
            return "agents.pi.selectModel".localized()
        }
        return selectedModel
    }

    private var title: String {
        if let selectedSlot {
            return String(format: "agents.defaultModel.followSlot".localized(), selectedSlot.rawValue.capitalized)
                + (AgentConfiguration.normalizedClaudeModelID(selectedModel).uses1M ? " · 1M" : "")
        }
        return selectedModel.isEmpty ? "agents.pi.selectModel".localized() : selectedModel
    }

    // MARK: - Provider Detection Helpers
    private func detectProvider(for modelName: String, provider: String? = nil, displayPlatform: String? = nil) -> AIProvider? {
        // 1. 优先使用 displayPlatform 明确指示的平台归属
        if let platform = displayPlatform?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !platform.isEmpty {
            switch platform {
            case "deepseek": return .deepseek
            case "moonshot", "kimi": return .moonshot
            case "zhipu", "zhipuai", "glm": return .glm
            case "anthropic", "claude": return .claude
            case "google", "gemini", "vertex": return .vertex
            case "openai", "codex": return .codex
            case "qwen", "alibaba", "aliyun": return .qwen
            case "minimax": return .minimax
            case "grok", "xai": return .grok
            case "copilot", "github-copilot": return .copilot
            case "antigravity": return .antigravity
            case "iflow": return .iflow
            case "kiro": return .kiro
            case "openrouter": return .openRouter
            default:
                if let matched = AIProvider(rawValue: platform) { return matched }
            }
        }

        // 2. 其次匹配 provider 字段标识
        if let prov = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !prov.isEmpty {
            switch prov {
            case "deepseek": return .deepseek
            case "moonshot", "kimi": return .moonshot
            case "zhipu", "zhipuai", "glm": return .glm
            case "anthropic", "claude": return .claude
            case "google", "gemini", "vertex": return .vertex
            case "openai", "codex": return .codex
            case "qwen", "alibaba", "aliyun": return .qwen
            case "minimax": return .minimax
            case "grok", "xai": return .grok
            case "copilot", "github-copilot": return .copilot
            case "antigravity": return .antigravity
            case "iflow": return .iflow
            case "kiro": return .kiro
            case "openrouter": return .openRouter
            default:
                if let matched = AIProvider(rawValue: prov) { return matched }
            }
        }

        // 3. 模型名称特征推断
        let lower = modelName.lowercased()
        if lower.contains("deepseek") { return .deepseek }
        if lower.contains("moonshot") || lower.contains("kimi") { return .moonshot }
        if lower.contains("glm") || lower.contains("cogview") || lower.contains("charglm") { return .glm }
        if lower.contains("claude") || lower.contains("anthropic") || lower == "opus" || lower == "sonnet" || lower == "haiku" || lower == "fable" { return .claude }
        if lower.contains("gemini") || lower.contains("gemma") { return .vertex }
        if lower.contains("gpt-") || lower.contains("gpt4") || lower.contains("gpt3") || lower.contains("o1-") || lower.contains("o3-") || lower.contains("o4-") || lower.contains("openai") || lower.contains("codex") { return .codex }
        if lower.contains("qwen") { return .qwen }
        if lower.contains("minimax") || lower.contains("abab") { return .minimax }
        if lower.contains("grok") { return .grok }

        return nil
    }

    private func detectProvider(for alias: CPAModelAlias) -> AIProvider? {
        detectProvider(for: alias.model, provider: alias.provider, displayPlatform: nil)
    }

    private func detectProvider(for model: AvailableModel) -> AIProvider? {
        detectProvider(for: model.name, provider: model.provider, displayPlatform: model.displayPlatform)
    }

    private func detectProvider(forModelName name: String) -> AIProvider? {
        if let match = availableModels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame }) {
            return detectProvider(for: match)
        }
        if let matchAlias = aliases.first(where: { $0.alias.caseInsensitiveCompare(name) == .orderedSame }) {
            return detectProvider(for: matchAlias)
        }
        return detectProvider(for: name, provider: nil, displayPlatform: nil)
    }

    // MARK: - Filtered Models and Categories
    private var availableCategories: [PickerCategory] {
        var list: [PickerCategory] = [.all]
        if agent == .claudeCode && allowsRoleSelection {
            list.append(.roles)
        }

        var found = Set<AIProvider>()
        for alias in candidatePolicy.confirmedAliases {
            if let p = detectProvider(for: alias) {
                found.insert(p)
            }
        }
        for model in availableModels {
            if let p = detectProvider(for: model) {
                found.insert(p)
            }
        }
        for name in matchingModels {
            if let p = detectProvider(forModelName: name) {
                found.insert(p)
            }
        }

        let preferredOrder: [AIProvider] = [
            .deepseek, .moonshot, .glm, .claude, .vertex, .codex, .qwen, .minimax,
            .grok, .openRouter, .copilot, .antigravity, .iflow, .kiro, .clinePass
        ]
        for p in preferredOrder where found.contains(p) {
            list.append(.provider(p))
        }
        for p in found where !preferredOrder.contains(p) {
            list.append(.provider(p))
        }

        let hasOther = matchingModels.contains { detectProvider(forModelName: $0) == nil }
            || matchingAliases.contains { detectProvider(for: $0) == nil }
        if hasOther {
            list.append(.other)
        }

        return list
    }

    private var matchingRoleSlots: [ModelSlot] {
        guard agent == .claudeCode && allowsRoleSelection else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return ModelSlot.allCases }
        return ModelSlot.allCases.filter { slot in
            slot.rawValue.localizedCaseInsensitiveContains(query) ||
            model(for: slot).localizedCaseInsensitiveContains(query) ||
            String(format: "agents.defaultModel.followSlot".localized(), slot.rawValue.capitalized).localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingAliases: [CPAModelAlias] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidatePolicy.confirmedAliases.filter {
            query.isEmpty ||
            $0.alias.localizedCaseInsensitiveContains(query) ||
            $0.model.localizedCaseInsensitiveContains(query) ||
            $0.provider.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingModels: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidatePolicy.modelIDs
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func aliases(for provider: AIProvider) -> [CPAModelAlias] {
        matchingAliases.filter { detectProvider(for: $0) == provider }
    }

    private func models(for provider: AIProvider) -> [String] {
        matchingModels.filter { detectProvider(forModelName: $0) == provider }
    }

    private var unclassifiedAliases: [CPAModelAlias] {
        matchingAliases.filter { detectProvider(for: $0) == nil }
    }

    private var unclassifiedModels: [String] {
        matchingModels.filter { detectProvider(forModelName: $0) == nil }
    }

    private var displayProviders: [AIProvider] {
        var found = Set<AIProvider>()
        for alias in matchingAliases {
            if let p = detectProvider(for: alias) {
                found.insert(p)
            }
        }
        for model in matchingModels {
            if let p = detectProvider(forModelName: model) {
                found.insert(p)
            }
        }

        let preferredOrder: [AIProvider] = [
            .deepseek, .moonshot, .glm, .claude, .vertex, .codex, .qwen, .minimax,
            .grok, .openRouter, .copilot, .antigravity, .iflow, .kiro, .clinePass
        ]
        var result: [AIProvider] = []
        for p in preferredOrder where found.contains(p) {
            result.append(p)
        }
        for p in found where !preferredOrder.contains(p) {
            result.append(p)
        }
        return result
    }

    private var isContentEmpty: Bool {
        switch selectedCategory {
        case .all:
            return matchingRoleSlots.isEmpty && displayProviders.isEmpty && unclassifiedAliases.isEmpty && unclassifiedModels.isEmpty
        case .roles:
            return matchingRoleSlots.isEmpty
        case .provider(let p):
            return aliases(for: p).isEmpty && models(for: p).isEmpty
        case .other:
            return unclassifiedAliases.isEmpty && unclassifiedModels.isEmpty
        }
    }

    private var canAddCustomModel: Bool {
        // 包括 role[1m] 在内的分类与候选、别名及保存计划一致，避免手填绕过实际槽的禁止角色约束。
        candidatePolicy.canAddCustomModel(search)
    }

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack {
                    Label(selectionLabelKey.localized(), systemImage: "play.circle")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(action: onRefresh) {
                        if isFetchingModels {
                            SmallProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.quotioMicroCapsule)
                    .disabled(isFetchingModels)
                    .help("agents.models.refresh".localized())
                    .accessibilityLabel("agents.models.refresh".localized())
                }
            }

            Button {
                search = ""
                selectedCategory = .all
                isPresented = true
            } label: {
                HStack(spacing: isCompact ? 6 : 10) {
                    if !isCompact { pickerLeadingIcon }

                    Text(verbatim: title)
                        .font(isCompact ? .system(size: 12, design: .monospaced) : .system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(selectedModel.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !isCompact, let alias = selectedAlias {
                        Text("cpaAliases.title".localized())
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)

                        Text("→ " + alias.model)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, isCompact ? 10 : 14)
                .frame(maxWidth: .infinity, minHeight: isCompact ? 34 : 36, alignment: .leading)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isPresented ? Color.accentColor.opacity(0.6) : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                        lineWidth: isPresented ? 1.5 : 0.5
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectionLabelKey.localized())
            .accessibilityValue(title)
            .accessibilityIdentifier("agentDefaultModelPicker")
            .help(requestModel)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { modelPopover }

            if candidatePolicy.hasUnconfirmedSelection, !isFetchingModels {
                // 警告附在当前值旁，不能只藏在弹层中；刷新失败、空目录和旧型号均不自动改写选择。
                Label("agents.models.unconfirmed".localized(), systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isCompact, selectedSlot != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("cpaAliases.actualModel".localized())
                    Text(verbatim: requestModel).fontDesign(.monospaced).textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if !isCompact, selectedAlias == nil && selectedSlot == nil {
                CPAModelAliasSummary(model: requestModel, aliases: candidatePolicy.confirmedAliases)
            }

            if showsHeader {
                Text((agent == .pi ? "agents.pi.modelInfo" : (agent == .claudeCode ? "agents.defaultModel.claudeInfo" : "agents.defaultModel.codexInfo")).localized())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pickerLeadingIcon: some View {
        if selectedSlot != nil {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(agent.color)
        } else if let alias = selectedAlias {
            if let p = detectProvider(for: alias) {
                ProviderIcon(provider: p, size: 16)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            if let p = detectProvider(forModelName: selectedModel) {
                ProviderIcon(provider: p, size: 16)
            } else {
                Image(systemName: "cpu")
                    .foregroundStyle(agent.color)
            }
        }
    }

    // MARK: - Magpie Style Two-Column Popover
    private var modelPopover: some View {
        VStack(spacing: 0) {
            popoverSearchBar

            Divider()

            HStack(spacing: 0) {
                providerSidebar
                    .frame(width: 48)

                Rectangle()
                    .fill(QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(0.6))
                    .frame(width: 1)

                modelContentList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 380)
        }
        .frame(width: 540)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
    }

    // MARK: - Search Bar
    private var popoverSearchBar: some View {
        HStack(spacing: 8) {
            QuotioCapsuleTextField(
                "cpaAliases.search".localized(),
                text: $search,
                systemImage: "magnifyingglass",
                showsClearButton: true,
                autofocus: true
            )

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("action.close".localized())
            .accessibilityLabel("action.close".localized())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Provider Navigation Sidebar
    private var providerSidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(availableCategories) { category in
                    categoryButton(category)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .background(QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.35))
    }

    private func categoryButton(_ category: PickerCategory) -> some View {
        let isSelected = selectedCategory == category
        let tintColor = categoryTintColor(category)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            ZStack {
                CategoryButtonBackground(isSelected: isSelected, tintColor: tintColor)
                categoryIcon(category, size: 20)
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(category.title)
        .accessibilityLabel(category.title)
    }

    @ViewBuilder
    private func categoryIcon(_ category: PickerCategory, size: CGFloat) -> some View {
        switch category {
        case .all:
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: size * 0.75))
                .foregroundStyle(selectedCategory == .all ? Color.accentColor : .secondary)
        case .roles:
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: size * 0.75, weight: .semibold))
                .foregroundStyle(agent.color)
        case .provider(let provider):
            ProviderIcon(provider: provider, size: size)
        case .other:
            Image(systemName: "cpu")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
        }
    }

    private func categoryTintColor(_ category: PickerCategory) -> Color {
        switch category {
        case .all: return Color.accentColor
        case .roles: return agent.color
        case .provider(let p): return p.color
        case .other: return Color.secondary
        }
    }

    // MARK: - Model Content List
    private var modelContentList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 3) {
                if candidatePolicy.hasUnconfirmedSelection, selectedSlot == nil,
                   search.isEmpty || selectedModel.localizedCaseInsensitiveContains(search) {
                    // 当前旧值独立呈现，只允许保留原选择，不把它混入服务商分组中的实时候选。
                    sectionHeader("agents.models.currentConfiguration".localized(), count: 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: selectedModel).font(.callout.monospaced()).textSelection(.enabled)
                        Text("agents.models.unconfirmed".localized()).font(.caption).foregroundStyle(.orange)
                    }
                    .padding(10)
                }
                if canAddCustomModel {
                    customModelOptionRow(search.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                switch selectedCategory {
                case .all:
                    allCategoryContent
                case .roles:
                    rolesCategoryContent
                case .provider(let provider):
                    providerCategoryContent(provider)
                case .other:
                    otherCategoryContent
                }

                if isContentEmpty && !canAddCustomModel {
                    emptyStateView
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var allCategoryContent: some View {
        if !matchingRoleSlots.isEmpty {
            sectionHeader("cpaAliases.followRole".localized(), count: matchingRoleSlots.count)
            ForEach(matchingRoleSlots) { slot in
                roleOptionRow(slot)
            }
        }

        ForEach(displayProviders) { provider in
            let pAliases = aliases(for: provider)
            let pModels = models(for: provider)
            if !pAliases.isEmpty || !pModels.isEmpty {
                sectionHeader(provider.displayName, count: pAliases.count + pModels.count)
                ForEach(pAliases) { alias in
                    aliasOptionRow(alias, provider: provider)
                }
                ForEach(pModels, id: \.self) { model in
                    modelOptionRow(model, provider: provider)
                }
            }
        }

        if !unclassifiedAliases.isEmpty || !unclassifiedModels.isEmpty {
            sectionHeader("usage.replica.other".localized(), count: unclassifiedAliases.count + unclassifiedModels.count)
            ForEach(unclassifiedAliases) { alias in
                aliasOptionRow(alias, provider: nil)
            }
            ForEach(unclassifiedModels, id: \.self) { model in
                modelOptionRow(model, provider: nil)
            }
        }
    }

    @ViewBuilder
    private var rolesCategoryContent: some View {
        if !matchingRoleSlots.isEmpty {
            sectionHeader("cpaAliases.followRole".localized(), count: matchingRoleSlots.count)
            ForEach(matchingRoleSlots) { slot in
                roleOptionRow(slot)
            }
        }
    }

    @ViewBuilder
    private func providerCategoryContent(_ provider: AIProvider) -> some View {
        let pAliases = aliases(for: provider)
        let pModels = models(for: provider)
        if !pAliases.isEmpty || !pModels.isEmpty {
            sectionHeader(provider.displayName, count: pAliases.count + pModels.count)
            ForEach(pAliases) { alias in
                aliasOptionRow(alias, provider: provider)
            }
            ForEach(pModels, id: \.self) { model in
                modelOptionRow(model, provider: provider)
            }
        }
    }

    @ViewBuilder
    private var otherCategoryContent: some View {
        if !unclassifiedAliases.isEmpty || !unclassifiedModels.isEmpty {
            sectionHeader("usage.replica.other".localized(), count: unclassifiedAliases.count + unclassifiedModels.count)
            ForEach(unclassifiedAliases) { alias in
                aliasOptionRow(alias, provider: nil)
            }
            ForEach(unclassifiedModels, id: \.self) { model in
                modelOptionRow(model, provider: nil)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            if let count {
                Text("(\(count))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Row Views
    private func roleOptionRow(_ slot: ModelSlot) -> some View {
        let isSelected = selectedSlot == slot
        let targetModel = model(for: slot)
        let declares1M = AgentConfiguration.is1MSupported(by: targetModel)
        return Button {
            selectedModel = slot.rawValue
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(agent.color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(String(format: "agents.defaultModel.followSlot".localized(), slot.rawValue.capitalized))
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if declares1M {
                            oneMillionDeclarationBadge
                        }
                    }

                    Text("→ " + targetModel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if candidatePolicy.isUnconfirmedTarget(for: slot) {
                        Text("agents.models.unconfirmed".localized())
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(agent.color)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                ModelPickerRowBackground(isSelected: isSelected, tintColor: agent.color)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func aliasOptionRow(_ entry: CPAModelAlias, provider: AIProvider?) -> some View {
        let isSelected = entry.alias == selectedModel
        // 点击提交的是公开 alias，元数据 target 不参与本次 CLI 上下文声明。
        // 不能因为目标说明有 [1m] 就给不带后缀的别名标记已开启；非 Claude 客户端也不解释此声明。
        let declares1M = agent == .claudeCode && AgentConfiguration.is1MSupported(by: entry.alias)
        let accentColor = provider?.color ?? Color.accentColor
        return Button {
            selectedModel = entry.alias
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                if let provider {
                    ProviderIcon(provider: provider, size: 18)
                        .frame(width: 20)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: entry.alias)
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("cpaAliases.title".localized())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)

                        if declares1M {
                            oneMillionDeclarationBadge
                        }

                        if let effort = entry.effort, !effort.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "brain").font(.system(size: 8))
                                Text(verbatim: effort).font(.system(size: 9, weight: .medium))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                    }

                    HStack(spacing: 4) {
                        Text("→ " + entry.model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("· " + (provider?.displayName ?? entry.provider))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                ModelPickerRowBackground(isSelected: isSelected, tintColor: accentColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelOptionRow(_ name: String, provider: AIProvider?) -> some View {
        let isSelected = name == selectedModel
        let declares1M = agent == .claudeCode && AgentConfiguration.is1MSupported(by: name)
        let accentColor = provider?.color ?? agent.color
        return Button {
            selectedModel = name
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                if let provider {
                    ProviderIcon(provider: provider, size: 18)
                        .frame(width: 20)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 14))
                        .foregroundStyle(agent.color)
                        .frame(width: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: name)
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if declares1M {
                            oneMillionDeclarationBadge
                        }
                    }

                    if let provider {
                        Text(verbatim: provider.displayName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                ModelPickerRowBackground(isSelected: isSelected, tintColor: accentColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func customModelOptionRow(_ name: String) -> some View {
        Button {
            selectedModel = name
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: name)
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        if agent == .claudeCode && AgentConfiguration.is1MSupported(by: name) {
                            oneMillionDeclarationBadge
                        }
                    }

                    // 保留明确的手动输入功能，同时说明它尚未经过当前目录确认。
                    Text("cpaAliases.customModel".localized() + " · " + "agents.models.unconfirmed".localized())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text((availableModels.isEmpty && search.isEmpty) ? "availableModels.empty".localized() : "cpaAliases.noMatches".localized())
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(20)
    }

    private var oneMillionDeclarationBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill").font(.system(size: 7))
            Text("1M").font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(QuotioTheme.Colors.claudeOrange.opacity(0.15), in: Capsule())
        .foregroundStyle(QuotioTheme.Colors.claudeOrange)
        // 此标记只说明选项携带显式 [1m]，目录公开 ID 不等于已经验证后端容量。
        .help("agents.modelMapping.oneMillion.declared".localized())
        .accessibilityLabel("1M " + "agents.modelMapping.oneMillion.declared".localized())
    }
}

// MARK: - Row Background Supporting Hover
private struct ModelPickerRowBackground: View {
    let isSelected: Bool
    let tintColor: Color
    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
            .fill(isSelected ? tintColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            .onHover { isHovered = $0 }
    }
}

// MARK: - Category Button Background Supporting Hover
private struct CategoryButtonBackground: View {
    let isSelected: Bool
    let tintColor: Color
    @State private var isHovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? tintColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))

            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tintColor.opacity(0.4), lineWidth: 1)
            }
        }
        .onHover { isHovered = $0 }
    }
}
