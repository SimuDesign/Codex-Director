import SwiftUI
import DirectorCore

/// The table and inspector have explicit readable minima. Below the combined
/// width, show one stage at a time so the selected inspector is never cropped.
public enum CapabilitiesLayoutState: String, Equatable, Sendable {
    case spacious
    case compact

    public static func forContentWidth(_ width: CGFloat) -> Self {
        width >= 840 ? .spacious : .compact
    }
}

/// Capabilities destination: native table with filters and selection-driven
/// inspector. No glass rows, no decorative cards.
public struct CapabilitiesView: View {
    @ObservedObject public var model: CapabilitiesViewModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    public let findings: [ReviewFinding]
    public let onClassify: ((String, ResourceOwnership) -> Void)?
    public let onResetClassification: ((String) -> Void)?
    public let onResetAllClassification: (() -> Void)?

    public init(model: CapabilitiesViewModel, findings: [ReviewFinding] = [], onClassify: ((String, ResourceOwnership) -> Void)? = nil, onResetClassification: ((String) -> Void)? = nil, onResetAllClassification: (() -> Void)? = nil) {
        self.model = model
        self.findings = findings
        self.onClassify = onClassify
        self.onResetClassification = onResetClassification
        self.onResetAllClassification = onResetAllClassification
    }

