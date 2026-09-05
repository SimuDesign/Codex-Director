import SwiftUI
import DirectorCore

/// Data Status: source categories, index progress, coverage, parser version,
/// last refresh, and derived-data controls (rebuild / delete with explicit
/// confirmation that original files are unchanged).
public struct DataStatusView: View {
    public let progress: IndexingProgress
    public let isIndexing: Bool
    public let lastRefresh: Date?
    public let error: String?
    public let parserVersion: String
    public let sourceCategoryCounts: [(name: String, count: Int)]
    public let sessionsWithPartialCoverage: Int
    public let parserCoverageFindingCount: Int
    public let sourceDataFresh: Bool
    public let sourceDataLastCheckedAt: Date?
    public let confirmDelete: Binding<Bool>
    public let rebuildAction: () -> Void
    public let deleteAction: () -> Void
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(
        progress: IndexingProgress,
        isIndexing: Bool,
        lastRefresh: Date?,
        error: String?,
        parserVersion: String,
        sourceCategoryCounts: [(name: String, count: Int)],
        sessionsWithPartialCoverage: Int,
        sourceDataFresh: Bool,
        sourceDataLastCheckedAt: Date?,
        confirmDelete: Binding<Bool>,
        rebuildAction: @escaping () -> Void,
        deleteAction: @escaping () -> Void,
        parserCoverageFindingCount: Int = 0
    ) {
        self.progress = progress
        self.isIndexing = isIndexing
        self.lastRefresh = lastRefresh
        self.error = error
        self.parserVersion = parserVersion
        self.sourceCategoryCounts = sourceCategoryCounts
        self.sessionsWithPartialCoverage = sessionsWithPartialCoverage
        self.parserCoverageFindingCount = parserCoverageFindingCount
        self.sourceDataFresh = sourceDataFresh
        self.sourceDataLastCheckedAt = sourceDataLastCheckedAt
        self.confirmDelete = confirmDelete
        self.rebuildAction = rebuildAction
        self.deleteAction = deleteAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space6) {
                Text(text("Data Status"))
                    .font(DirectorTypography.windowTitle)

                if isIndexing {
                    ProgressView(value: Double(progress.processedFiles), total: Double(max(progress.totalFiles, 1)))
                    Text(languageStore.localizer.format(
                        "%@ · %@",
                        fallback: "%@ · %@",
                        languageStore.localizer.format("%lld of %lld files", fallback: "%lld of %lld files", progress.processedFiles, progress.totalFiles),
                        languageStore.localizer.plural("data.sessionCount", count: progress.indexedSessions, fallback: "%lld sessions")
                    ))
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSecondary)
                }

                if let error {
                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                        Label(text("Indexing error"), systemImage: "exclamationmark.triangle")
                            .font(DirectorTypography.supporting)
                            .foregroundStyle(DirectorColor.status(.failure))
                        Text(error)
                            .font(DirectorTypography.code)
                            .textSelection(.enabled)
                            .accessibilityLabel(languageStore.localizer.format("%@; %@", fallback: "%@; %@", text("Original technical details"), error))
                    }
                }

                section(text("Source categories")) {
                    ForEach(sourceCategoryCounts, id: \.name) { category in
                        HStack {
                            Text(sourceCategoryLabel(category.name))
                            Spacer()
                            Text(languageStore.localizer.format("%lld", fallback: "%lld", category.count))
                                .font(DirectorTypography.data)
                        }
                        .font(DirectorTypography.body)
                    }
                    if sourceCategoryCounts.isEmpty {
                        Text(text("No scan roots configured."))
                            .font(DirectorTypography.supporting)
                            .foregroundStyle(DirectorColor.textSecondary)
                    }
                }

                section(text("Index")) {
                    EvidenceInspector(items: [
                        .init(id: "phase", label: text("Phase"), value: enumLabel(progress.phase, prefix: "indexing.phase.")),
                        .init(id: "source-fresh", label: text("Source data"), value: sourceDataFresh ? text("Fresh") : text("Stale / needs refresh")),
                        .init(id: "source-check", label: text("Source check"), value: sourceDataLastCheckedAt.map { languageStore.localizer.date($0) } ?? "—"),
                        .init(id: "parser", label: text("Parser version"), value: parserVersion),
                        .init(id: "refresh", label: text("Last refresh"), value: lastRefresh.map { languageStore.localizer.date($0) } ?? "—"),
                        .init(id: "partial", label: text("Partial coverage"), value: languageStore.localizer.plural("data.sessionCount", count: sessionsWithPartialCoverage, fallback: "%lld sessions")),
                        .init(id: "parser-coverage", label: text("Parser coverage notices"), value: "\(parserCoverageFindingCount)"),
                    ])
                }

                section(text("Derived data")) {
                    VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                        Text(text("The SQLite index is a disposable projection of your source files. Deleting it never changes original resources or Sessions."))
                            .font(DirectorTypography.supporting)
                            .foregroundStyle(DirectorColor.textSecondary)
                        HStack(spacing: DirectorSpacing.space3) {
                            Button(text("Rebuild index"), action: rebuildAction)
                                .disabled(isIndexing)
                            Button(text("Delete derived data"), role: .destructive, action: { confirmDelete.wrappedValue = true })
                                .disabled(isIndexing)
                        }
                    }
                }
            }
            .padding(DirectorSpacing.space5)
        }
        .alert(text("Delete derived data?"), isPresented: confirmDelete) {
            Button(text("Delete"), role: .destructive, action: deleteAction)
            Button(text("Cancel"), role: .cancel) {}
        } message: {
            Text(text(DirectorAppModel.deleteConfirmationMessage))
        }
        .accessibilityElement(children: .contain)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            Text(title.uppercased())
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            content()
        }
    }

    private func text(_ key: String) -> String {
        languageStore.localizer.text(key, fallback: key)
    }

    private func enumLabel<Value: RawRepresentable>(_ value: Value, prefix: String) -> String where Value.RawValue == String {
        languageStore.localizer.enumLabel(.init(key: prefix + value.rawValue, fallback: value.rawValue.capitalized))
    }

    private func sourceCategoryLabel(_ name: String) -> String {
        let key: String
        switch name {
        case "skills": key = "source.category.skills"
        case "agents": key = "source.category.agents"
        case "plugins": key = "source.category.plugins"
        case "projects": key = "source.category.projects"
        default: return name
        }
        return languageStore.localizer.text(key, fallback: name.capitalized)
    }
}
