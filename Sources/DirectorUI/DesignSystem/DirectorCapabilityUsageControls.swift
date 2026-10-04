import SwiftUI
import DirectorCore

/// One vocabulary and native control implementation for all capability browsers.
enum DirectorUsageSortOption: String, CaseIterable, Identifiable {
    case usageDescending, usageAscending, nameAscending, modifiedDescending
    var id: String { rawValue }
    var capabilitySort: CapabilitySort {
        switch self {
        case .usageDescending: .usageDescending
        case .usageAscending: .usageAscending
        case .nameAscending: .nameAscending
        case .modifiedDescending: .modifiedDescending
        }
    }
    init(_ sort: CapabilitySort) {
        switch sort {
        case .usageAscending: self = .usageAscending
        case .nameAscending: self = .nameAscending
        case .modifiedDescending: self = .modifiedDescending
        default: self = .usageDescending
        }
    }
    func title(_ language: AppLanguage) -> String {
        let key: String
        let fallback: String
        switch self {
        case .usageDescending: (key, fallback) = ("capabilityUsage.sort.descending", "Usage ↓")
        case .usageAscending: (key, fallback) = ("capabilityUsage.sort.ascending", "Usage ↑")
        case .nameAscending: (key, fallback) = ("capabilityUsage.sort.name", "Name A–Z")
        case .modifiedDescending: (key, fallback) = ("capabilityUsage.sort.modified", "Modified ↓")
        }
        return DirectorLocalizer(language: language).text(key, fallback: fallback)
    }
}

struct DirectorUsagePeriodPicker: View {
    @Binding var selection: CapabilityFolderUsagePeriod
    @EnvironmentObject private var languageStore: AppLanguageStore

    var body: some View {
        DirectorOutlinedSegmentedControl(
            languageStore.localizer.text("capabilityUsage.period", fallback: "Usage period"),
            selection: $selection,
            options: [
                .init(value: .sevenDays, title: languageStore.localizer.text("capabilityUsage.sevenDays", fallback: "Last 7 days")),
                .init(value: .thirtyDays, title: languageStore.localizer.text("capabilityUsage.thirtyDays", fallback: "Last 30 days"))
            ],
            minimumHeight: DirectorCapabilityFilterMetrics.controlHeight
        )
        .frame(width: DirectorCapabilityFilterMetrics.periodWidth)
    }
}

struct DirectorUsageSortMenu: View {
    @Binding var selection: DirectorUsageSortOption
    var allowsModified = false
    @EnvironmentObject private var languageStore: AppLanguageStore

    var body: some View {
        DirectorOutlinedMenuField(selection.title(languageStore.language), height: DirectorCapabilityFilterMetrics.controlHeight) {
            ForEach(DirectorUsageSortOption.allCases.filter { allowsModified || $0 != .modifiedDescending }) { option in
                Button { selection = option } label: {
                    HStack {
                        Text(option.title(languageStore.language))
                        if selection == option { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                }
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .frame(width: DirectorCapabilityFilterMetrics.sortWidth)
        .accessibilityLabel(languageStore.localizer.text("library.sort", fallback: "Sort"))
        .accessibilityValue(selection.title(languageStore.language))
    }
}
