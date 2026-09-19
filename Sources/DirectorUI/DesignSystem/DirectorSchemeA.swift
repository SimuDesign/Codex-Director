import SwiftUI
import AppKit
import DirectorCore

/// The small, semantic accent vocabulary used by Scheme A. Keeping the
/// vocabulary typed prevents feature views from inventing one-off colors.
public enum DirectorAccentTone: String, CaseIterable, Sendable {
    case blue
    case ice
    case mint
    case teal
}

/// Visual feedback variants for a filled primary action. Each variant keeps
/// an opaque, appearance-specific rail so state feedback never reduces the
/// contrast of the label or symbol.
public enum DirectorActionState: Sendable {
    case normal
    case hover
    case pressed
    case disabled
}

/// Gradients are shared surface treatments, not per-page decoration.
public enum DirectorGradient {
    /// The blue → ice → mint brand rail used by the quota visualization,
    /// Home title and navigation selection. Action controls use the separate
    /// appearance-aware rail below.
    public static let brand = LinearGradient(
        colors: [DirectorColor.accentBlue, DirectorColor.accentIce, DirectorColor.accentMint],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Compatibility name for existing non-action brand consumers. New
    /// controls should use `primaryAction(state:)` so their foreground and
    /// background semantics stay independent from charts and titles.
    public static let primaryButton = brand

    public static let navigationSelected = brand

    /// Appearance-aware filled action treatment. Light mode uses the deeper
    /// approved stops (#0065B3 → #00738B → #087765) for white content; Dark
    /// mode retains the existing bright stops for black content.
    public static func primaryAction(state: DirectorActionState = .normal) -> LinearGradient {
        let colors: [Color]
        switch state {
        case .normal:
            colors = [DirectorColor.actionBlue, DirectorColor.actionIce, DirectorColor.actionMint]
        case .hover:
            colors = [DirectorColor.actionHoverBlue, DirectorColor.actionHoverIce, DirectorColor.actionHoverMint]
        case .pressed:
            colors = [DirectorColor.actionPressedBlue, DirectorColor.actionPressedIce, DirectorColor.actionPressedMint]
        case .disabled:
            colors = [DirectorColor.actionDisabledBlue, DirectorColor.actionDisabledIce, DirectorColor.actionDisabledMint]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    /// Vertical quota-bar treatment using the same brand rail as primary
    /// actions, without assigning a warning or status meaning to the chart.
    public static let quotaBar = LinearGradient(
        colors: [DirectorColor.accentBlue, DirectorColor.accentIce, DirectorColor.accentMint],
        startPoint: .bottom,
        endPoint: .top
    )

    public static func accent(_ tone: DirectorAccentTone) -> LinearGradient {
        // Editorial title accents keep the approved blue -> ice -> mint
        // chromatic rail visible on every page. The page tone changes the
        // leading stop, but never collapses the treatment into a translucent
        // version of one semantic color (which made the teal page unreadable
        // in dark mode).
        let colors = accentStopTones(for: tone).map(DirectorColor.accent)
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func accentStopTones(for tone: DirectorAccentTone) -> [DirectorAccentTone] {
        switch tone {
        case .blue: return [.blue, .ice, .mint]
        case .ice: return [.ice, .mint, .blue]
        case .mint: return [.mint, .blue, .ice]
        // Teal remains the page semantic tone for labels and metrics, while
        // the title rail starts with the higher-contrast core accent family.
        case .teal: return [.blue, .ice, .mint]
        }
    }

    /// A restrained selected-row/card wash. Content remains opaque and the
    /// system selection state remains the source of truth for accessibility.
    public static func selectionWash(_ tone: DirectorAccentTone = .blue) -> LinearGradient {
        let color = DirectorColor.accent(tone)
        return LinearGradient(
            colors: [color.opacity(0.16), color.opacity(0.05)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    public static let environment = LinearGradient(
        colors: [DirectorColor.environmentLight, DirectorColor.canvas.opacity(0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A restrained field behind editorial pages. Content stages remain
    /// opaque; this gradient only establishes the page's visual atmosphere.
    public static let ambientField = RadialGradient(
        colors: [DirectorColor.environmentStrong.opacity(0.34), DirectorColor.environmentDeep.opacity(0)],
        center: .topLeading,
        startRadius: 12,
        endRadius: 720
    )
}

/// Shared page canvas. It provides the visual boundary without introducing
/// an additional scroll container or a glass material into content.
public struct DirectorCanvas<Content: View>: View {
    private let compact: Bool
    private let contentPadding: Bool
    private let content: Content

    public init(compact: Bool = false, contentPadding: Bool = true, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.contentPadding = contentPadding
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DirectorColor.canvas.ignoresSafeArea()
            DirectorGradient.environment.ignoresSafeArea()
            content
                .padding(contentPadding ? (compact ? DirectorSpacing.compactPagePadding : DirectorSpacing.pagePadding) : 0)
                .frame(maxWidth: DirectorSpacing.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// Editorial page background shared by the capability libraries and Settings.
/// Feature views keep their native scroll containers full width and apply the
/// shared grid to scroll content instead of moving the scroll indicator.
public struct DirectorEditorialFrame<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DirectorColor.canvas.ignoresSafeArea()
            DirectorGradient.ambientField.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Home-reference content frame for full-width `ScrollView` destinations.
/// Native `List` pages use `DirectorPageLayout.contentMargin(for:)` through
/// `contentMargins` to preserve their row and selection semantics.
public struct DirectorPageContentFrame<Content: View>: View {
    public let workspaceWidth: CGFloat
    private let content: Content

    public init(workspaceWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.workspaceWidth = workspaceWidth
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: DirectorPageLayout.contentWidth(for: workspaceWidth), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, DirectorPageLayout.horizontalPadding(for: workspaceWidth))
            .padding(.vertical, DirectorSpacing.space6)
    }
}

/// A two-column editorial hero: route marker and title lead the scan path,
/// while explanatory copy stays in a readable secondary measure.
public struct DirectorEditorialHero: View {
    public let eyebrow: String?
    public let title: String
    public let titleAccent: String?
    public let subtitle: String?
    public let symbolName: String?
    public let tone: DirectorAccentTone
    public let compact: Bool

    public init(eyebrow: String? = nil, title: String, titleAccent: String? = nil, subtitle: String? = nil, symbolName: String? = nil, tone: DirectorAccentTone = .blue, compact: Bool = false) {
        self.eyebrow = eyebrow
        self.title = title
        self.titleAccent = titleAccent
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.tone = tone
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? DirectorSpacing.space3 : DirectorSpacing.space5) {
            if compact {
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    titleLead
                    subtitleView
                }
            } else {
                HStack(alignment: .bottom, spacing: DirectorSpacing.heroGap) {
                    titleLead
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    subtitleView
                        .frame(width: 360, alignment: .leading)
                }
            }
            Rectangle()
                .fill(DirectorColor.boundary)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, compact ? DirectorSpacing.space2 : DirectorSpacing.space3)
    }

    private var titleLead: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            if let eyebrow, !eyebrow.isEmpty {
                HStack(spacing: DirectorSpacing.space2) {
                    if let symbolName {
                        Image(systemName: symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    Text(eyebrow)
                }
                .font(DirectorTypography.eyebrow)
                .foregroundStyle(DirectorColor.accent(tone))
                .tracking(0.8)
            }
            HStack(alignment: .center, spacing: DirectorSpacing.space3) {
                if (eyebrow == nil || eyebrow?.isEmpty == true), let symbolName {
                    Image(systemName: symbolName)
                        .font(DirectorTypography.pageHeroSymbol)
                        .foregroundStyle(DirectorColor.accent(tone))
                        .accessibilityHidden(true)
                }
                titleText
                    .font(compact ? DirectorTypography.editorialHeroTitleCompact : DirectorTypography.editorialHeroTitle)
                    .foregroundStyle(DirectorColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: Text {
        guard let titleAccent,
              let range = title.range(of: titleAccent),
              !titleAccent.isEmpty else {
            return Text(title)
        }

        let prefix = String(title[..<range.lowerBound])
        let suffix = String(title[range.upperBound...])
        return Text("\(Text(prefix))\(Text(titleAccent).foregroundStyle(DirectorGradient.accent(tone)))\(Text(suffix))")
    }
}

/// A consistent, compact hero for all capability pages and future settings
/// sections. The symbol is a visual cue only; text carries the AX meaning.
public struct DirectorPageHeader: View {
    public let eyebrow: String?
    public let title: String
    /// Optional title fragment that receives the Scheme A accent gradient.
    /// The full title remains a single accessibility value.
    public let titleAccent: String?
    public let subtitle: String?
    public let symbolName: String?
    public let tone: DirectorAccentTone

    public init(
        eyebrow: String? = nil,
        title: String,
        titleAccent: String? = nil,
        subtitle: String? = nil,
        symbolName: String? = nil,
        tone: DirectorAccentTone = .blue
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.titleAccent = titleAccent
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: DirectorSpacing.space8) {
                    titleBlock
                        .layoutPriority(1)
                    Spacer(minLength: DirectorSpacing.space6)
                    subtitleBlock
                        .frame(maxWidth: 400, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
                    titleBlock
                    subtitleBlock
                }
            }
            .padding(.vertical, DirectorSpacing.space8)
            Rectangle()
                .fill(DirectorColor.boundary)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            if let eyebrow, !eyebrow.isEmpty {
                HStack(spacing: DirectorSpacing.space2) {
                    if let symbolName {
                        Image(systemName: symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    Text(eyebrow)
                }
                .font(DirectorTypography.eyebrow)
                .foregroundStyle(DirectorColor.accent(tone))
                .tracking(0.8)
            }
            titleText
                .font(DirectorTypography.heroTitle)
                .foregroundStyle(DirectorColor.textPrimary)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var titleText: Text {
        guard let titleAccent,
              let range = title.range(of: titleAccent),
              !titleAccent.isEmpty else {
            return Text(title)
        }

        let prefix = String(title[..<range.lowerBound])
        let suffix = String(title[range.upperBound...])
        return Text("\(Text(prefix))\(Text(titleAccent).foregroundStyle(DirectorGradient.accent(tone)))\(Text(suffix))")
    }

    @ViewBuilder
    private var subtitleBlock: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The visible control ribbon shared by library pages. The content remains
/// caller-owned so native Pickers and keyboard navigation are preserved.
public struct DirectorFilterRibbon<Content: View>: View {
    private let compact: Bool
    private let content: Content

    public init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    public var body: some View {
        content
            .padding(compact ? DirectorSpacing.space2 : DirectorSpacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.ribbon, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.ribbon, style: .continuous)
                    .stroke(DirectorColor.boundary, lineWidth: 1)
                    .accessibilityHidden(true)
            }
        .accessibilityElement(children: .contain)
    }
}

/// Shared visual container for editable and single-select library controls.
/// The caller retains the native TextField/Menu behavior and accessibility;
/// this primitive owns only the common surface and hit geometry.
public struct DirectorControlField<Content: View>: View {
    private let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, DirectorSpacing.space3)
            .frame(minHeight: DirectorSpacing.controlMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .fill(reduceTransparency ? DirectorColor.inset : DirectorColor.controlField)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .stroke(
                        DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.86),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
    }
}

/// A real native single-choice control with local Scheme A drawing. AppKit
/// owns the three actionable accessibility children, selection, keyboard
/// navigation and focus; there is no hidden accessibility-only replica.
public struct DirectorOutlinedSegmentedControl<Selection: Hashable>: View {
    public struct Option: Identifiable {
        public let value: Selection
        public let title: String

        public init(value: Selection, title: String) {
            self.value = value
            self.title = title
        }

        public var id: Selection { value }
    }

    private let label: String
    private let options: [Option]
    @Binding private var selection: Selection
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ label: String, selection: Binding<Selection>, options: [Option]) {
        self.label = label
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        DirectorNativeSegmentedControlBridge(
            label: label,
            titles: options.map(\.title),
            selectedIndex: options.firstIndex(where: { $0.value == selection }) ?? -1,
            isEnabled: isEnabled,
            increasedContrast: contrast == .increased,
            reduceTransparency: reduceTransparency
        ) { index in
            guard options.indices.contains(index) else { return }
            selection = options[index].value
        }
    }
}

private struct DirectorNativeSegmentedControlBridge: NSViewRepresentable {
    let label: String
    let titles: [String]
    let selectedIndex: Int
    let isEnabled: Bool
    let increasedContrast: Bool
    let reduceTransparency: Bool
    let selectionChanged: (Int) -> Void

    func makeNSView(context: Context) -> DirectorNativeOutlinedSegmentedControl {
        DirectorNativeOutlinedSegmentedControl(frame: .zero)
    }

    func updateNSView(_ control: DirectorNativeOutlinedSegmentedControl, context: Context) {
        if control.segmentCount != titles.count { control.segmentCount = titles.count }
        for (index, title) in titles.enumerated() {
            control.setLabel(title, forSegment: index)
            control.setToolTip(title, forSegment: index)
        }
        control.selectedSegment = selectedIndex
        control.isEnabled = isEnabled
        control.increasedContrast = increasedContrast
        control.reduceTransparency = reduceTransparency
        control.selectionChanged = selectionChanged
        control.setAccessibilityLabel(label)
        control.invalidateIntrinsicContentSize()
        control.needsLayout = true
        control.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DirectorNativeOutlinedSegmentedControl, context: Context) -> CGSize? {
        nsView.fittingSize(forWidth: proposal.width)
    }
}

/// The native cell and real segment labels remain the AX and interaction
/// source of truth. Only this instance's painting is replaced; no window-wide
/// control discovery, appearance mutation, private APIs or swizzling.
final class DirectorNativeOutlinedSegmentedControl: NSSegmentedControl {
    var increasedContrast = false
    var reduceTransparency = false
    var selectionChanged: ((Int) -> Void)?
    private var hoveredSegment: Int?
    private var pressedSegment: Int?
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackingMode = .selectOne
        segmentDistribution = .fillEqually
        segmentStyle = .rounded
        font = NSFont.preferredFont(forTextStyle: .body)
        focusRingType = .exterior
        target = self
        action = #selector(selectionDidChange)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    @objc private func selectionDidChange() {
        needsDisplay = true
        selectionChanged?(selectedSegment)
    }

    override func layout() {
        super.layout()
        guard segmentCount > 0 else { return }
        for index in 0..<segmentCount {
            setWidth(bounds.width / CGFloat(segmentCount), forSegment: index)
        }
    }

    override var intrinsicContentSize: NSSize { fittingSize(forWidth: nil) }

    func fittingSize(forWidth proposedWidth: CGFloat?) -> CGSize {
        guard segmentCount > 0 else { return .zero }
        let padding = DirectorSpacing.space1
        let gaps = padding * CGFloat(segmentCount - 1)
        let idealItemWidth = (0..<segmentCount).map {
            attributedTitle(for: $0, useSemibold: true).boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width.rounded(.up) + padding
        }.max() ?? 0
        let width = proposedWidth ?? (idealItemWidth + DirectorSpacing.space2 * 2) * CGFloat(segmentCount) + gaps + padding * 2
        let textWidth = max(1, (width - padding * 2 - gaps) / CGFloat(segmentCount) - DirectorSpacing.space2 * 2)
        let textHeight = (0..<segmentCount).map {
            attributedTitle(for: $0, useSemibold: true).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height.rounded(.up)
        }.max() ?? 0
        return CGSize(width: width, height: max(DirectorCapabilityFolderLayout.segmentHeight, textHeight + padding * 2) + padding * 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredSegment = segmentIndex(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSegment = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressedSegment = segmentIndex(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        displayIfNeeded()
        super.mouseDown(with: event)
        pressedSegment = nil
        needsDisplay = true
    }

    private func segmentIndex(at point: CGPoint) -> Int? {
        guard segmentCount > 0, bounds.contains(point), bounds.width > 0 else { return nil }
        return min(segmentCount - 1, max(0, Int((point.x - bounds.minX) / bounds.width * CGFloat(segmentCount))))
    }

    private func attributedTitle(for index: Int, useSemibold: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let weight: NSFont.Weight = useSemibold || index == selectedSegment ? .semibold : .regular
        return NSAttributedString(
            string: label(forSegment: index) ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: font?.pointSize ?? NSFont.systemFontSize, weight: weight),
                .foregroundColor: NSColor(DirectorColor.textPrimary).withAlphaComponent(isEnabled ? 1 : 0.52),
                .paragraphStyle: paragraph
            ]
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let boundaryWidth: CGFloat = increasedContrast ? 1.5 : 1
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: boundaryWidth / 2, dy: boundaryWidth / 2), xRadius: DirectorRadius.control, yRadius: DirectorRadius.control)
        NSColor(reduceTransparency ? DirectorColor.inset : DirectorColor.controlField).setFill()
        outline.fill()
        NSColor(DirectorColor.controlBoundary).setStroke()
        outline.lineWidth = boundaryWidth
        outline.stroke()
        guard segmentCount > 0 else { return }
        let padding = DirectorSpacing.space1
        let itemWidth = max(0, (bounds.width - padding * 2 - padding * CGFloat(segmentCount - 1)) / CGFloat(segmentCount))
        for index in 0..<segmentCount {
            let rect = NSRect(x: bounds.minX + padding + CGFloat(index) * (itemWidth + padding), y: bounds.minY + padding, width: itemWidth, height: max(0, bounds.height - padding * 2))
            let item = NSBezierPath(roundedRect: rect, xRadius: DirectorRadius.compact, yRadius: DirectorRadius.compact)
            if index == selectedSegment || index == hoveredSegment || index == pressedSegment {
                NSColor(DirectorColor.inset).setFill()
                item.fill()
            }
            if index == selectedSegment {
                let lineWidth: CGFloat = increasedContrast ? 2 : 1.5
                let ring = NSBezierPath(roundedRect: rect, xRadius: DirectorRadius.compact, yRadius: DirectorRadius.compact)
                ring.append(NSBezierPath(roundedRect: rect.insetBy(dx: lineWidth, dy: lineWidth), xRadius: DirectorRadius.compact - lineWidth, yRadius: DirectorRadius.compact - lineWidth))
                ring.windingRule = .evenOdd
                NSGradient(colors: [NSColor(DirectorColor.accentBlue), NSColor(DirectorColor.accentIce), NSColor(DirectorColor.accentMint)])?.draw(in: ring, angle: 0)
            }
            let text = attributedTitle(for: index)
            let textWidth = max(0, rect.width - DirectorSpacing.space2 * 2)
            let textHeight = text.boundingRect(with: CGSize(width: max(1, textWidth), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height.rounded(.up)
            text.draw(with: NSRect(x: rect.minX + DirectorSpacing.space2, y: rect.midY - textHeight / 2, width: textWidth, height: textHeight), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: DirectorRadius.control, yRadius: DirectorRadius.control).fill()
    }
}

/// Neutral outlined frame around an icon-only native Menu. The frame belongs
/// outside Menu because macOS may synthesize its label into an AppKit button
/// and discard label-local backgrounds and sizing.
public struct DirectorOutlinedIconMenu<Content: View>: View {
    private let systemImage: String
    private let content: Content
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(systemImage: String, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: systemImage)
                .font(DirectorTypography.segmentedControl.weight(.semibold))
                .frame(width: DirectorCapabilityFolderLayout.iconMenuTarget, height: DirectorCapabilityFolderLayout.iconMenuTarget)
                .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(DirectorColor.textSecondary)
        .opacity(isEnabled ? 1 : 0.52)
        .frame(width: DirectorCapabilityFolderLayout.iconMenuTarget, height: DirectorCapabilityFolderLayout.iconMenuTarget)
        .background {
            RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                .fill(reduceTransparency ? DirectorColor.inset : DirectorColor.controlField)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                .stroke(
                    DirectorColor.controlBoundary,
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
                .accessibilityHidden(true)
        }
        .frame(width: DirectorCapabilityFolderLayout.iconMenuTarget, height: DirectorCapabilityFolderLayout.iconMenuTarget)
        .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
    }
}

/// Full-width outlined frame around a native `Menu` whose value must remain
/// visible when closed. The painted field owns the hit geometry and sits
/// outside Menu so AppKit cannot collapse it to a small pill.
public struct DirectorOutlinedMenuField<Content: View>: View {
    private let title: String
    private let content: Content
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: DirectorSpacing.space2) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: DirectorSpacing.space1)
                Image(systemName: "chevron.down")
                    .accessibilityHidden(true)
            }
            .font(DirectorTypography.segmentedControl)
            .padding(.horizontal, DirectorSpacing.space3)
            .frame(maxWidth: .infinity, minHeight: DirectorCapabilityFolderLayout.controlHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(DirectorColor.textPrimary)
        .opacity(isEnabled ? 1 : 0.52)
        .frame(minHeight: DirectorCapabilityFolderLayout.controlHeight)
        .background {
            RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                .fill(reduceTransparency ? DirectorColor.inset : DirectorColor.controlField)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                .stroke(
                    DirectorColor.controlBoundary,
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
                .accessibilityHidden(true)
        }
        .frame(minHeight: DirectorCapabilityFolderLayout.controlHeight)
        .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
    }
}

/// Legacy inspector content remains available to non-Card-Atlas consumers.
/// Capability libraries use `DirectorSideSheet` so the list never changes
/// geometry when a resource is selected.
public struct DirectorInspectorPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        DirectorContentStage(compact: true) { content }
            .frame(minWidth: DirectorSpacing.inspectorMinWidth,
                   idealWidth: DirectorSpacing.inspectorIdealWidth,
                   maxWidth: DirectorSpacing.inspectorMaxWidth,
                   alignment: .leading)
    }
}

/// A transient right-side detail surface for capability libraries. The list
/// remains spatially stable underneath the scrim and native focus can be
/// dismissed with Escape or the close button.
public struct DirectorSideSheet<Content: View>: View {
    private let width: CGFloat
    private let onClose: () -> Void
    private let closeLabel: String
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(width: CGFloat = 400, onClose: @escaping () -> Void, closeLabel: String = "Close detail", @ViewBuilder content: () -> Content) {
        self.width = width
        self.onClose = onClose
        self.closeLabel = closeLabel
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(closeLabel)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, DirectorSpacing.space4)
            .padding(.top, DirectorSpacing.space3)
            .padding(.bottom, DirectorSpacing.space2)

            Divider()
                .overlay(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.82))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: min(max(width, DirectorSpacing.sideSheetMinWidth), DirectorSpacing.sideSheetMaxWidth), alignment: .top)
        .background(DirectorColor.canvas)
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.panel, style: .continuous)
                .stroke(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.92), lineWidth: contrast == .increased ? 1.5 : 1)
                .accessibilityHidden(true)
        }
        .onExitCommand(perform: onClose)
        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Filled primary action styling. Native Button focus and disabled semantics
/// remain intact while the visual states are centralized here.
public enum DirectorPrimaryActionButtonSize: Sendable {
    case standard
    case toolbar
    case settings

    fileprivate var font: Font {
        self == .toolbar ? DirectorTypography.toolbarAction : DirectorTypography.primaryAction
    }

    fileprivate var horizontalPadding: CGFloat {
        switch self {
        case .standard: return DirectorSpacing.space5
        case .toolbar: return DirectorSpacing.space3
        case .settings: return DirectorSpacing.space4
        }
    }

    fileprivate var verticalPadding: CGFloat {
        switch self {
        case .standard: return DirectorSpacing.space3
        case .toolbar: return DirectorSpacing.space1
        case .settings: return DirectorSpacing.space2
        }
    }

    fileprivate var minimumHeight: CGFloat {
        switch self {
        case .toolbar: return DirectorSpacing.toolbarControlMinHeight
        case .settings: return DirectorSpacing.settingsActionHeight
        case .standard: return DirectorSpacing.controlMinHeight
        }
    }

    fileprivate var fixedLabelWidth: CGFloat? {
        self == .settings ? DirectorSpacing.settingsActionLabelWidth : nil
    }
}

public struct DirectorPrimaryActionButtonStyle: ButtonStyle {
    private let size: DirectorPrimaryActionButtonSize
    private let isProcessing: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    public init(
        size: DirectorPrimaryActionButtonSize = .standard,
        isProcessing: Bool = false
    ) {
        self.size = size
        self.isProcessing = isProcessing
    }

    public func makeBody(configuration: Configuration) -> some View {
        let visuallyActive = isEnabled || isProcessing
        let actionState: DirectorActionState = if !visuallyActive {
            .disabled
        } else if configuration.isPressed {
            .pressed
        } else if isHovering {
            .hover
        } else {
            .normal
        }
        configuration.label
            .font(size.font)
            .foregroundStyle(DirectorColor.primaryActionForeground)
            .frame(minWidth: size.fixedLabelWidth, maxWidth: size.fixedLabelWidth)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.minimumHeight)
            .background {
                DirectorGradient.primaryAction(state: actionState)
            }
            .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .stroke(DirectorColor.primaryActionBoundary.opacity(contrast == .increased ? 1 : 0.8), lineWidth: contrast == .increased ? 1.5 : 1)
                    .accessibilityHidden(true)
            }
            .shadow(
                color: DirectorColor.primaryActionShadow.opacity(visuallyActive && !configuration.isPressed && size != .toolbar ? 0.16 : 0),
                radius: size == .toolbar ? 0 : 3,
                y: size == .toolbar ? 0 : 1
            )
            .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

/// Secondary action geometry matches the primary action exactly while using
/// the shared translucent control surface.
public struct DirectorSecondaryActionButtonStyle: ButtonStyle {
    private let size: DirectorPrimaryActionButtonSize
    private let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    public init(size: DirectorPrimaryActionButtonSize = .standard, destructive: Bool = false) {
        self.size = size
        self.destructive = destructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(destructive ? DirectorColor.status(.failure) : DirectorColor.textPrimary)
            .frame(minWidth: size.fixedLabelWidth, maxWidth: size.fixedLabelWidth)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.minimumHeight)
            .background {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .fill(reduceTransparency ? DirectorColor.inset : DirectorColor.controlField)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.72 : (isHovering ? 0.92 : 1)) : 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .stroke(
                        destructive ? DirectorColor.status(.failure).opacity(0.68) : DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.86),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                    .accessibilityHidden(true)
            }
            .opacity(isEnabled ? 1 : 0.72)
            .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

public enum DirectorAdaptiveGrid {
    /// Four columns at 760+, two at 420–759, one below 420.
    public static func columns(for width: CGFloat) -> Int {
        width >= 760 ? 4 : (width >= 420 ? 2 : 1)
    }

    public static func items(for width: CGFloat, spacing: CGFloat = DirectorSpacing.space3) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns(for: width))
    }
}
