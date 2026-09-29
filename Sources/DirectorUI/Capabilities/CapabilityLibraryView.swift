import SwiftUI
import DirectorCore

public struct CapabilityLibraryRow: Identifiable, Equatable, Sendable {
    public let entry: CapabilityCatalogEntry
    public let recent7Count: Int?
    public let recent30Count: Int?
    public let inferredCount: Int
    public let lastUsedAt: Date?
    public let sourceModifiedAt: Date?
    public let coverage: CoverageState
    public let statisticsReady: Bool
    public let attributionUnavailable: Bool
    public var id: String { entry.resource.id }
    /// Compatibility alias used by presentation tests and detail adapters.
    /// A missing value is meaningful for plugin attribution and is never
    /// converted to zero.
    public var reportedRecent7Count: Int? { recent7Count }
    public init(entry: CapabilityCatalogEntry, recent7Count: Int?, inferredCount: Int, lastUsedAt: Date?, sourceModifiedAt: Date?, coverage: CoverageState = .unknown, statisticsReady: Bool = true, attributionUnavailable: Bool = false, recent30Count: Int? = nil) { self.entry = entry; self.recent7Count = recent7Count; self.recent30Count = recent30Count; self.inferredCount = inferredCount; self.lastUsedAt = lastUsedAt; self.sourceModifiedAt = sourceModifiedAt; self.coverage = coverage; self.statisticsReady = statisticsReady; self.attributionUnavailable = attributionUnavailable }
}

public struct CapabilitySummaryMetric: Identifiable, Equatable, Sendable {
    public let kind: CapabilitySummaryMetricKind
    public let label: String
    public let value: Int
    public let statisticsReady: Bool
    public var id: String { kind.rawValue }
    public init(kind: CapabilitySummaryMetricKind, label: String, value: Int, statisticsReady: Bool = true) { self.kind = kind; self.label = label; self.value = value; self.statisticsReady = statisticsReady }
    /// Compatibility initializer for clients using the pre-0.2.3 string ID.
    public init(id: String, label: String, value: Int, statisticsReady: Bool = true) { self.kind = CapabilitySummaryMetricKind(rawValue: id) ?? .global; self.label = label; self.value = value; self.statisticsReady = statisticsReady }
}

public struct CapabilityLibraryGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let rows: [CapabilityLibraryRow]
    internal let renderRows: [CapabilityLibraryRenderRow]
    public init(id: String, title: String, rows: [CapabilityLibraryRow]) {
        self.id = id; self.title = title; self.rows = rows
        renderRows = rows.enumerated().map { index, row in
            let boundary: CapabilityLibraryRowBoundary = rows.count == 1 ? .only : index == 0 ? .first : index == rows.count - 1 ? .last : .middle
            return CapabilityLibraryRenderRow(row: row, boundary: boundary)
        }
    }
}

internal enum CapabilityLibraryRowBoundary: Equatable, Sendable { case first, middle, last, only }
internal struct CapabilityLibraryRenderRow: Identifiable, Equatable, Sendable {
    let row: CapabilityLibraryRow
    let boundary: CapabilityLibraryRowBoundary
    var id: String { row.id }
}

/// Window-local disclosure state. It never changes the filtered group counts
/// or persists capability IDs outside the current browsing session.
internal struct CapabilityLibraryDisclosureState: Equatable {
    private(set) var collapsedGroupIDs: Set<String> = []

    func isCollapsed(_ groupID: String) -> Bool { collapsedGroupIDs.contains(groupID) }

    @discardableResult
    mutating func toggle(_ groupID: String) -> Bool {
        if collapsedGroupIDs.remove(groupID) != nil { return false }
        collapsedGroupIDs.insert(groupID)
        return true
    }

    mutating func revealAll() { collapsedGroupIDs.removeAll() }
}

/// In-memory display strings only. No persistence, source reads or row views.
internal struct CapabilityLibraryRowText: Equatable {
    let summary: String
    let metadata: String
    let countValue: String
    let countLabel: String
    let accessibilityLabel: String
    let inferredLabel: String
}

/// Geometry contract for the library filter ribbon. Search gets a complete
/// row whenever it cannot share a line with the visible selectors. The same
/// measured content width then controls selector wrapping.
public enum DirectorFilterLayout {
    public enum SelectorArrangement: Equatable, Sendable {
        case row
        case twoColumns
        case singleColumn
    }

    public static let searchMinimumWidth: CGFloat = 220
    public static let controlGap: CGFloat = DirectorSpacing.space3
    public static let viewMinimumWidth: CGFloat = 152
    public static let sortMinimumWidth: CGFloat = 132
    public static let pluginStatusMinimumWidth: CGFloat = 128

    public static func controlsMinimumWidth(for category: CapabilityCategory) -> CGFloat {
        let isPlugin = category == .installedPlugins
        let count = isPlugin ? 3 : 2
        let widths = viewMinimumWidth + sortMinimumWidth + (isPlugin ? pluginStatusMinimumWidth : 0)
        return widths + CGFloat(count - 1) * controlGap
    }

    public static func searchAndControlsFit(width: CGFloat, category: CapabilityCategory) -> Bool {
        width >= searchMinimumWidth + controlGap + controlsMinimumWidth(for: category)
    }

    public static func selectorArrangement(width: CGFloat, category: CapabilityCategory) -> SelectorArrangement {
        // This width is the selector column after search has moved above it.
        // Keep the selectors on one line whenever their own minimum widths fit;
        // only then collapse to a two-column or single-column stack.
        guard width < controlsMinimumWidth(for: category) else { return .row }
        return width >= viewMinimumWidth * 2 + controlGap ? .twoColumns : .singleColumn
    }
}

@MainActor public final class CapabilityLibraryViewModel: ObservableObject {
    private struct RowProjectionKey: Equatable {
        let scope: CapabilityBrowseScope
        let context: CapabilityBrowseContext
        let language: AppLanguage
        let dataRevision: Int
    }

    private struct RowProjection {
        let groups: [CapabilityLibraryGroup]
        let rows: [CapabilityLibraryRow]
        let rowsByID: [String: CapabilityLibraryRow]
    }

    private var dataRevision = 0
    private var cachedRowProjection: (key: RowProjectionKey, value: RowProjection)?
    private struct RowTextKey: Equatable {
        let row: CapabilityLibraryRow
        let language: AppLanguage
        let isThirtyDay: Bool
        let ready: Bool
        let timeZone: TimeZone
    }
    private var cachedRowText: [String: (key: RowTextKey, value: CapabilityLibraryRowText)] = [:]
    private var rowLocalizer: DirectorLocalizer?
    #if DEBUG || DIRECTOR_INTERACTION_PERFORMANCE
    internal private(set) var rowProjectionBuildCount = 0
    internal private(set) var rowTextBuildCount = 0
    #endif

