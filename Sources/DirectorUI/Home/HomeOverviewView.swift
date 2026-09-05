import SwiftUI
import DirectorCore

public struct HomeOverviewView: View {
    public let model: HomeOverviewModel
    public let quotaModel: QuotaOverviewModel
    public let onQuotaSourceChange: (String) -> Void
    public let onOpenCategory: (CapabilityCategory) -> Void
    public let onOpenCapability: (CapabilityCategory, String) -> Void
    public let presentationState: DirectorPresentationState
    public let directoryLoaded: Bool
    public let hasComputedStatistics: Bool
    public let hasCachedHomeSummary: Bool
    public let lastUpdatedAt: Date?
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(model: HomeOverviewModel, quotaModel: QuotaOverviewModel, presentationState: DirectorPresentationState = .loaded, directoryLoaded: Bool = true, hasComputedStatistics: Bool = true, hasCachedHomeSummary: Bool = false, lastUpdatedAt: Date? = nil, onQuotaSourceChange: @escaping (String) -> Void = { _ in }, onOpenCategory: @escaping (CapabilityCategory) -> Void = { _ in }, onOpenCapability: @escaping (CapabilityCategory, String) -> Void = { _, _ in }) {
        self.model = model
        self.quotaModel = quotaModel
        self.presentationState = presentationState
        self.directoryLoaded = directoryLoaded
        self.hasComputedStatistics = hasComputedStatistics
        self.hasCachedHomeSummary = hasCachedHomeSummary
        self.lastUpdatedAt = lastUpdatedAt
        self.onQuotaSourceChange = onQuotaSourceChange
        self.onOpenCategory = onOpenCategory
        self.onOpenCapability = onOpenCapability
    }