    public var body: some View {
        GeometryReader { proxy in
            switch CapabilitiesLayoutState.forContentWidth(proxy.size.width) {
            case .spacious:
                HSplitView {
                    table
                        .frame(minWidth: 520, idealWidth: 640)
                    if let selected = model.selectedRow {
                        inspector(for: selected)
                    }
                }
            case .compact:
                if let selected = model.selectedRow {
                    inspector(for: selected)
                } else {
                    table
                        .frame(minWidth: 0, idealWidth: 640)
                }
            }
        }
        .searchable(text: $model.searchText, prompt: languageStore.localizer.text("filter.searchCapabilities", fallback: "Search capabilities"))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(ResourceInventoryCategory.allCases) { category in
                        Button(categoryLabel(category)) {
                            model.applyCategory(category)
                        }
                    }
                } label: {
                    Label(languageStore.localizer.text("filter.category", fallback: "Category filter"), systemImage: "square.grid.2x2")
                }
                .accessibilityLabel(languageStore.localizer.text("filter.category", fallback: "Category filter"))
                .accessibilityValue(categoryLabel(model.categoryFilter))
                Menu {
                    ForEach(model.availableKinds, id: \.rawValue) { kind in
                        Button(kindLabel(kind)) {
                            model.kindFilter = (model.kindFilter == kind) ? nil : kind
                        }
                    }
                } label: {
                    Label(languageStore.localizer.text("filter.kind", fallback: "Kind filter"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(languageStore.localizer.text("filter.kind", fallback: "Kind filter"))
                .accessibilityValue(model.kindFilter.map(kindLabel) ?? languageStore.localizer.text("filter.allKinds", fallback: "All kinds"))
                Menu {
                    ForEach(model.availableScopes, id: \.rawValue) { scope in
                        Button(scopeLabel(scope)) {
                            model.scopeFilter = (model.scopeFilter == scope) ? nil : scope
                        }
                    }
                } label: {
                    Label(languageStore.localizer.text("filter.scope", fallback: "Scope filter"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(languageStore.localizer.text("filter.scope", fallback: "Scope filter"))
                .accessibilityValue(model.scopeFilter.map(scopeLabel) ?? languageStore.localizer.text("filter.allScopes", fallback: "All scopes"))
                Menu {
                    Button(languageStore.localizer.text("filter.allProjects", fallback: "All projects")) { model.projectFilter = nil }
                    ForEach(model.availableProjects) { project in
                        Button(project.name) { model.projectFilter = project.id }
                    }
                } label: {
                    Label(languageStore.localizer.text("filter.project", fallback: "Project filter"), systemImage: "folder")
                }
                .accessibilityLabel(languageStore.localizer.text("filter.project", fallback: "Project filter"))
                .accessibilityValue(selectedProjectTitle)
                Menu {
                    ForEach(CapabilityUsageFilter.allCases) { filter in
                        Button(usageFilterTitle(filter)) {
                            model.usageFilter = filter
                        }
                    }
                } label: {
                    Label(languageStore.localizer.text("filter.usage", fallback: "Usage filter"), systemImage: "chart.bar.xaxis")
                }
                .accessibilityLabel(languageStore.localizer.text("filter.usage", fallback: "Usage filter"))
                .accessibilityValue(usageFilterTitle(model.usageFilter))
                Toggle(languageStore.localizer.text("filter.showBuiltIn", fallback: "Show Built-in"), isOn: $model.showBuiltIn)
                Menu(languageStore.localizer.text("filter.advanced", fallback: "Advanced")) {
                    Toggle(languageStore.localizer.text("filter.showCachedPlugins", fallback: "Show cached / disabled plugins"), isOn: $model.showAdvancedPluginCapabilities)
                    Divider()
                    Button(languageStore.localizer.text("filter.resetClassifications", fallback: "Reset all classification corrections"), role: .destructive) {
                        onResetAllClassification?()
                    }
                }
            }
        }
        .accessibilityLabel(languageStore.localizer.text("nav.capabilities", fallback: "Capabilities"))
        .onAppear {
            model.clearSelectionIfFilteredOut()
        }
        // Observe the derived projection rather than an incomplete list of
        // individual controls. This also covers built-in/plugin visibility
        // toggles and inventory refreshes that can hide a selected row.
        .onChange(of: model.filteredRows) { _, _ in
            model.clearSelectionIfFilteredOut()
        }
    }

    private func inspector(for selected: CapabilityRow) -> some View {
        CapabilityInspector(
            resource: selected.resource,
            relations: model.relations(for: selected.resource.id),
            usage: selected,
            findings: findings.filter { $0.resourceID == selected.resource.id },
            provenance: model.provenance.filter { $0.resourceID == selected.resource.id },
            onDismiss: {
                model.dismissInspector()
            },
            onClassify: { ownership in onClassify?(selected.resource.id, ownership) },
            onResetClassification: { onResetClassification?(selected.resource.id) }
        )
        .frame(minWidth: 280, idealWidth: 340)
    }

    private var table: some View {
        Table(model.filteredRows, selection: $model.selectedResourceID) {
            TableColumn(languageStore.localizer.text("capability.name", fallback: "Name")) { row in
                HStack(spacing: DirectorSpacing.space2) {
                    Image(systemName: DirectorSymbol.resource(row.resource.kind))
                        .foregroundStyle(DirectorColor.resource(row.resource.kind))
                        .accessibilityHidden(true)
                    Text(row.resource.name)
                        .font(DirectorTypography.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.resource.name)
                }
            }
            .width(
                min: DirectorTableMetrics.capabilityNameMinimumWidth,
                ideal: DirectorTableMetrics.capabilityNameIdealWidth,
                max: DirectorTableMetrics.capabilityNameMaximumWidth
            )
            TableColumn(languageStore.localizer.text("capability.kind", fallback: "Kind")) { row in
                Text(kindLabel(row.resource.kind))
                    .font(DirectorTypography.supporting)
            }
            TableColumn(languageStore.localizer.text("capability.scope", fallback: "Scope")) { row in
                Text(scopeLabel(row.resource.scope))
                    .font(DirectorTypography.supporting)
            }
            TableColumn(languageStore.localizer.text("capability.ownership", fallback: "Ownership")) { row in
                Text(ownershipLabel(row.resource.ownership))
                    .font(DirectorTypography.supporting)
            }
            TableColumn(languageStore.localizer.text("capability.origin", fallback: "Origin")) { row in
                Text(originLabel(row.resource.origin))
                    .font(DirectorTypography.supporting)
            }
            TableColumn(languageStore.localizer.text("capability.project", fallback: "Project")) { row in
                Text(projectName(for: row.resource.projectID))
                    .font(DirectorTypography.supporting)
            }
            TableColumn(languageStore.localizer.text("capability.status", fallback: "Status")) { row in
                RuntimeStatusBadge(status: row.resource.status)
            }
            TableColumn(languageStore.localizer.text("capability.calls", fallback: "Calls")) { row in
                Text("\(row.callCount)")
                    .font(DirectorTypography.data)
            }
            TableColumn(languageStore.localizer.text("capability.failures", fallback: "Failures")) { row in
                Text("\(row.failureCount)")
                    .font(DirectorTypography.data)
            }
            TableColumn(languageStore.localizer.text("capability.confidence", fallback: "Confidence")) { row in
                ConfidenceBadge(confidence: row.resource.confidence)
            }
        }
    }

    private func projectName(for id: String?) -> String {
        guard let id else { return "—" }
        return model.projects.first(where: { $0.id == id })?.name ?? id
    }

    private var selectedProjectTitle: String {
        guard let projectID = model.projectFilter else {
            return languageStore.localizer.text("filter.allProjects", fallback: "All projects")
        }
        return model.projects.first(where: { $0.id == projectID })?.name ?? projectID
    }

    private func usageFilterTitle(_ filter: CapabilityUsageFilter) -> String {
        let key: String
        let fallback: String
        switch filter {
        case .all: key = "filter.all"; fallback = "All"
        case .observed: key = "home.observed"; fallback = "Observed"
        case .notObserved: key = "home.notObserved"; fallback = "Not observed"
        case .hasFailures: key = "filter.hasFailures"; fallback = "Has failures"
        case .evidenceLimited: key = "filter.evidenceLimited"; fallback = "Evidence limited"
        case .notEvaluated: key = "filter.notEvaluated"; fallback = "Not evaluated"
        }
        return languageStore.localizer.text(key, fallback: fallback)
    }

    private func categoryLabel(_ category: ResourceInventoryCategory) -> String {
        let keys: [ResourceInventoryCategory: String] = [
            .all: "category.all", .myAgents: "category.myAgents", .mySkills: "category.mySkills",
            .installedSkills: "category.installedSkills", .instructions: "category.instructions",
            .plugins: "category.plugins", .builtIn: "category.builtIn"
        ]
        return languageStore.localizer.text(keys[category] ?? "category.all", fallback: category.rawValue)
    }

    private func kindLabel(_ kind: ResourceKind) -> String {
        languageStore.localizer.enumLabel(LocalizedEnumValue(key: "enum.\(kind.rawValue)", fallback: kind.rawValue.capitalized))
    }

    private func scopeLabel(_ scope: ResourceScope) -> String {
        languageStore.localizer.enumLabel(LocalizedEnumValue(key: "enum.\(scope.rawValue)", fallback: scope.rawValue.capitalized))
    }

    private func ownershipLabel(_ ownership: ResourceOwnership) -> String {
        languageStore.localizer.enumLabel(LocalizedEnumValue(key: "enum.\(ownership.rawValue)", fallback: ownership.rawValue))
    }

    private func originLabel(_ origin: ResourceOrigin) -> String {
        languageStore.localizer.enumLabel(LocalizedEnumValue(key: "enum.\(origin.rawValue)", fallback: origin.rawValue.capitalized))
    }
}