    @Published public var context = CapabilityBrowseContext()
    @Published public var selectedID: String?
    @Published public private(set) var catalog: [CapabilityCatalogEntry]
    @Published public private(set) var recentStats: [CapabilityUsageStats]
    @Published public private(set) var browseStats: [CapabilityUsageStats]
    @Published public private(set) var category30DayStats: [CapabilityUsageStats]
    @Published public private(set) var browse30DayStats: [CapabilityUsageStats]
    @Published public private(set) var pluginStats: [PluginUsageResult]
    @Published public private(set) var browsePluginStats: [PluginUsageResult]
    @Published public private(set) var categoryPlugin30DayStats: [PluginUsageResult]
    @Published public private(set) var browsePlugin30DayStats: [PluginUsageResult]
    @Published public var isLoading = false
    @Published public var loadError: String?
    @Published public private(set) var categoryStatsReady = false
    @Published public private(set) var browseStatsReady = false
    @Published public private(set) var category30StatsReady = false
    @Published public private(set) var browse30StatsReady = false
    @Published public private(set) var pluginStatsReady = false
    @Published public private(set) var browsePluginStatsReady = false
    @Published public private(set) var categoryPlugin30StatsReady = false
    @Published public private(set) var browsePlugin30StatsReady = false
    @Published public private(set) var projects: [CapabilityProject] = []
    @Published public private(set) var browseHistory: [CapabilityHistory]
    @Published public private(set) var categoryHistory: [CapabilityHistory]
    @Published public private(set) var pluginAttributionUnavailableCount = 0
    @Published public var language: AppLanguage = .simplifiedChinese
    public private(set) var usageProjects: [String: Set<String>] = [:]
    public let category: CapabilityCategory
    public init(category: CapabilityCategory, catalog: [CapabilityCatalogEntry] = [], recentStats: [CapabilityUsageStats] = [], browseStats: [CapabilityUsageStats] = [], browseHistory: [CapabilityHistory] = [], usageProjects: [String: Set<String>] = [:], pluginStats: [PluginUsageResult] = [], browsePluginStats: [PluginUsageResult] = [], category30DayStats: [CapabilityUsageStats] = [], browse30DayStats: [CapabilityUsageStats] = [], categoryPlugin30DayStats: [PluginUsageResult] = [], browsePlugin30DayStats: [PluginUsageResult] = [], categoryHistory: [CapabilityHistory] = [], pluginAttributionUnavailableCount: Int = 0) { self.category = category; self.catalog = catalog; self.recentStats = recentStats; self.browseStats = browseStats; self.category30DayStats = category30DayStats; self.browse30DayStats = browse30DayStats; self.browseHistory = browseHistory; self.categoryHistory = categoryHistory; self.usageProjects = usageProjects; self.pluginStats = pluginStats; self.browsePluginStats = browsePluginStats; self.categoryPlugin30DayStats = categoryPlugin30DayStats; self.browsePlugin30DayStats = browsePlugin30DayStats; self.pluginAttributionUnavailableCount = pluginAttributionUnavailableCount; self.categoryStatsReady = !recentStats.isEmpty; self.browseStatsReady = !browseStats.isEmpty; self.category30StatsReady = !category30DayStats.isEmpty; self.browse30StatsReady = !browse30DayStats.isEmpty; self.pluginStatsReady = !pluginStats.isEmpty; self.browsePluginStatsReady = !browsePluginStats.isEmpty; self.categoryPlugin30StatsReady = !categoryPlugin30DayStats.isEmpty; self.browsePlugin30StatsReady = !browsePlugin30DayStats.isEmpty }
    /// Updates only the cheap directory projection. A directory read does not
    /// prove that usage statistics were queried, including an empty result.
    public func setDirectory(catalog: [CapabilityCatalogEntry], projects: [CapabilityProject]) {
        invalidateRowProjection()
        self.catalog = catalog
        self.projects = projects
        if let selectedID, !catalog.contains(where: { $0.resource.id == selectedID }) { self.selectedID = nil }
    }
    public func setData(catalog: [CapabilityCatalogEntry], categoryStats: [CapabilityUsageStats], browseStats: [CapabilityUsageStats]? = nil, browseHistory: [CapabilityHistory], usageProjects: [String: Set<String>] = [:], category30DayStats: [CapabilityUsageStats]? = nil, browse30DayStats: [CapabilityUsageStats]? = nil, categoryHistory: [CapabilityHistory] = []) { invalidateRowProjection(); self.catalog = catalog; self.recentStats = categoryStats; self.browseStats = browseStats ?? categoryStats; self.category30DayStats = category30DayStats ?? []; self.browse30DayStats = browse30DayStats ?? []; self.browseHistory = browseHistory; self.categoryHistory = categoryHistory; self.usageProjects = usageProjects; self.categoryStatsReady = true; self.browseStatsReady = true; self.category30StatsReady = category30DayStats != nil; self.browse30StatsReady = browse30DayStats != nil }
    public func setPluginData(_ stats: [PluginUsageResult], browseStats: [PluginUsageResult]? = nil, category30DayStats: [PluginUsageResult]? = nil, browse30DayStats: [PluginUsageResult]? = nil, attributionUnavailableCount: Int? = nil) { invalidateRowProjection(); pluginStats = stats; browsePluginStats = browseStats ?? stats; categoryPlugin30DayStats = category30DayStats ?? []; browsePlugin30DayStats = browse30DayStats ?? []; pluginAttributionUnavailableCount = attributionUnavailableCount ?? stats.filter { $0.callCount == nil }.count; pluginStatsReady = true; browsePluginStatsReady = true; categoryPlugin30StatsReady = category30DayStats != nil; browsePlugin30StatsReady = browse30DayStats != nil }
    public func setProjects(_ value: [CapabilityProject]) { invalidateRowProjection(); projects = value }
    private func invalidateRowProjection() {
        dataRevision &+= 1
        cachedRowProjection = nil
        cachedRowText.removeAll(keepingCapacity: true)
    }
    public var categoryEntries: [CapabilityCatalogEntry] { catalog.filter { $0.category == category } }
    public var categoryCount: Int { categoryEntries.count }
    public var modifiedSortAllowed: Bool { category == .customAgents || category == .customSkills }
    public var usedCount: Int {
        if category == .installedPlugins {
            let ids = Set(pluginStats.compactMap { ($0.callCount ?? 0) > 0 ? $0.pluginID : nil })
            return ids.intersection(Set(categoryEntries.map { $0.resource.id })).count
        }
        let ids = Set(recentStats.filter { $0.callCount > 0 }.map(\.resourceID))
        return ids.intersection(Set(categoryEntries.map { $0.resource.id })).count
    }
    public var notUsed30Count: Int {
        if category == .installedPlugins {
            guard categoryPlugin30StatsReady else { return 0 }
            let byID = Dictionary(uniqueKeysWithValues: categoryPlugin30DayStats.map { ($0.pluginID, $0) })
            return categoryEntries.filter { byID[$0.resource.id]?.callCount == 0 }.count
        }
        guard category30StatsReady else { return 0 }
        let used = Set(category30DayStats.filter { $0.callCount > 0 }.map(\.resourceID))
        return categoryEntries.filter { !used.contains($0.resource.id) }.count
    }
    /// Complete four-card contract used by the capability pages.
    public var summaryCards: [CapabilitySummaryMetric] {
        if category == .installedPlugins {
            return [metric(.installed, categoryEntries.count), metric(.enabled, categoryEntries.filter { $0.resource.status != .blocked }.count), metric(.recent7, usedCount, ready: pluginStatsReady), metric(.notUsed30, notUsed30Count, ready: categoryPlugin30StatsReady)]
        }
        return [metric(.global, categoryEntries.filter { $0.resource.projectID == nil }.count), metric(.project, categoryEntries.filter { $0.resource.projectID != nil }.count), metric(.recent7, usedCount, ready: categoryStatsReady), metric(.notUsed30, notUsed30Count, ready: category30StatsReady)]
    }
    /// Legacy three-card projection retained for source compatibility.
    public var summaryMetrics: [CapabilitySummaryMetric] { Array(summaryCards.prefix(3)) }
    private func metric(_ kind: CapabilitySummaryMetricKind, _ value: Int, ready: Bool = true) -> CapabilitySummaryMetric {
        let label: String
        switch kind { case .global: label = "Global"; case .project: label = "Project"; case .recent7: label = "Used in past 7 days"; case .notUsed30: label = "Not used in past 30 days"; case .installed: label = "Installed"; case .enabled: label = "Enabled"; case .attributionUnavailable: label = "Attribution unavailable" }
        return .init(kind: kind, label: label, value: value, statisticsReady: ready)
    }
    public var rows: [CapabilityLibraryRow] { rows(for: context.scope) }
    public func rows(for scope: CapabilityBrowseScope) -> [CapabilityLibraryRow] { rowProjection(for: scope).rows }
    public func row(withID id: String, in scope: CapabilityBrowseScope) -> CapabilityLibraryRow? {
        rowProjection(for: scope).rowsByID[id]
    }
    /// Stable configuration groups: global first, then localized project name
    /// and stable ID. Search removes empty groups and sort stays group-local.
    public func groupedRows(for scope: CapabilityBrowseScope) -> [CapabilityLibraryGroup] {
        rowProjection(for: scope).groups
    }

