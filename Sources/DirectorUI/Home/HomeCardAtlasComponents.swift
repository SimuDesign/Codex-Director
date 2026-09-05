import AppKit
import SwiftUI

/// Named Home-only numeric roles keep the Avenir Next treatment visible in
/// code without changing the application's general interface typography.
public enum HomeNumericTypography {
    public static let metric = DirectorTypography.homeMetric
    public static let percentage = DirectorTypography.homePercentage
    public static let timestamp = DirectorTypography.homeTimestamp
    public static let rankIndex = DirectorTypography.homeRank
    public static let rankCount = DirectorTypography.homeRankCount
}

/// Home strings remain caller-localized. These stable keys make the module
/// contract explicit while allowing the same components to serve English and
/// Simplified Chinese.
public enum HomeCardAtlasCopy {
    public static let usageTitle = "home.module.usage"
    public static let capabilitySummaryTitle = "home.module.capabilitySummary"
    public static let usageRankingTitle = "home.module.usageRanking"
}

/// Home-only page frame. Unlike the shared editorial frame, this owns the
/// outer workspace measurement so Home's 40/16 pt breakpoint is not derived
/// from a second, already-padded geometry context.
public struct HomeCardAtlasFrame<Content: View>: View {
    public let workspaceWidth: CGFloat
    private let content: Content

    public init(workspaceWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.workspaceWidth = workspaceWidth
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DirectorColor.canvas.ignoresSafeArea()
            DirectorGradient.ambientField.ignoresSafeArea()
            ScrollView {
                DirectorPageContentFrame(workspaceWidth: workspaceWidth) {
                    content
                }
            }
        }
    }
}

/// The only Home image packaged by the Card Atlas implementation. The source
/// PNG is transparent and is deliberately loaded through the DirectorUI
/// module bundle so SwiftPM tests and the application share one resource path.
enum HomeCardAtlasAsset {
    static let fileName = "home-capability-archive-v3-trimmed"

    static var url: URL? {
        Bundle.module.url(forResource: fileName, withExtension: "png", subdirectory: "Home")
            ?? Bundle.module.url(forResource: fileName, withExtension: "png")
    }

    static var image: NSImage? {
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Presentation-only mapping for the Home quota ring. The model continues to
/// own the reported quota semantics; this value merely turns the optional
/// remaining percentage into the two drawable ring segments and one center
/// label. A missing or invalid observation never becomes a full allowance.
struct QuotaRingPresentation: Equatable, Sendable {
    let remainingFraction: Double?
    let consumedFraction: Double?
    let centerText: String
    let isAwaitingNewRecord: Bool

    static func make(remainingPercent: Double?) -> Self {
        guard let remainingPercent, remainingPercent.isFinite else {
            return Self(
                remainingFraction: nil,
                consumedFraction: nil,
                centerText: "—",
                isAwaitingNewRecord: true
            )
        }

        let remaining = min(1, max(0, remainingPercent / 100))
        return Self(
            remainingFraction: remaining,
            consumedFraction: 1 - remaining,
            centerText: String(format: "%.0f%%", remaining * 100),
            isAwaitingNewRecord: false
        )
    }
}

/// A custom ring keeps the quota drawing legible as progress rather than a
/// generic Swift Charts donut. The track and consumed segment use dynamic
/// system text color; only the remaining segment carries the approved accent
/// gradient. The parent supplies the single accessibility value.
struct HomeQuotaProgressRing: View {
    let presentation: QuotaRingPresentation
    let diameter: CGFloat
    let lineWidth: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealProgress = 0.0

    init(
        presentation: QuotaRingPresentation,
        diameter: CGFloat = 236,
        lineWidth: CGFloat = DirectorSpacing.homeQuotaRingLineWidth
    ) {
        self.presentation = presentation
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    DirectorColor.boundary.opacity(contrast == .increased ? 0.88 : 0.58),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            if let remaining = presentation.remainingFraction,
               let consumed = presentation.consumedFraction {
                let remainingEnd = min(remaining, revealProgress)
                let consumedEnd = max(remaining, min(remaining + consumed, revealProgress))
                Circle()
                    .trim(from: 0, to: remainingEnd)
                    .stroke(
                        DirectorGradient.primaryButton,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                if consumedEnd > remaining {
                    Circle()
                        .trim(from: remaining, to: consumedEnd)
                        .stroke(
                            DirectorColor.textPrimary.opacity(contrast == .increased ? 0.42 : 0.28),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear(perform: reveal)
        .onChange(of: presentation) { _, _ in reveal() }
        .onChange(of: reduceMotion) { _, _ in reveal() }
        .accessibilityHidden(true)
    }

    private func reveal() {
        guard !reduceMotion else {
            revealProgress = 1
            return
        }
        revealProgress = 0
        withAnimation(.easeOut(duration: DirectorMotion.emphasized)) {
            revealProgress = 1
        }
    }
}

/// A transparent, non-material boundary used only for the three Home modules.
/// The header rule provides hierarchy without adding a nested card surface.
public struct HomeOutlineModule<Content: View>: View {
    public let title: String
    public let supportingText: String?
    public let tone: DirectorAccentTone
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        title: String,
        supportingText: String? = nil,
        tone: DirectorAccentTone = .blue,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.supportingText = supportingText
        self.tone = tone
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space6) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DirectorColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let supportingText, !supportingText.isEmpty {
                    Text(supportingText)
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSecondary)
                }
                Rectangle()
                    .fill(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.82))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, DirectorSpacing.space4)
            content
        }
        .padding(.horizontal, DirectorSpacing.space6)
        .padding(.bottom, DirectorSpacing.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.homeModule, style: .continuous)
                .stroke(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.84), lineWidth: contrast == .increased ? 1.5 : 1)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.homeModule, style: .continuous))
    }
}

