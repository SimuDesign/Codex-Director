import Foundation
import DirectorCore

/// Pure row presentation. Recorded reads/delegations are not success metrics.
struct CapabilityFolderUsageDisplay {
    let value: String
    let caption: String
    let accessibilityText: String
    let help: String

    init(count: Int?, stats: CapabilityUsageStats?, period: CapabilityFolderUsagePeriod, language: AppLanguage) {
        let localizer = DirectorLocalizer(language: language)
        let periodName = localizer.text(period == .thirtyDays ? "capabilityFolders.usage.thirtyDays" : "capabilityFolders.usage.sevenDays", fallback: period == .thirtyDays ? "Last 30 days" : "Last 7 days")
        let recorded = localizer.text("capabilityFolders.usage.recorded", fallback: "Recorded calls")
        value = count.flatMap { $0 >= 0 ? String($0) : nil } ?? "—"
        caption = localizer.text(period == .thirtyDays ? "capabilityFolders.usage.captionThirty" : "capabilityFolders.usage.captionSeven", fallback: period == .thirtyDays ? "Recorded · 30 days" : "Recorded · 7 days")
        let pending = localizer.text("capabilityFolders.usage.pending", fallback: "Statistics not ready")
        let scope = localizer.text("capabilityFolders.usage.allProjects", fallback: "All usage projects")
        var qualifiers: [String] = []
        if let stats {
            if stats.inferredCount > 0 {
                qualifiers.append(localizer.format("capabilityFolders.usage.inferred", fallback: "%d inferred", stats.inferredCount))
            }
            if stats.coverage != .complete {
                qualifiers.append(localizer.text("capabilityFolders.usage.partial", fallback: "Evidence coverage partial or unknown"))
            }
        }
        accessibilityText = ([periodName, value == "—" ? pending : "\(value) \(recorded)", scope] + qualifiers).joined(separator: ", ")
        help = ([localizer.text("capabilityFolders.usage.help", fallback: "Recorded delegation/read evidence, not successful execution or effectiveness. Zero means no calls were recorded, not that the capability was unused."), scope] + qualifiers).joined(separator: " · ")
    }

    /// Nil requests a stable name/ID tie-breaker; unknown always sorts last.
    static func compareCounts(_ lhs: Int?, _ rhs: Int?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?): return left == right ? nil : (ascending ? left < right : left > right)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
}