    private func rowProjection(for scope: CapabilityBrowseScope) -> RowProjection {
        let key = RowProjectionKey(scope: scope, context: context, language: language, dataRevision: dataRevision)
        if let cachedRowProjection, cachedRowProjection.key == key { return cachedRowProjection.value }
        #if DIRECTOR_INTERACTION_PERFORMANCE
        let projectionStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let grouped = Dictionary(grouping: makeRows(for: scope)) { $0.entry.resource.projectID ?? "__global__" }
        let groups: [CapabilityLibraryGroup] = grouped.compactMap { id, values in
            guard !values.isEmpty else { return nil }
            let title = id == "__global__" ? "Global" : (projects.first(where: { $0.id == id })?.name ?? id)
            return CapabilityLibraryGroup(id: id, title: title, rows: values.sorted(by: sort))
        }.sorted { lhs, rhs in
            if lhs.id == "__global__" { return rhs.id != "__global__" }
            if rhs.id == "__global__" { return false }
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
        let rows = groups.flatMap(\.rows)
        let projection = RowProjection(groups: groups, rows: rows, rowsByID: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }))
        #if DEBUG || DIRECTOR_INTERACTION_PERFORMANCE
        rowProjectionBuildCount += 1
        #endif
        #if DIRECTOR_INTERACTION_PERFORMANCE
        InteractionPerformanceProbe.record(.rowProjectionBuild, since: projectionStart)
        #endif
        cachedRowProjection = (key, projection)
        return projection
    }
    private func makeRows(for scope: CapabilityBrowseScope) -> [CapabilityLibraryRow] {
        let stats = Dictionary(uniqueKeysWithValues: browseStats.map { ($0.resourceID, $0) })
        let thirty = Dictionary(uniqueKeysWithValues: browse30DayStats.map { ($0.resourceID, $0) })
        let history = Dictionary(uniqueKeysWithValues: browseHistory.map { ($0.resourceID, $0) })
        let plugins = Dictionary(uniqueKeysWithValues: browsePluginStats.map { ($0.pluginID, $0) })
        let plugins30 = Dictionary(uniqueKeysWithValues: browsePlugin30DayStats.map { ($0.pluginID, $0) })
        let isPlugin = category == .installedPlugins
        let statsReady = isPlugin ? browsePluginStatsReady : browseStatsReady
        let stats30Ready = isPlugin ? browsePlugin30StatsReady : browse30StatsReady
        return categoryEntries.filter { matchesScope($0, scope: scope) }.filter(search).filter(matchesPluginStatus).compactMap { entry in
            let stat = stats[entry.resource.id]
            let stat30 = thirty[entry.resource.id]
            let plugin = plugins[entry.resource.id]
            let plugin30 = plugins30[entry.resource.id]
            let unavailable = isPlugin && statsReady && (plugin == nil || plugin?.callCount == nil)
            let row = CapabilityLibraryRow(entry: entry, recent7Count: isPlugin ? (statsReady ? plugin?.callCount : nil) : (statsReady ? (stat?.callCount ?? 0) : nil), inferredCount: isPlugin ? (plugin?.inferredCount ?? 0) : (stat?.inferredCount ?? 0), lastUsedAt: isPlugin ? history[entry.resource.id]?.lastUsedAt : (history[entry.resource.id]?.lastUsedAt ?? stat?.lastUsedAt), sourceModifiedAt: entry.resource.sourceModifiedAt, coverage: isPlugin ? (plugin?.coverage ?? .unknown) : (stat?.coverage ?? .unknown), statisticsReady: statsReady, attributionUnavailable: unavailable, recent30Count: isPlugin ? (stats30Ready ? plugin30?.callCount : nil) : (stats30Ready ? (stat30?.callCount ?? 0) : nil))
            return matchesActivity(row) ? row : nil
        }
    }
    private func matchesScope(_ e: CapabilityCatalogEntry, scope: CapabilityBrowseScope) -> Bool { switch scope { case .global: return e.resource.projectID == nil; case .allProjects: return e.resource.projectID != nil; case .allCapabilities: return true; case .project(let id): return usageProjects[e.resource.id]?.contains(id) == true } }
    private func search(_ e: CapabilityCatalogEntry) -> Bool { let q = context.search.trimmingCharacters(in: .whitespacesAndNewlines); guard !q.isEmpty else { return true }; return CapabilityPurposeLocalization.searchTerms(for: e.resource, language: language).contains { $0.localizedCaseInsensitiveContains(q) } }
    private func matchesActivity(_ row: CapabilityLibraryRow) -> Bool { switch context.activityFilter { case .all: return true; case .recent7: return row.recent7Count.map { $0 > 0 } ?? false; case .notUsed30: return !row.attributionUnavailable && row.recent30Count.map { $0 == 0 } ?? false } }
    private func matchesPluginStatus(_ entry: CapabilityCatalogEntry) -> Bool { guard category == .installedPlugins else { return true }; switch context.pluginStatusFilter { case .all: return true; case .enabled: return entry.resource.status != .blocked && entry.resource.status != .warning; case .disabled: return entry.resource.status == .blocked } }
    public func displayedUsageCount(for row: CapabilityLibraryRow) -> Int? {
        context.sort == .thirtyDayUsageDescending ? row.recent30Count : row.recent7Count
    }

    public var displayedUsageReady: Bool {
        if category == .installedPlugins {
            return context.sort == .thirtyDayUsageDescending ? browsePlugin30StatsReady : browsePluginStatsReady
        }
        return context.sort == .thirtyDayUsageDescending ? browse30StatsReady : browseStatsReady
    }

    /// Lazy, bounded to the current directory: warm navigation and selection
    /// reuse display strings; no eager formatting of offscreen capabilities.
    internal func rowText(for row: CapabilityLibraryRow, language: AppLanguage, timeZone: TimeZone = .current) -> CapabilityLibraryRowText {
        let key = RowTextKey(row: row, language: language, isThirtyDay: context.sort == .thirtyDayUsageDescending, ready: displayedUsageReady, timeZone: timeZone)
        if let cached = cachedRowText[row.id], cached.key == key { return cached.value }
        if rowLocalizer?.language != language { rowLocalizer = DirectorLocalizer(language: language) }
        let localizer = rowLocalizer!
        func copy(_ key: String, _ fallback: String, _ args: CVarArg...) -> String { localizer.format(key, fallback: fallback, arguments: args) }
        func date(_ value: Date) -> String {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.timeZone = timeZone
            return localizer.date(value, style: style)
        }
        let resource = row.entry.resource
        let owner = localizer.enumLabel(.init(key: "enum.\(resource.ownership.rawValue)", fallback: resource.ownership.rawValue.capitalized))
        let scope = localizer.enumLabel(.init(key: "enum.\(resource.scope.rawValue)", fallback: resource.scope.rawValue.capitalized))
        let status = category == .installedPlugins ? (resource.status == .warning ? copy("library.pluginUnverified", "Last observed · unverified") : resource.status == .blocked ? copy("library.disabled", "Disabled") : copy("library.enabled", "Enabled")) : localizer.text("status.\(resource.status.rawValue)", fallback: resource.status.rawValue.capitalized)
        let parent = row.entry.parentPluginID.flatMap { id in catalog.first { $0.resource.id == id }?.resource.name }
        let source = resource.ownership == .pluginProvided ? parent.map { copy("library.sourcePlugin", "Plugin %@", $0) } : nil
        let modified = modifiedSortAllowed ? resource.sourceModifiedAt.map { copy("library.modified", "Modified %@", date($0)) } : nil
        let inferred = copy("library.inferred", "Inferred")
        let metadata = [owner, scope, status, source, modified, row.inferredCount > 0 ? inferred : nil, row.lastUsedAt.map(date)].compactMap { $0 }.joined(separator: " · ")
        let usage = displayedUsageCount(for: row)
        let unknown = category == .installedPlugins && displayedUsageReady ? copy("library.unavailable", "Unavailable") : copy("library.pending", "—")
        let count = usage.map { localizer.plural("library.callCount", count: $0, fallback: "%lld calls") } ?? unknown
        let text = CapabilityLibraryRowText(
            summary: CapabilityPurposeLocalization.localizedSummary(for: resource, language: language) ?? copy("library.purposeUnavailable", "Purpose unavailable"),
            metadata: metadata,
            countValue: usage.map { copy("library.number", "%lld", Int64($0)) } ?? unknown,
            countLabel: usage == nil ? copy("library.evidence", "Evidence") : key.isThirtyDay ? copy("library.calls30Label", "calls · 30 days") : copy("library.callsLabel", "calls"),
            accessibilityLabel: "\(resource.name), \(count)", inferredLabel: inferred
        )
        #if DEBUG || DIRECTOR_INTERACTION_PERFORMANCE
        rowTextBuildCount += 1
        #endif
        // Discard departed rows on directory updates; external callers cannot
        // turn arbitrary resources into an unbounded cache.
        if catalog.contains(where: { $0.resource.id == row.id }) { cachedRowText[row.id] = (key, text) }
        return text
    }

    private func sort(_ l: CapabilityLibraryRow, _ r: CapabilityLibraryRow) -> Bool {
        let left = displayedUsageCount(for: l)
        let right = displayedUsageCount(for: r)
        switch context.sort {
        case .usageAscending, .usageDescending, .recentUsageDescending, .thirtyDayUsageDescending:
            if left == nil && right != nil { return false }
            if left != nil && right == nil { return true }
            if let left, let right, left != right {
                return context.sort == .usageAscending ? left < right : left > right
            }
        case .recentUsageAscending:
            if l.lastUsedAt != r.lastUsedAt { return (l.lastUsedAt ?? .distantPast) < (r.lastUsedAt ?? .distantPast) }
        case .modifiedDescending:
            if modifiedSortAllowed, l.sourceModifiedAt != r.sourceModifiedAt { return (l.sourceModifiedAt ?? .distantPast) > (r.sourceModifiedAt ?? .distantPast) }
        case .nameAscending: break
        }
        if context.sort != .nameAscending, context.sort != .recentUsageAscending,
           left == right, l.lastUsedAt != r.lastUsedAt {
            return (l.lastUsedAt ?? .distantPast) > (r.lastUsedAt ?? .distantPast)
        }
        let name = l.entry.resource.name.localizedStandardCompare(r.entry.resource.name)
        return name == .orderedSame ? l.id < r.id : name == .orderedAscending
    }
}