/// Compact Home hero. Refresh is owned by the global window toolbar so every
/// destination exposes the same action and the page header stays editorial.
public struct HomeHeroHeader: View {
    public let title: String
    public let titleAccent: String?
    public let latestUpdateText: String?
    public let statusText: String?
    public let compact: Bool

    public init(
        title: String,
        titleAccent: String? = nil,
        latestUpdateText: String? = nil,
        statusText: String? = nil,
        compact: Bool = false
    ) {
        self.title = title
        self.titleAccent = titleAccent
        self.latestUpdateText = latestUpdateText
        self.statusText = statusText
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
            titleText
                .font(compact ? DirectorTypography.editorialHeroTitleCompact : DirectorTypography.editorialHeroTitle)
                .foregroundStyle(DirectorColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            if let latestUpdateText, !latestUpdateText.isEmpty {
                Text(latestUpdateText)
                    .font(HomeNumericTypography.timestamp)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: Text {
        guard let titleAccent,
              let range = title.range(of: titleAccent),
              !titleAccent.isEmpty else {
            return Text(title)
        }

        let prefix = String(title[..<range.lowerBound])
        let suffix = String(title[range.upperBound...])
        return Text("\(Text(prefix))\(Text(titleAccent).foregroundStyle(DirectorGradient.primaryButton))\(Text(suffix))")
    }
}

/// A reusable grid shell for the four Home summary metrics. The parent keeps
/// ownership of the metric actions; this shell only applies the responsive
/// 4/2/1 geometry.
public struct HomeMetricStrip<Content: View>: View {
    public let contentWidth: CGFloat
    private let content: Content

    public init(contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.contentWidth = contentWidth
        self.content = content()
    }

    public var body: some View {
        let columns = HomeLayout.metricColumns(for: contentWidth)
        LazyVGrid(columns: columns.gridItems(), spacing: 0) {
            content
        }
        .padding(DirectorSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            HomeMetricRuleOverlay(columns: columns)
        }
    }
}

private struct HomeMetricRuleOverlay: View {
    let columns: Int
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            var path = Path()
            if columns > 1 {
                for index in 1..<columns {
                    let x = size.width * CGFloat(index) / CGFloat(columns)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
            }
            if columns == 2 {
                let y = size.height / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            } else if columns == 1 {
                for index in 1..<4 {
                    let y = size.height * CGFloat(index) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            context.stroke(
                path,
                with: .color(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.82)),
                lineWidth: contrast == .increased ? 1.5 : 1
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A metric segment with a native Button role. The icon is optical decoration
/// and the combined label preserves its semantic meaning for VoiceOver.
public struct HomeMetricSegment: View {
    public let symbolName: String
    public let label: String
    public let value: String
    public let supportingText: String?
    public let tone: DirectorAccentTone
    public let action: () -> Void

    public init(
        symbolName: String,
        label: String,
        value: String,
        supportingText: String? = nil,
        tone: DirectorAccentTone = .blue,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.label = label
        self.value = value
        self.supportingText = supportingText
        self.tone = tone
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                HStack(spacing: DirectorSpacing.space2) {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DirectorColor.accent(tone))
                        .frame(width: 38, height: 38)
                        .background(DirectorColor.accent(tone).opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    Text(label)
                        .font(DirectorTypography.supporting.weight(.semibold))
                        .foregroundStyle(DirectorColor.textPrimary)
                }
                Text(value)
                    .font(HomeNumericTypography.metric)
                    .foregroundStyle(DirectorColor.accent(tone))
                    .fixedSize()
                if let supportingText {
                    Text(supportingText)
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        }
        .buttonStyle(HomeMetricSegmentButtonStyle())
        .accessibilityLabel([label, value, supportingText].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct HomeMetricSegmentButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(DirectorSpacing.space4)
            .background(configuration.isPressed || isHovering ? DirectorColor.inset : Color.clear)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// A comparison shell for the three usage-ranking columns. Columns receive
/// their own internal grammar from the caller while this component guarantees
/// top alignment and the approved wide/stacked breakpoints.
public struct HomeRankingLedger<Content: View>: View {
    public let contentWidth: CGFloat
    private let content: Content

    public init(contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.contentWidth = contentWidth
        self.content = content()
    }

    public var body: some View {
        Group {
            if HomeLayout.rankingColumns(for: contentWidth) == 3 {
                HStack(alignment: .top, spacing: 0) { content }
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space6) { content }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay {
            if HomeLayout.rankingColumns(for: contentWidth) == 3 {
                HomeRankingRuleOverlay()
            }
        }
    }
}

private struct HomeRankingRuleOverlay: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let oneThird = proxy.size.width / 3
                path.move(to: CGPoint(x: oneThird, y: 0))
                path.addLine(to: CGPoint(x: oneThird, y: proxy.size.height))
                path.move(to: CGPoint(x: oneThird * 2, y: 0))
                path.addLine(to: CGPoint(x: oneThird * 2, y: proxy.size.height))
            }
            .stroke(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.82), lineWidth: contrast == .increased ? 1.5 : 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Int {
    func gridItems() -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: DirectorSpacing.space4), count: self)
    }
}