    public var body: some View {
        GeometryReader { viewport in
            HomeCardAtlasFrame(workspaceWidth: viewport.size.width) {
                let contentWidth = HomeLayout.contentWidth(for: viewport.size.width)
                VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
                    pageHeader(compact: viewport.size.width < DirectorPageLayout.compactBreakpoint)

                    VStack(alignment: .leading, spacing: DirectorSpacing.moduleGap) {
                        HomeOutlineModule(
                            title: copy("home.module.usage", fallback: "Usage"),
                            supportingText: nil,
                            tone: .blue
                        ) {
                            QuotaOverviewView(
                                model: quotaModel,
                                availableWidth: contentWidth,
                                onSourceChange: onQuotaSourceChange
                            )
                        }

                        HomeOutlineModule(
                            title: copy("home.module.capabilitySummary", fallback: "Capability summary"),
                            supportingText: nil,
                            tone: .ice
                        ) {
                            inventoryModule(width: contentWidth)
                        }

                        HomeOutlineModule(
                            title: copy("home.module.usageRanking", fallback: "Usage ranking"),
                            supportingText: nil,
                            tone: .mint
                        ) {
                            rankingModule(width: contentWidth)
                        }
                    }

                }
                // Constrain children to the measured workspace content width.
                // A max-only frame lets a wide chart keep its intrinsic width
                // and prevents the quota module from entering compact mode.
                .frame(width: contentWidth, alignment: .leading)
            }
        }
    }

    /// Returns the localized state key without requiring SwiftUI view rendering.
    /// An initial model with a directory, statistics, or cached Home summary is
    /// usable but has not completed indexing, so it must say “not indexed yet”
    /// rather than implying that its first read is still pending.
    internal static func stateMessageKey(
        for state: DirectorPresentationState,
        directoryLoaded: Bool,
        hasComputedStatistics: Bool,
        hasCachedHomeSummary: Bool
    ) -> String? {
        switch state {
        case .initial:
            return directoryLoaded || hasComputedStatistics || hasCachedHomeSummary
                ? "home.state.notIndexed"
                : "home.state.preparing"
        case .indexing:
            return "home.state.indexing"
        case .failure:
            return "home.state.failure"
        default:
            return nil
        }
    }

    private func pageHeader(compact: Bool) -> some View {
        HomeHeroHeader(
            title: "Welcome to Codex Director",
            titleAccent: DirectorUI.productName,
            latestUpdateText: latestUpdateText,
            statusText: stateMessage,
            compact: compact
        )
    }

    private var latestUpdateText: String {
        guard let lastUpdatedAt else {
            return copy("home.refresh.never", fallback: "Not updated yet")
        }
        return copy(
            "home.refresh.lastUpdated",
            fallback: "Last updated: %@",
            languageStore.localizer.date(lastUpdatedAt)
        )
    }

    private var stateMessage: String? {
        guard let key = Self.stateMessageKey(
            for: presentationState,
            directoryLoaded: directoryLoaded,
            hasComputedStatistics: hasComputedStatistics,
            hasCachedHomeSummary: hasCachedHomeSummary
        ) else { return nil }

        switch key {
        case "home.state.notIndexed": return copy(key, fallback: "Not indexed yet.")
        case "home.state.preparing": return copy(key, fallback: "Preparing indexed data…")
        case "home.state.indexing": return copy(key, fallback: "Indexing capabilities…")
        case "home.state.failure": return copy(key, fallback: "Data update failed; showing the last available data.")
        default: return nil
        }
    }

    private func inventoryModule(width: CGFloat) -> some View {
        HomeMetricStrip(contentWidth: width) {
            inventoryButton(.customAgents)
            inventoryButton(.customSkills)
            inventoryButton(.installedSkills)
            inventoryButton(.installedPlugins)
        }
    }

    private func inventoryButton(_ category: CapabilityCategory) -> some View {
        let value: String
        let subtitle: String
        switch category {
        case .customAgents:
            value = inventoryAvailable ? number(model.inventory.customAgents) : "—"
            subtitle = inventoryAvailable ? copy("home.overview.customCounts", fallback: "Global %lld · Project %lld", Int64(model.inventory.customAgentsGlobal), Int64(model.inventory.customAgentsProject)) : copy("home.state.preparing", fallback: "Preparing indexed data…")
        case .customSkills:
            value = inventoryAvailable ? number(model.inventory.customSkills) : "—"
            subtitle = inventoryAvailable ? copy("home.overview.customCounts", fallback: "Global %lld · Project %lld", Int64(model.inventory.customSkillsGlobal), Int64(model.inventory.customSkillsProject)) : copy("home.state.preparing", fallback: "Preparing indexed data…")
        case .installedSkills:
            value = inventoryAvailable ? number(model.inventory.installedSkills) : "—"
            subtitle = inventoryAvailable ? copy("home.overview.installedSkillCounts", fallback: "Independent %lld · Plugin %lld", Int64(model.inventory.installedSkillsIndependent), Int64(model.inventory.installedSkillsPluginProvided)) : copy("home.state.preparing", fallback: "Preparing indexed data…")
        case .installedPlugins:
            value = inventoryAvailable ? number(model.inventory.installedPlugins) : "—"
            subtitle = inventoryAvailable ? copy("home.overview.pluginCounts", fallback: "%lld enabled", Int64(model.inventory.enabledPlugins)) : copy("home.state.preparing", fallback: "Preparing indexed data…")
        }

        return HomeMetricSegment(
            symbolName: symbol(for: category),
            label: categoryTitle(category),
            value: value,
            supportingText: subtitle,
            tone: inventoryTone(category),
            action: { onOpenCategory(category) }
        )
        .focusEffectDisabled(false)
    }

    private var inventoryAvailable: Bool { directoryLoaded || hasCachedHomeSummary }

    @ViewBuilder
    private func rankingModule(width: CGFloat) -> some View {
        HomeRankingLedger(contentWidth: width) {
            rankingPanel(.customAgents)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            rankingPanel(.customSkills)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            rankingPanel(.installedSkills)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func rankingPanel(_ category: CapabilityCategory) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(categoryTitle(category)).font(DirectorTypography.sectionTitle)
                    Spacer(minLength: DirectorSpacing.space2)
                    Button(copy("home.overview.viewAll", fallback: "View all")) { onOpenCategory(category) }
                        .buttonStyle(.link)
                        .font(DirectorTypography.label)
                }

                let statisticsReady = hasComputedStatistics || hasCachedHomeSummary
                if !statisticsReady {
                    Text(copy("home.state.preparing", fallback: "Preparing indexed statistics…"))
                        .font(DirectorTypography.label)
                        .homeSecondaryText()
                }

                let rows = statisticsReady ? Array(model.rankings[category] ?? []) : []
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button { onOpenCapability(category, row.id) } label: {
                        rankingRow(row, category: category, position: index + 1)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled(false)
                    .help(row.name)
                        .accessibilityLabel(rowAccessibility(row, position: index + 1))
                }

                if statisticsReady && rows.isEmpty {
                    Text(copy("home.overview.noIndexedCalls", fallback: "No calls observed in indexed history"))
                        .font(DirectorTypography.label)
                        .homeSecondaryText()
                }
        }
        .padding(.horizontal, DirectorSpacing.space4)
    }

    private func rankingRow(_ row: HomeOverviewModel.RankingRow, category: CapabilityCategory, position: Int) -> some View {
        let tone = rankingTone(category)
        return HStack(alignment: .top, spacing: DirectorSpacing.space3) {
            Text(String(format: "%02d", position))
                .font(HomeNumericTypography.rankIndex)
                .foregroundStyle(DirectorColor.accent(tone))
                .frame(width: 24, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                    HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                        Text(row.name)
                            .font(DirectorTypography.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                HStack(spacing: DirectorSpacing.space2) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DirectorColor.inset)
                            Capsule().fill(DirectorColor.accent(tone)).frame(width: proxy.size.width * min(1, max(0, row.relativeLength)))
                        }
                    }
                    .frame(height: 4)
                    if row.inferred {
                        Text(copy("evidence.inferred", fallback: "Inferred"))
                            .font(DirectorTypography.label)
                            .homeSecondaryText()
                            .fixedSize()
                    }
                }
            }
            Text(number(row.count))
                .font(HomeNumericTypography.rankCount)
                .frame(width: 52, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, DirectorSpacing.space2)
        .contentShape(Rectangle())
    }

    private func categoryTitle(_ category: CapabilityCategory) -> String {
        switch category {
        case .customAgents: return copy("home.overview.myAgents", fallback: "Custom Agents")
        case .customSkills: return copy("home.overview.mySkills", fallback: "Custom Skills")
        case .installedSkills: return copy("home.overview.installedSkills", fallback: "Installed Skills")
        case .installedPlugins: return copy("home.overview.installedPlugins", fallback: "Installed Plugins")
        }
    }

    private func symbol(for category: CapabilityCategory) -> String {
        DirectorSymbol.category(category)
    }

    private func inventoryTone(_ category: CapabilityCategory) -> DirectorAccentTone {
        switch category {
        case .customAgents: return .blue
        case .customSkills: return .ice
        case .installedSkills: return .mint
        case .installedPlugins: return .teal
        }
    }

    private func rankingTone(_ category: CapabilityCategory) -> DirectorAccentTone {
        switch category {
        case .customAgents: return .blue
        case .customSkills: return .ice
        case .installedSkills: return .mint
        case .installedPlugins: return .teal
        }
    }

    private func copy(_ key: String, fallback: String, _ args: CVarArg...) -> String { languageStore.localizer.format(key, fallback: fallback, arguments: args) }
    private func number(_ value: Int) -> String { copy("home.overview.number", fallback: "%lld", Int64(value)) }
    private func callCount(_ value: Int) -> String { languageStore.localizer.plural("home.overview.callCount", count: value, fallback: "%lld calls") }
    private func rowAccessibility(_ row: HomeOverviewModel.RankingRow, position: Int) -> String {
        let qualifier = row.inferred ? ", " + copy("evidence.inferred", fallback: "Inferred") : ""
        return "\(position), \(row.name), \(callCount(row.count))\(qualifier)"
    }
}