private struct DetailMetadataToken: Equatable {
    let row: CapabilityLibraryRow
    let usageProjectIDs: Set<String>
    let projects: [CapabilityProject]
}

private struct CapabilityGroupRowBorder: Shape {
    typealias Boundary = CapabilityLibraryRowBoundary

    let boundary: Boundary

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(DirectorRadius.contentPanel, min(rect.width, rect.height) / 2)
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        let hasBottom = boundary == .last || boundary == .only

        path.move(to: CGPoint(x: left, y: top))
        if hasBottom {
            path.addLine(to: CGPoint(x: left, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: right - radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius), control: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: right, y: top))
        } else {
            path.addLine(to: CGPoint(x: left, y: bottom))
            path.move(to: CGPoint(x: right, y: top))
            path.addLine(to: CGPoint(x: right, y: bottom))
        }
        return path
    }
}

private struct CapabilityGroupRowBackground: Shape {
    let boundary: CapabilityGroupRowBorder.Boundary

    func path(in rect: CGRect) -> Path {
        guard boundary == .last || boundary == .only else {
            return Rectangle().path(in: rect)
        }
        let radius = min(DirectorRadius.contentPanel, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct CapabilityGroupHeaderBorder: Shape {
    let isCollapsed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(DirectorRadius.contentPanel, min(rect.width, rect.height) / 2)
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY

        path.move(to: CGPoint(x: left, y: isCollapsed ? bottom - radius : bottom))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: top), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + radius), control: CGPoint(x: right, y: top))
        if isCollapsed {
            path.addLine(to: CGPoint(x: right, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: left + radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: left, y: bottom - radius), control: CGPoint(x: left, y: bottom))
        } else {
            path.addLine(to: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: left, y: bottom))
        }
        return path
    }
}

public struct CapabilityLibraryView: View {
    @ObservedObject public var model: CapabilityLibraryViewModel
    public let title: String; public let subtitle: String; public var onScopeChanged: ((CapabilityBrowseScope) -> Void)?
    public var detailContext: ((CapabilityLibraryRow) -> CapabilityDetailViewModel)?
    /// Optional folder organization hooks supplied by the app model. Keeping
    /// these as closures lets the library remain usable by isolated hosts
    /// without constructing a second folder store.
    public var folderDefinitions: [CapabilityFolderDefinition]
    public var folderMembership: ((String, String) -> Bool)?
    public var onToggleFolderMembership: ((String, String, Bool) -> Void)?
    public let presentationState: DirectorPresentationState
    public let pluginInventoryAvailable: Bool?
    public let queryStatus: DirectorLibraryQueryStatus?
    public let resultContext: DirectorLibraryResultContext?
    public let queryTrigger: String?
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var cachedDetail: CapabilityDetailViewModel?
    @State private var cachedDetailKey = ""
    @State private var selectedRowEmphasized = false
    @State private var groupDisclosure = CapabilityLibraryDisclosureState()
    public init(model: CapabilityLibraryViewModel, title: String, subtitle: String, presentationState: DirectorPresentationState = .loaded, pluginInventoryAvailable: Bool? = nil, queryStatus: DirectorLibraryQueryStatus? = nil, resultContext: DirectorLibraryResultContext? = nil, queryTrigger: String? = nil, onScopeChanged: ((CapabilityBrowseScope) -> Void)? = nil, detailContext: ((CapabilityLibraryRow) -> CapabilityDetailViewModel)? = nil, folderDefinitions: [CapabilityFolderDefinition] = [], folderMembership: ((String, String) -> Bool)? = nil, onToggleFolderMembership: ((String, String, Bool) -> Void)? = nil) { self.model = model; self.title = title; self.subtitle = subtitle; self.presentationState = presentationState; self.pluginInventoryAvailable = pluginInventoryAvailable; self.queryStatus = queryStatus; self.resultContext = resultContext; self.queryTrigger = queryTrigger; self.onScopeChanged = onScopeChanged; self.detailContext = detailContext; self.folderDefinitions = folderDefinitions; self.folderMembership = folderMembership; self.onToggleFolderMembership = onToggleFolderMembership }
    public var body: some View {
        DirectorEditorialFrame {
            GeometryReader { proxy in
                ZStack(alignment: .trailing) {
                    list(width: proxy.size.width)

                    if let row = selected {
                        Color.black.opacity(0.24)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedID = nil }
                            .accessibilityHidden(true)

                        DirectorSideSheet(
                            width: sideSheetWidth(for: proxy.size.width),
                            onClose: { model.selectedID = nil },
                            closeLabel: copy("detail.close", "Close detail")
                        ) {
                            detail(row, showsBackButton: false)
                        }
                        .padding(.vertical, DirectorSpacing.space2)
                        .padding(.trailing, proxy.size.width < 760 ? DirectorSpacing.space2 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.selectedID)
            }
        }
        .navigationTitle(title)
        .task(id: queryTaskID) { guard queryTrigger != nil else { return }; onScopeChanged?(model.context.scope) }
        .onAppear {
            if model.language != languageStore.language {
                model.language = languageStore.language
            }
        }
        .onChange(of: languageStore.language) { _, value in model.language = value }
        .onChange(of: model.context.search) { _, _ in groupDisclosure.revealAll() }
        .onExitCommand { model.selectedID = nil }
    }
    private var queryTaskID: String? { queryTrigger.map { "\($0)|\(String(describing: model.context.scope))" } }
    private var effectiveScope: CapabilityBrowseScope { if (queryStatus == .loading || queryStatus == .failed), let resultContext { return resultContext.scope }; return model.context.scope }
    private var displayedRows: [CapabilityLibraryRow] { model.rows(for: effectiveScope) }
    private var hasLastObservedPlugins: Bool {
        model.category == .installedPlugins && model.categoryEntries.contains { $0.resource.sourceRootID == "last-known-runtime" }
    }
    private var pluginInventoryUnverified: Bool {
        model.category == .installedPlugins && (pluginInventoryAvailable == false || hasLastObservedPlugins)
    }
    private var pluginCountUnknown: Bool {
        pluginInventoryUnverified || (model.category == .installedPlugins && pluginInventoryAvailable == nil && model.categoryEntries.isEmpty && presentationState != .preview)
    }
    private var selected: CapabilityLibraryRow? {
        guard let selectedID = model.selectedID else { return nil }
        return model.row(withID: selectedID, in: effectiveScope)
    }
    private func sideSheetWidth(for width: CGFloat) -> CGFloat {
        min(DirectorSpacing.sideSheetMaxWidth, max(DirectorSpacing.sideSheetMinWidth, width * 0.34))
    }
    @ViewBuilder private func list(width: CGFloat) -> some View {
        #if DIRECTOR_INTERACTION_PERFORMANCE
        if ProcessInfo.processInfo.environment["CODEX_DIRECTOR_LIBRARY_RENDERER"] == "appkit" {
            diagnosticAppKitList(width: width)
        } else {
            nativeList(width: width)
        }
        #else
        nativeList(width: width)
        #endif
    }

    private func nativeList(width: CGFloat) -> some View {
        // The List remains full workspace width so its scroll indicator aligns
        // with Home. Row insets carry the 40/16 pt page grid because macOS List
        // rows with custom backgrounds do not honor horizontal contentMargins.
        let contentWidth = DirectorPageLayout.contentWidth(for: width)
        let rowInsets = pageRowInsets(for: width)
        let headerRowInsets = pageHeaderRowInsets(for: width)
        let compactComposition = width < DirectorPageLayout.compactBreakpoint
        return List(selection: $model.selectedID) {
            capabilityHeader(compact: compactComposition)
                .selectionDisabled()
                .listRowBackground(Color.clear)
                .listRowInsets(headerRowInsets)
                .listRowSeparator(.hidden)

            summary(width: contentWidth, compact: compactComposition)
                .selectionDisabled()
                .padding(.bottom, DirectorSpacing.space6)
                .listRowBackground(Color.clear)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)

            if pluginInventoryUnverified {
                Label(copy("library.pluginQueryFailed", "Plugin list unavailable. Previous results, if any, are unverified; refresh data to retry."), systemImage: "exclamationmark.triangle")
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.status(.warning))
                    .selectionDisabled()
                    .padding(.bottom, DirectorSpacing.space3)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
            }

            DirectorFilterRibbon(compact: compactComposition) {
                let ribbonInset = compactComposition ? DirectorSpacing.space2 * 2 : DirectorSpacing.space4 * 2
                filterRibbonContent(width: max(0, contentWidth - ribbonInset))
            }
            .selectionDisabled()
            .padding(.bottom, DirectorSpacing.ribbonGap)
            .listRowBackground(Color.clear)
            .listRowInsets(rowInsets)
            .listRowSeparator(.hidden)

            resultContextNotice
                .selectionDisabled()
                .listRowBackground(Color.clear)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)

