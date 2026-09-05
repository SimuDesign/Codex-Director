import SwiftUI
import DirectorCore

/// Chronological invocation timeline for one session.
///
/// Native `LazyVStack` with stable order, nesting, retry, compaction,
/// interruption, status, duration, and confidence. Raw payloads are never
/// shown; Reduce Motion needs no extra handling because the timeline has no
/// travel animation.
public struct InvocationTimelineView: View {
    public let events: [InvocationEvent]
    public let emptyMessage: String
    private let depths: [String: Int]
    @Binding public var selection: String?
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(
        events: [InvocationEvent],
        depths: [String: Int] = [:],
        selection: Binding<String?> = .constant(nil),
        emptyMessage: String = "No invocations recorded for this task."
    ) {
        self.events = events
        self.depths = depths
        self._selection = selection
        self.emptyMessage = emptyMessage
    }

    public var body: some View {
        if events.isEmpty {
            VStack(spacing: DirectorSpacing.space3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title)
                    .foregroundStyle(DirectorColor.textTertiary)
                Text(languageStore.localizer.text(emptyMessage, fallback: emptyMessage))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        Button {
                            selection = event.id
                        } label: {
                            row(event)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == event.id ? .isSelected : [])
                        .accessibilityValue(selection == event.id ? languageStore.localizer.text("Selected", fallback: "Selected") : "")
                        Divider()
                    }
                }
                .padding(.vertical, DirectorSpacing.space2)
            }
        }
    }

    private func row(_ event: InvocationEvent) -> some View {
        HStack(spacing: DirectorSpacing.space2) {
            Rectangle()
                .fill(DirectorColor.separator)
                .frame(width: DirectorSpacing.space1 * CGFloat(depths[event.id] ?? 0), height: 1)
            Image(systemName: symbol(for: event))
                .foregroundStyle(color(for: event))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(name(for: event))
                .font(DirectorTypography.code)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0)
                .layoutPriority(0)
            if event.status != .completed && event.status != .unknown {
                RuntimeStatusBadge(status: status(for: event))
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let durationMs = event.durationMs {
                Text(durationText(durationMs))
                    .font(DirectorTypography.data)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if event.confidence != .exact {
                ConfidenceBadge(confidence: event.confidence)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: DirectorSpacing.space3)
            if let timestamp = event.timestamp {
                Text(languageStore.localizer.date(timestamp, style: Date.FormatStyle(time: .shortened)))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, DirectorSpacing.space1)
        .padding(.horizontal, DirectorSpacing.space3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: event))
    }

    private func name(for event: InvocationEvent) -> String {
        switch event.kind {
        case .agent: return event.resourceID ?? enumLabel(event.kind, fallback: "Agent")
        case .skill: return event.resourceID ?? enumLabel(event.kind, fallback: "Skill")
        case .orchestration: return event.resourceID ?? enumLabel(event.kind, fallback: "Orchestration")
        case .compaction: return enumLabel(event.kind, fallback: "Compaction")
        case .interruption: return enumLabel(event.kind, fallback: "Interruption")
        default: return event.resourceID ?? enumLabel(event.kind, fallback: event.kind.rawValue.capitalized)
        }
    }

    private func symbol(for event: InvocationEvent) -> String {
        switch event.kind {
        case .compaction: return "arrow.triangle.merge"
        case .interruption: return "stop.circle"
        case .agent: return "person.crop.circle"
        case .skill: return "sparkles"
        case .orchestration: return "arrow.triangle.branch"
        case .tool: return "wrench.and.screwdriver"
        default: return "circle"
        }
    }

    private func color(for event: InvocationEvent) -> Color {
        switch event.status {
        case .failed, .interrupted: return DirectorColor.status(.failure)
        case .retried: return DirectorColor.status(.warning)
        case .completed: return DirectorColor.status(.success)
        default: return DirectorColor.textSecondary
        }
    }

    private func status(for event: InvocationEvent) -> RuntimeStatus {
        switch event.status {
        case .failed: return .failure
        case .interrupted: return .blocked
        case .retried: return .warning
        case .started: return .running
        case .completed: return .success
        case .unknown: return .unknown
        }
    }

    private func accessibilityText(for event: InvocationEvent) -> String {
        let kindLabel: String
        switch event.kind {
        case .agent: kindLabel = enumLabel(event.kind, fallback: "Agent")
        case .skill: kindLabel = enumLabel(event.kind, fallback: "Skill")
        case .orchestration: kindLabel = enumLabel(event.kind, fallback: "Orchestration")
        default: kindLabel = enumLabel(event.kind, fallback: event.kind.rawValue.capitalized)
        }
        var parts = [name(for: event), kindLabel, enumLabel(event.status, fallback: event.status.rawValue.capitalized)]
        if let durationMs = event.durationMs {
            parts.append(durationText(durationMs))
        }
        if event.confidence != .exact {
            parts.append(languageStore.localizer.format("confidence %@", fallback: "confidence %@", enumLabel(event.confidence, fallback: event.confidence.rawValue.capitalized)))
        }
        return parts.joined(separator: ", ")
    }

    private func enumLabel<Value: RawRepresentable>(_ value: Value, fallback: String) -> String where Value.RawValue == String {
        languageStore.localizer.enumLabel(.init(key: Self.localizationKey(for: value), fallback: fallback))
    }

    static func localizationKey<Value: RawRepresentable>(for value: Value) -> String where Value.RawValue == String {
        let prefix = labelKeyPrefix(for: value)
        return prefix + value.rawValue
    }

    private static func labelKeyPrefix<Value: RawRepresentable>(for value: Value) -> String {
        switch value {
        case is InvocationKind: return "invocation.kind."
        case is InvocationStatus: return "status."
        case is EvidenceConfidence: return "confidence."
        default: return "enum."
        }
    }

    private func durationText(_ durationMs: Int) -> String {
        if durationMs >= 60_000 {
            return languageStore.localizer.format("%.1f min", fallback: "%.1f min", Double(durationMs) / 60_000)
        }
        if durationMs >= 1_000 {
            return languageStore.localizer.format("%.1f s", fallback: "%.1f s", Double(durationMs) / 1_000)
        }
        return languageStore.localizer.format("%lld ms", fallback: "%lld ms", durationMs)
    }

    public static func durationText(_ durationMs: Int) -> String {
        if durationMs >= 60_000 {
            return String(format: "%.1f min", Double(durationMs) / 60_000)
        }
        if durationMs >= 1_000 {
            return String(format: "%.1f s", Double(durationMs) / 1_000)
        }
        return "\(durationMs) ms"
    }
}
