import SwiftUI
import DirectorCore

/// Opaque content panel shared by Home and non-Card-Atlas surfaces.
public struct DirectorPanel<Content: View>: View {
    private let compact: Bool
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    public var body: some View {
        content
            .padding(compact ? DirectorSpacing.space4 : DirectorSpacing.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DirectorColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                    .stroke(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.82), lineWidth: contrast == .increased ? 1.5 : 1)
                    .accessibilityHidden(true)
            }
    }
}

/// Full-width opaque stage used to separate an editorial section from its
/// ambient page field. It deliberately avoids a nested rounded-card stack.
public struct DirectorContentStage<Content: View>: View {
    private let compact: Bool
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    public var body: some View {
        content
            .padding(compact ? DirectorSpacing.space4 : DirectorSpacing.contentStagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DirectorColor.panel)
            .overlay(alignment: .top) {
                Rectangle().fill(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.82)).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.82)).frame(height: 1)
            }
    }
}

/// Stable ordinal rail for Home's three major sections.
public struct DirectorSectionBand<Content: View>: View {
    public let ordinal: String
    public let title: String
    public let supportingText: String?
    public let tone: DirectorAccentTone
    private let content: Content

    public init(ordinal: String, title: String, supportingText: String? = nil, tone: DirectorAccentTone = .teal, @ViewBuilder content: () -> Content) {
        self.ordinal = ordinal
        self.title = title
        self.supportingText = supportingText
        self.tone = tone
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DirectorSpacing.space4) {
            Text(ordinal)
                .font(DirectorTypography.eyebrow)
                .foregroundStyle(DirectorColor.accent(tone))
                .frame(width: 36, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
                VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                    Text(title)
                        .font(DirectorTypography.sectionTitle.weight(.semibold))
                        .foregroundStyle(DirectorColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let supportingText {
                        Text(supportingText)
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textSecondary)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DirectorSpacing.space6)
        .overlay(alignment: .bottom) { Rectangle().fill(DirectorColor.boundary).frame(height: 1) }
    }
}

/// Responsive metric sequence. Width is the measured content width, not the
/// outer window width, so compact 420–759pt content remains a true 2×2 grid.
public struct DirectorMetricSequence<Content: View>: View {
    public let contentWidth: CGFloat
    private let content: Content

    public init(contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.contentWidth = contentWidth
        self.content = content()
    }

    public var body: some View {
        LazyVGrid(columns: DirectorAdaptiveGrid.items(for: contentWidth), spacing: DirectorSpacing.space3) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Column labels only appear when the parent has enough width to represent the
/// corresponding row columns. Native List selection remains in the caller.
public struct DirectorTableHeader: View {
    public let name: String
    public let summary: String
    public let count: String

    public init(name: String, summary: String, count: String) {
        self.name = name
        self.summary = summary
        self.count = count
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
            Text("#")
                .frame(width: 28, alignment: .leading)
            Text(name)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(summary)
                .frame(width: 116, alignment: .trailing)
            Text(count)
                .frame(width: 76, alignment: .trailing)
        }
        .font(DirectorTypography.eyebrow)
        .foregroundStyle(DirectorColor.textTertiary)
        .padding(.horizontal, DirectorSpacing.space3)
        .padding(.bottom, DirectorSpacing.space2)
        .overlay(alignment: .bottom) { Rectangle().fill(DirectorColor.boundary).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

public struct DirectorMetricCard: View {
    public let symbolName: String
    public let action: () -> Void
    public let label: String
    public let value: String
    public let supportingText: String?
    public let ordinal: String?
    public let valueFont: Font
    public let selected: Bool
    public let tone: DirectorAccentTone
    public let minimumHeight: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    public init(symbolName: String, label: String, value: String, supportingText: String? = nil, ordinal: String? = nil, valueFont: Font = DirectorTypography.metric, selected: Bool = false, tone: DirectorAccentTone = .blue, minimumHeight: CGFloat = 136, action: @escaping () -> Void) {
        self.symbolName = symbolName
        self.label = label
        self.value = value
        self.supportingText = supportingText
        self.ordinal = ordinal
        self.valueFont = valueFont
        self.selected = selected
        self.tone = tone
        self.minimumHeight = minimumHeight
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                    if let ordinal {
                        Text(ordinal)
                            .font(DirectorTypography.label.weight(.semibold).monospacedDigit())
                            .foregroundStyle(DirectorColor.accent(tone))
                            .accessibilityHidden(true)
                    }
                    Image(systemName: symbolName)
                        .foregroundStyle(selected ? DirectorColor.accent(tone) : DirectorColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(label).font(DirectorTypography.supporting.weight(.semibold)).foregroundStyle(DirectorColor.textPrimary)
                }
                Text(value).font(valueFont).foregroundStyle(DirectorColor.accent(tone)).fixedSize()
                if let supportingText {
                    Text(supportingText)
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // `minimumHeight` is the final outer height. Subtract the style's
            // two `space4` vertical insets to avoid accidental expansion.
            .frame(maxWidth: .infinity, minHeight: max(0, minimumHeight - DirectorSpacing.space4 * 2), alignment: .leading)
        }
        .buttonStyle(DirectorMetricCardButtonStyle(selected: selected, tone: tone, contrast: contrast))
        .accessibilityLabel([label, value, supportingText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DirectorMetricCardButtonStyle: ButtonStyle {
    let selected: Bool
    let tone: DirectorAccentTone
    let contrast: ColorSchemeContrast
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(DirectorSpacing.space4)
            .background {
                RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                    .fill(
                        selected
                            ? DirectorColor.accent(tone).opacity(0.055)
                            : DirectorColor.inset.opacity(isHovering || configuration.isPressed ? 0.72 : 0)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                    .stroke(
                        selected || configuration.isPressed
                            ? DirectorColor.accent(tone)
                            : DirectorColor.boundary.opacity(contrast == .increased ? 1 : (isHovering ? 1 : 0.92)),
                        lineWidth: contrast == .increased || configuration.isPressed ? 1.5 : 1
                    )
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: DirectorMotion.instant), value: isHovering)
            .animation(.easeOut(duration: DirectorMotion.instant), value: configuration.isPressed)
    }
}

public struct DirectorGroupHeader: View {
    public let title: String
    public let supportingText: String?
    public let ordinal: String?
    public let trailingText: String?
    public let symbolName: String?
    public let tone: DirectorAccentTone

    public init(title: String, supportingText: String? = nil, ordinal: String? = nil, trailingText: String? = nil, symbolName: String? = nil, tone: DirectorAccentTone = .teal) {
        self.title = title
        self.supportingText = supportingText
        self.ordinal = ordinal
        self.trailingText = trailingText
        self.symbolName = symbolName
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                if let ordinal {
                    Text(ordinal)
                        .font(DirectorTypography.label.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DirectorColor.accent(tone))
                        .accessibilityHidden(true)
                }
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(DirectorTypography.supporting.weight(.semibold))
                        .foregroundStyle(DirectorColor.accent(tone))
                        .frame(width: 24, height: 24)
                        .background(DirectorColor.accent(tone).opacity(0.12), in: RoundedRectangle(cornerRadius: DirectorRadius.compact, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(ordinal == nil ? .title3.weight(.semibold) : .title2.weight(.semibold))
                    .foregroundStyle(DirectorColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DirectorSpacing.space3)
                if let trailingText, !trailingText.isEmpty {
                    Text(trailingText)
                        .font(DirectorTypography.label.monospacedDigit())
                        .foregroundStyle(DirectorColor.textSecondary)
                        .fixedSize()
                }
            }
            if let supportingText {
                Text(supportingText)
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
        }
    }
}