            if model.isLoading {
                ProgressView(copy("library.loading", "Loading…"))
                    .selectionDisabled()
                    .controlSize(.small)
                    .padding(.vertical, DirectorSpacing.space3)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
            }
            if model.loadError != nil {
                Text(copy("library.error", "Unable to load capability usage; showing the last available result."))
                    .selectionDisabled()
                    .foregroundStyle(DirectorColor.status(.failure))
                    .padding(.vertical, DirectorSpacing.space3)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
            }
            if displayedRows.isEmpty {
                Text(emptyMessage)
                    .selectionDisabled()
                    .font(DirectorTypography.body)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .padding(.vertical, DirectorSpacing.space4)
                    .listRowBackground(Color.clear)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
            } else {
                let groups = model.groupedRows(for: effectiveScope)
                ForEach(groups) { group in
                    groupHeader(group, rowInsets: rowInsets, hasPrecedingGroup: group.id != groups.first?.id)
                        .selectionDisabled()
                    if !groupDisclosure.isCollapsed(group.id) {
                        ForEach(group.renderRows) { item in
                            libraryRow(item.row, boundary: item.boundary, rowInsets: rowInsets)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .tint(DirectorColor.accent(pageTone))
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowSeparator(.hidden)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .frame(minHeight: 220)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    #if DIRECTOR_INTERACTION_PERFORMANCE
    private func diagnosticAppKitList(width: CGFloat) -> some View {
        let contentWidth = DirectorPageLayout.contentWidth(for: width)
        // The native List path subtracts its own 8pt content inset. This
        // diagnostic plain NSTableView has no such inset.
        let rowInset = DirectorPageLayout.contentMargin(for: width)
        let compact = width < DirectorPageLayout.compactBreakpoint
        var rows: [FullPageLibraryPrototypeRow] = [
            .init(
                id: "diagnostic-header",
                height: compact ? 444 : 336,
                selectable: false,
                view: AnyView(diagnosticAppKitHeader(contentWidth: contentWidth, rowInset: rowInset, compact: compact))
            )
        ]
        if displayedRows.isEmpty {
            rows.append(.init(
                id: "diagnostic-empty",
                height: 72,
                selectable: false,
                view: AnyView(Text(emptyMessage)
                    .font(DirectorTypography.body)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .padding(.horizontal, rowInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            ))
        } else {
            let groups = model.groupedRows(for: effectiveScope)
            for group in groups {
                rows.append(.init(
                    id: "diagnostic-group-\(group.id)",
                    height: compact ? 60 : 56,
                    selectable: false,
                    view: AnyView(groupHeader(group, rowInsets: .init())
                        .padding(.horizontal, rowInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom))
                ))
                if !groupDisclosure.isCollapsed(group.id) {
                    for (index, row) in group.rows.enumerated() {
                        let boundary = groupBoundary(for: index, count: group.rows.count)
                        rows.append(.init(
                            id: row.id,
                            height: compact ? 112 : 96,
                            selectable: true,
                            view: AnyView(libraryRow(row, boundary: boundary, rowInsets: .init())
                                .tint(DirectorColor.accent(pageTone))
                                .padding(.horizontal, rowInset)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
                        ))
                    }
                }
                if group.id != groups.last?.id {
                    rows.append(.init(
                        id: "diagnostic-group-space-\(group.id)",
                        height: DirectorSpacing.space5,
                        selectable: false,
                        view: AnyView(Color.clear)
                    ))
                }
            }
        }
        return FullPageLibraryRendererPrototype(
            rows: rows,
            selectedID: $model.selectedID,
            folderOptions: { resourceID in
                guard let folderMembership else { return [] }
                return folderDefinitions.filter(\.isCustom).map { folder in
                    FullPageLibraryRendererPrototype.FolderOption(
                        id: folder.id,
                        name: folder.displayName(language: model.language == .simplifiedChinese ? .simplifiedChinese : .english),
                        included: folderMembership(resourceID, folder.id)
                    )
                }
            },
            onToggleFolder: onToggleFolderMembership
        )
        .frame(minHeight: 220)
    }

    private func diagnosticAppKitHeader(contentWidth: CGFloat, rowInset: CGFloat, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            capabilityHeader(compact: compact, minimumTitleScale: 1)
                .padding(.bottom, DirectorSpacing.space6)
            summary(width: contentWidth, compact: compact)
                .padding(.bottom, DirectorSpacing.space6)
            DirectorFilterRibbon(compact: compact) {
                let ribbonInset = compact ? DirectorSpacing.space2 * 2 : DirectorSpacing.space4 * 2
                filterRibbonContent(width: max(0, contentWidth - ribbonInset))
            }
            .padding(.bottom, DirectorSpacing.ribbonGap)
            resultContextNotice
            if model.isLoading {
                ProgressView(copy("library.loading", "Loading…"))
                    .controlSize(.small)
                    .padding(.vertical, DirectorSpacing.space3)
            }
            if model.loadError != nil {
                Text(copy("library.error", "Unable to load capability usage; showing the last available result."))
                    .foregroundStyle(DirectorColor.status(.failure))
                    .padding(.vertical, DirectorSpacing.space3)
            }
        }
        // Match the native List's different header-row top insets at its two
        // responsive sizes; the table does not provide those insets itself.
        .padding(.top, DirectorSpacing.space6 + (compact ? DirectorSpacing.space1 : DirectorSpacing.space3))
        .padding(.horizontal, rowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    #endif

    private func pageRowInsets(for width: CGFloat) -> EdgeInsets {
        let margin = DirectorPageLayout.listRowInset(for: width)
        return EdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
    }

    private func pageHeaderRowInsets(for width: CGFloat) -> EdgeInsets {
        let margin = DirectorPageLayout.listRowInset(for: width)
        return EdgeInsets(top: DirectorSpacing.space6, leading: margin, bottom: 0, trailing: margin)
    }

    private func capabilityHeader(compact: Bool, minimumTitleScale: CGFloat = 0.72) -> some View {
        VStack(alignment: .leading, spacing: compact ? DirectorSpacing.space4 : DirectorSpacing.space5) {
            capabilityTitleBlock(compact: compact, minimumTitleScale: minimumTitleScale)
        }
        .padding(.bottom, compact ? DirectorSpacing.space3 : DirectorSpacing.space4)
    }

    private func capabilityTitleBlock(compact: Bool, minimumTitleScale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            HStack(alignment: .center, spacing: DirectorSpacing.space3) {
                Image(systemName: DirectorSymbol.category(model.category))
                    .font(DirectorTypography.pageHeroSymbol)
                    .foregroundStyle(DirectorColor.accent(pageTone))
                    .accessibilityHidden(true)
                capabilityTitleText
                    .font(compact ? DirectorTypography.editorialHeroTitleCompact : DirectorTypography.editorialHeroTitle)
                    .foregroundStyle(DirectorColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(minimumTitleScale)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(subtitle)
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var capabilityTitleText: Text { Text(title) }

    @ViewBuilder
    private func filterRibbonContent(width: CGFloat) -> some View {
        if DirectorFilterLayout.searchAndControlsFit(width: width, category: model.category) {
            HStack(alignment: .bottom, spacing: DirectorFilterLayout.controlGap) {
                filterSearchField
                    .frame(minWidth: DirectorFilterLayout.searchMinimumWidth, maxWidth: .infinity)
                controls(width: width)
            }
        } else {
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                filterSearchField
                    .frame(maxWidth: .infinity)
                controls(width: width)
            }
        }
    }

    private var filterSearchField: some View {
        DirectorSearchField(copy("filter.searchCapabilities", "Search capabilities"),
                            text: Binding(get: { model.context.search }, set: { model.context = model.context.updated(search: $0) }))
    }

    private func menuField<Content: View>(
        value: String,
        accessibilityLabel: String,
        minWidth: CGFloat,
        idealWidth: CGFloat,
        maxWidth: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        DirectorOutlinedMenuField(value, height: DirectorSpacing.controlMinHeight) {
            content()
        }
        .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value)
    }

    private func menuOption(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                if selected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectScope(_ scope: CapabilityBrowseScope) {
        model.context = model.context.updated(scope: scope)
        onScopeChanged?(model.context.scope)
    }

    private func selectSort(_ sort: CapabilitySort) {
        model.context = model.context.updated(sort: sort)
    }

    private func selectPluginStatus(_ status: CapabilityPluginStatusFilter) {
        model.context = model.context.updated(pluginStatusFilter: status)
    }

    private func groupBoundary(for index: Int, count: Int) -> CapabilityGroupRowBorder.Boundary {
        if count == 1 { return .only }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }

    private func groupHeader(_ group: CapabilityLibraryGroup, rowInsets: EdgeInsets, hasPrecedingGroup: Bool = false) -> some View {
        let isCollapsed = groupDisclosure.isCollapsed(group.id)
        let title = groupTitle(group)
        let groupCount = group.rows.count == 1
            ? copy("library.groupCount.singular", "1 capability")
            : copy("library.groupCount", "%lld capabilities", Int64(group.rows.count))
        let actionLabel = isCollapsed
            ? copy("library.group.expand", "Expand %@", title)
            : copy("library.group.collapse", "Collapse %@", title)
        return Button {
            if groupDisclosure.toggle(group.id),
               group.rows.contains(where: { $0.id == model.selectedID }) {
                model.selectedID = nil
            }
        } label: {
            HStack(alignment: .center, spacing: DirectorSpacing.space2) {
                Image(systemName: group.id == "__global__" ? "globe" : "folder.fill")
                    .font(DirectorTypography.supporting.weight(.semibold))
                    .foregroundStyle(DirectorColor.accent(pageTone))
                    .frame(width: 24, height: 24)
                    .background(DirectorColor.accent(pageTone).opacity(0.12), in: RoundedRectangle(cornerRadius: DirectorRadius.compact, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DirectorColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(groupCount)
                    .font(DirectorTypography.label.monospacedDigit())
                    .foregroundStyle(DirectorColor.textSecondary)
                    .fixedSize()
                Spacer(minLength: DirectorSpacing.space3)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(DirectorTypography.label.weight(.semibold))
                    .foregroundStyle(DirectorColor.textSecondary)
                    .frame(width: DirectorSpacing.toolbarControlMinHeight, height: DirectorSpacing.toolbarControlMinHeight)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(actionLabel)
        .accessibilityValue("\(groupCount), \(isCollapsed ? copy("library.group.collapsed", "Collapsed") : copy("library.group.expanded", "Expanded"))")
        .accessibilityAddTraits(.isHeader)
        .help(actionLabel)
        // The group outline reaches the same page grid as the header and
        // ribbon. Text keeps a 16pt internal inset inside that outline.
        .padding(.horizontal, DirectorSpacing.space4)
        .padding(.top, DirectorSpacing.space3)
        .padding(.bottom, DirectorSpacing.space2)
        .background {
            CapabilityGroupHeaderBorder(isCollapsed: isCollapsed).fill(DirectorColor.inset.opacity(0.62))
        }
        .overlay {
            CapabilityGroupHeaderBorder(isCollapsed: isCollapsed)
                .stroke(DirectorColor.boundary, lineWidth: 1)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DirectorColor.accent(pageTone))
                .frame(width: 3)
                .padding(.vertical, DirectorSpacing.space2)
                .accessibilityHidden(true)
        }
        // Own the separation in the next header's content geometry. A List
        // row inset pads its content, while a standalone spacer is subject to
        // macOS's minimum list-row height; neither gives an exact 20pt gap.
        .padding(.top, hasPrecedingGroup ? DirectorSpacing.space5 : 0)
        .listRowBackground(Color.clear)
        .listRowInsets(rowInsets)
    }

    private func libraryRow(_ row: CapabilityLibraryRow, boundary: CapabilityGroupRowBorder.Boundary, rowInsets: EdgeInsets) -> some View {
        #if DIRECTOR_INTERACTION_PERFORMANCE
        InteractionPerformanceProbe.increment(.rowViewBuild)
        #endif
        let text = model.rowText(for: row, language: languageStore.language)
        return HStack(alignment: .top, spacing: DirectorSpacing.space3) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                    if row.entry.resource.kind != .agent {
                        Image(systemName: DirectorSymbol.resource(row.entry.resource.kind))
                            .foregroundStyle(DirectorColor.resource(row.entry.resource.kind))
                            .accessibilityHidden(true)
                    }
                    Text(row.entry.resource.name)
                        .font(DirectorTypography.capabilityRowTitle)
                        .foregroundStyle(DirectorColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.entry.resource.name)
                    if row.inferredCount > 0 {
                        Text(text.inferredLabel)
                            .font(DirectorTypography.label.weight(.semibold))
                            .foregroundStyle(DirectorColor.dataText)
                            .padding(.horizontal, DirectorSpacing.space2)
                            .padding(.vertical, DirectorSpacing.space1)
                            .background(DirectorColor.accent(pageTone).opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(DirectorColor.accent(pageTone).opacity(0.48), lineWidth: 1))
                    }
                }
                Text(text.summary)
                    .font(DirectorTypography.capabilityRowSummary)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text.metadata)
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSupporting)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DirectorSpacing.space3)

            VStack(alignment: .trailing, spacing: DirectorSpacing.space1) {
                Text(text.countValue)
                    .font(DirectorTypography.capabilityRowCount)
                    .foregroundStyle(DirectorColor.textPrimary)
                    .fixedSize()
                Text(text.countLabel)
                    .font(DirectorTypography.capabilityRowCountLabel)
                    .foregroundStyle(DirectorColor.textSupporting)
                    .fixedSize()
            }
            .frame(minWidth: 72, alignment: .trailing)
            folderMembershipMenu(for: row.entry.resource)
            Image(systemName: "arrow.up.right")
                .font(DirectorTypography.label.weight(.semibold))
                .foregroundStyle(DirectorColor.textSupporting)
                .frame(width: 16, alignment: .trailing)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DirectorSpacing.space4)
        .padding(.vertical, DirectorSpacing.space4)
        .frame(minHeight: 96, alignment: .leading)
        // The opaque canvas base keeps the native List selection treatment from
        // bleeding through the row's gutter; the translucent wash adds the
        // page tone without changing the native selection model or AX state.
        .background {
            if row.id == model.selectedID {
                ZStack {
                    CapabilityGroupRowBackground(boundary: boundary)
                        .fill(DirectorColor.canvas)
                    CapabilityGroupRowBackground(boundary: boundary)
                        .fill(DirectorGradient.selectionWash(pageTone))
                }
            } else {
                CapabilityGroupRowBackground(boundary: boundary)
                    .fill(DirectorColor.canvas)
            }
        }
        .clipShape(CapabilityGroupRowBackground(boundary: boundary))
        .tag(row.id)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .overlay {
            CapabilityGroupRowBorder(boundary: boundary)
                .stroke(
                    row.id == model.selectedID && selectedRowEmphasized ? DirectorColor.focus : (row.id == model.selectedID ? DirectorColor.accent(pageTone) : DirectorColor.boundary),
                    lineWidth: row.id == model.selectedID && (selectedRowEmphasized || contrast == .increased) ? 2 : (row.id == model.selectedID ? 1.5 : 1)
                )
                .accessibilityHidden(true)
            if row.id == model.selectedID {
                DirectorListSelectionBridge(isEmphasized: $selectedRowEmphasized)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .leading) {
            if row.id == model.selectedID {
                Rectangle()
                    .fill(DirectorColor.accent(pageTone))
                    .frame(width: 2)
                    .padding(.vertical, DirectorSpacing.space3)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if boundary == .first || boundary == .middle {
                Rectangle()
                    .fill(DirectorColor.boundary)
                    .frame(height: 1)
                    .padding(.horizontal, DirectorSpacing.space4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .listRowInsets(rowInsets)
        .accessibilityLabel(text.accessibilityLabel)
    }
    private func groupTitle(_ group: CapabilityLibraryGroup) -> String {
        group.id == "__global__" ? copy("library.group.global", "Global") : group.title
    }
    @ViewBuilder private var resultContextNotice: some View { if let resultContext, resultContext.scope != model.context.scope || model.isLoading || model.loadError != nil { let label = copy("library.showingPrevious", "Showing %@ · %@–%@", scopeLabel(resultContext.scope), languageStore.localizer.date(resultContext.window.start), languageStore.localizer.date(resultContext.window.end)); Text(label).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary).accessibilityLabel(label) } }
    private var emptyMessage: String {
        switch presentationState {
        case .initial: return copy("library.notIndexed", "Not indexed yet.")
        case .indexing: return copy("library.indexing", "Indexing capabilities…")
        case .failure: return copy("library.error", "Unable to load capability usage.")
        default:
            if model.category == .installedPlugins && pluginInventoryAvailable != true && model.categoryEntries.isEmpty && presentationState != .preview { return copy("library.pluginNotVerified", "Installed plugins have not been verified yet.") }
            if model.categoryEntries.isEmpty { return copy("library.noCapabilities", "No capabilities in this category.") }
            if !model.context.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return copy("library.noSearchResults", "No capabilities match this search.") }
            if isProjectScope { return copy("library.noProjectUsage", "No observed calls in this project history.") }
            return copy("library.noScopeResults", "No capabilities in this configuration.")
        }
    }
    private var isProjectScope: Bool { if case .project = effectiveScope { return true }; return false }
    private func summary(width: CGFloat, compact: Bool = false) -> some View {
        return DirectorMetricSequence(contentWidth: width) {
            ForEach(model.summaryCards) { item in
                let minimumHeight: CGFloat = width < 760 ? DirectorSpacing.capabilityMetricHeightCompact : DirectorSpacing.capabilityMetricHeight
                DirectorMetricCard(symbolName: DirectorSymbol.summaryMetric(item.kind), label: metricLabel(item), value: metricValue(item), selected: selectedMetric(item), tone: metricTone(item.kind), minimumHeight: minimumHeight) { summaryAction(item.kind) }
            }
            if model.category == .installedPlugins && model.pluginAttributionUnavailableCount > 0 {
                Text(copy("library.attributionUnavailableCount", "Attribution unavailable for %lld", Int64(model.pluginAttributionUnavailableCount))).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func metricLabel(_ item: CapabilitySummaryMetric) -> String {
        let key: String
        switch item.kind { case .global: key = "global"; case .project: key = "project"; case .recent7: key = "used"; case .notUsed30: key = "notUsed30"; case .installed: key = "installed"; case .enabled: key = "enabled"; case .attributionUnavailable: key = "attributionUnavailable" }
        return copy("library.summary.\(key)", item.label)
    }
    private func metricValue(_ item: CapabilitySummaryMetric) -> String { if (item.kind == .installed || item.kind == .enabled) && pluginCountUnknown { return copy("library.pending", "—") }; if !item.statisticsReady && (item.kind == .recent7 || item.kind == .notUsed30) { return copy("library.pending", "—") }; return number(item.value) }
    private var usageStatisticsReady: Bool { model.category == .installedPlugins ? model.pluginStatsReady : model.categoryStatsReady }
    private func detail(_ row: CapabilityLibraryRow, showsBackButton: Bool) -> some View {
        let key = detailKey(row)
        return Group {
            if let detail = cachedDetail, cachedDetailKey == key {
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    folderMembershipMenu(for: row.entry.resource)
                    CapabilityDetailView(model: detail, onBack: { model.selectedID = nil }, showsBackButton: showsBackButton)
                }
                    .task(id: detailMetadataKey(row)) {
                        refreshDetailIfNeeded(row: row, detail: detail)
                    }
            } else { ProgressView() }
        }
        .task(id: key) {
            if let detail = cachedDetail, cachedDetailKey == key {
                refreshDetailIfNeeded(row: row, detail: detail)
                return
            }
            guard let detailContext else { return }
            let fresh = detailContext(row)
            cachedDetail = fresh
            cachedDetailKey = key
        }
    }

    @ViewBuilder
    private func folderMembershipMenu(for resource: CapabilityResource) -> some View {
        if (resource.kind == .agent || resource.kind == .skill),
           let folderMembership, let onToggleFolderMembership {
            Menu {
                ForEach(folderDefinitions.filter(\.isCustom)) { folder in
                    let included = folderMembership(resource.id, folder.id)
                    Button {
                        onToggleFolderMembership(resource.id, folder.id, !included)
                    } label: {
                        HStack {
                            Text(folder.displayName(language: languageStore.language == .simplifiedChinese ? .simplifiedChinese : .english))
                            if included { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .accessibilityAddTraits(included ? .isSelected : [])
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(copy("capabilityFolders.addToFolder", "Add to folder"))
            .disabled(folderDefinitions.filter(\.isCustom).isEmpty)
        }
    }
    private func detailKey(_ row: CapabilityLibraryRow) -> String {
        let scope: String
        switch effectiveScope {
        case .global: scope = "global"
        case .allProjects: scope = "all-projects"
        case .allCapabilities: scope = "all-capabilities"
        case .project(let id): scope = "project:\(id)"
        }
        return "\(row.id)|\(scope)"
    }
    private func detailMetadataKey(_ row: CapabilityLibraryRow) -> DetailMetadataToken {
        DetailMetadataToken(row: row, usageProjectIDs: model.usageProjects[row.id, default: []], projects: model.projects)
    }
    private func refreshDetailIfNeeded(row: CapabilityLibraryRow, detail: CapabilityDetailViewModel) {
        guard let detailContext else { return }
        let fresh = detailContext(row)
        let usageChanged = fresh.row.recent7Count != detail.row.recent7Count || fresh.row.recent30Count != detail.row.recent30Count || fresh.row.inferredCount != detail.row.inferredCount || fresh.row.lastUsedAt != detail.row.lastUsedAt || fresh.row.coverage != detail.row.coverage
        guard fresh.row != detail.row || fresh.projects != detail.projects || fresh.sessions != detail.sessions || fresh.usageProjectIDs != detail.usageProjectIDs || fresh.now != detail.now else { return }
        detail.updatePresentation(row: fresh.row, projects: fresh.projects, sessions: fresh.sessions, usageProjectIDs: fresh.usageProjectIDs, now: fresh.now)
        if usageChanged && detail.evidenceRequested { detail.reload() }
    }

    @ViewBuilder
    private func controls(width: CGFloat) -> some View {
        switch DirectorFilterLayout.selectorArrangement(width: width, category: model.category) {
        case .row:
            HStack(alignment: .center, spacing: DirectorSpacing.space3) {
                viewPicker
                sortPicker
                if model.category == .installedPlugins { pluginStatusPicker }
            }
        case .twoColumns:
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: DirectorFilterLayout.viewMinimumWidth), spacing: DirectorSpacing.space3),
                    GridItem(.flexible(minimum: DirectorFilterLayout.viewMinimumWidth), spacing: DirectorSpacing.space3)
                ],
                alignment: .leading,
                spacing: DirectorSpacing.space2
            ) {
                viewPicker
                sortPicker
                if model.category == .installedPlugins { pluginStatusPicker }
            }
        case .singleColumn:
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                viewPicker
                sortPicker
                if model.category == .installedPlugins { pluginStatusPicker }
            }
        }
    }
    private var viewPicker: some View {
        menuField(
            value: scopeLabel,
            accessibilityLabel: copy("library.view", "View"),
            minWidth: 152,
            idealWidth: 176,
            maxWidth: 196
        ) {
            menuOption(copy("library.scope.global", "Global configuration"), selected: model.context.scope == .global) {
                selectScope(.global)
            }
            menuOption(copy("library.scope.projects", "Project configuration"), selected: model.context.scope == .allProjects) {
                selectScope(.allProjects)
            }
            menuOption(copy("library.scope.all", "All capabilities"), selected: model.context.scope == .allCapabilities) {
                selectScope(.allCapabilities)
            }
            ForEach(model.projects) { project in
                let scope = CapabilityBrowseScope.project(project.id)
                menuOption(copy("library.scope.projectUsage", "%@ · Usage", project.name), selected: model.context.scope == scope) {
                    selectScope(scope)
                }
            }
        }
    }

    private var pluginStatusPicker: some View {
        menuField(
            value: pluginStatusLabel,
            accessibilityLabel: copy("library.pluginStatus", "Plugin status"),
            minWidth: 128,
            idealWidth: 148,
            maxWidth: 168
        ) {
            ForEach(CapabilityPluginStatusFilter.allCases, id: \.self) { status in
                menuOption(pluginStatusLabel(status), selected: model.context.pluginStatusFilter == status) {
                    selectPluginStatus(status)
                }
            }
        }
    }

    private func pluginStatusLabel(_ status: CapabilityPluginStatusFilter) -> String {
        switch status {
        case .all: return copy("library.status.all", "All plugins")
        case .enabled: return copy("library.status.enabled", "Enabled")
        case .disabled: return copy("library.status.disabled", "Disabled")
        }
    }
    private var pluginStatusLabel: String { pluginStatusLabel(model.context.pluginStatusFilter) }

    private var sortPicker: some View {
        menuField(
            value: sortLabel,
            accessibilityLabel: copy("library.sort", "Sort"),
            minWidth: 132,
            idealWidth: 152,
            maxWidth: 176
        ) {
            menuOption(copy("library.sort.recentDescending", "Past 7 days ↓"), selected: effectiveSort == .recentUsageDescending) {
                selectSort(.recentUsageDescending)
            }
            menuOption(copy("library.sort.thirtyDescending", "Past 30 days ↓"), selected: effectiveSort == .thirtyDayUsageDescending) {
                selectSort(.thirtyDayUsageDescending)
            }
            menuOption(copy("library.sort.usageAscending", "Usage ↑"), selected: effectiveSort == .usageAscending) {
                selectSort(.usageAscending)
            }
            menuOption(copy("library.sort.name", "Name A–Z"), selected: effectiveSort == .nameAscending) {
                selectSort(.nameAscending)
            }
            if model.modifiedSortAllowed {
                menuOption(copy("library.sort.modified", "Modified ↓"), selected: effectiveSort == .modifiedDescending) {
                    selectSort(.modifiedDescending)
                }
            }
        }
    }

    private var effectiveSort: CapabilitySort {
        model.context.sort == .usageDescending ? .recentUsageDescending : model.context.sort
    }
    private var scopeLabel: String { scopeLabel(model.context.scope) }
    private func scopeLabel(_ scope: CapabilityBrowseScope) -> String { switch scope { case .global: return copy("library.scope.global", "Global configuration"); case .allProjects: return copy("library.scope.projects", "Project configuration"); case .allCapabilities: return copy("library.scope.all", "All capabilities"); case .project(let id): return model.projects.first { $0.id == id }.map { copy("library.scope.projectUsage", "%@ · Usage", $0.name) } ?? id } }
    private var sortLabel: String { switch model.context.sort { case .thirtyDayUsageDescending: return copy("library.sort.thirtyDescending", "Past 30 days ↓"); case .usageAscending: return copy("library.sort.usageAscending", "Usage ↑"); case .nameAscending: return copy("library.sort.name", "Name A–Z"); case .modifiedDescending where model.modifiedSortAllowed: return copy("library.sort.modified", "Modified ↓"); default: return copy("library.sort.recentDescending", "Past 7 days ↓") } }
    private func selectedMetric(_ metric: CapabilitySummaryMetric) -> Bool {
        switch metric.kind {
        case .global: return model.context.scope == .global
        case .project: return model.context.scope == .allProjects
        case .recent7: return model.context.activityFilter == .recent7
        case .notUsed30: return model.context.activityFilter == .notUsed30
        case .installed: return model.context.pluginStatusFilter == .all
        case .enabled: return model.context.pluginStatusFilter == .enabled
        default: return false
        }
    }
    private var pageTone: DirectorAccentTone {
        switch model.category {
        case .customAgents: return .blue
        case .customSkills: return .ice
        case .installedSkills: return .mint
        case .installedPlugins: return .teal
        }
    }
    private func metricTone(_ kind: CapabilitySummaryMetricKind) -> DirectorAccentTone {
        switch kind {
        case .global, .installed: return .blue
        case .project, .enabled: return .ice
        case .recent7: return .mint
        case .notUsed30, .attributionUnavailable: return .teal
        }
    }
    private func summaryAction(_ kind: CapabilitySummaryMetricKind) {
        switch kind {
        case .global: model.context = model.context.updated(scope: model.context.scope == .global ? .allCapabilities : .global)
        case .project: model.context = model.context.updated(scope: model.context.scope == .allProjects ? .allCapabilities : .allProjects)
        case .recent7: model.context = model.context.updated(activityFilter: model.context.activityFilter == .recent7 ? .all : .recent7)
        case .notUsed30: model.context = model.context.updated(activityFilter: model.context.activityFilter == .notUsed30 ? .all : .notUsed30)
        // The page itself is the installed-plugin category.  “Installed” is
        // therefore the all-status projection; clicking it from Enabled (or
        // Disabled) returns to that complete set and clicking it again is a
        // deliberate no-op, matching the card's selected state.
        case .installed: model.context = model.context.updated(pluginStatusFilter: .all)
        case .enabled: model.context = model.context.updated(pluginStatusFilter: model.context.pluginStatusFilter == .enabled ? .all : .enabled)
        default: break
        }
        onScopeChanged?(model.context.scope)
    }
    private func copy(_ key: String, _ fallback: String, _ args: CVarArg...) -> String { languageStore.localizer.format(key, fallback: fallback, arguments: args) }
    private func number(_ value: Int) -> String { copy("library.number", "%lld", Int64(value)) }
}
