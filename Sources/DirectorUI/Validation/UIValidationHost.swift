#if DEBUG
import SwiftUI
import AppKit

/// Pure sizing rules for the Debug validation host.
///
/// The host window includes validation controls in its normal mode, but the
/// requested product viewport must be measured independently from those
/// controls when capture mode is active. Keeping this calculation outside the
/// view makes the contract deterministic and testable without relying on a
/// scheduling turn or a live window.
enum UIValidationCaptureLayout {
    static let dividerHeight: CGFloat = 1

    static func windowContentSize(
        productSize: CGSize,
        controlsHeight: CGFloat,
        showsControls: Bool,
        dividerHeight: CGFloat = Self.dividerHeight
    ) -> CGSize {
        CGSize(
            width: productSize.width,
            height: productSize.height + (showsControls ? max(0, controlsHeight) + max(0, dividerHeight) : 0)
        )
    }

    static func reportedProductViewportSize(
        requested: CGSize,
        measured: CGSize,
        captureMode: Bool
    ) -> CGSize {
        captureMode ? requested : measured
    }
}

/// Debug-only native host for testing the shipped workspace with synthetic data.
public struct UIValidationHost: View {
    public enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    @State private var session: UIValidationSession?
    @ObservedObject private var languageStore: AppLanguageStore
    @ObservedObject private var themeStore: AppThemeStore

    public init(
        languageStore: AppLanguageStore? = nil,
        themeStore: AppThemeStore? = nil
    ) {
        _session = State(initialValue: try? UIValidationSession())
        _languageStore = ObservedObject(wrappedValue: languageStore ?? AppLanguageStore(memoryLanguage: .simplifiedChinese))
        _themeStore = ObservedObject(wrappedValue: themeStore ?? AppThemeStore(memoryTheme: .dark))
    }

    public var body: some View {
        Group {
            if let session {
                ValidationWorkspace(
                    session: session,
                    languageStore: languageStore,
                    themeStore: themeStore
                )
            } else {
                VStack(spacing: DirectorSpacing.space4) {
                    Label("Synthetic validation unavailable", systemImage: "exclamationmark.triangle")
                        .font(DirectorTypography.sectionTitle)
                    Text("The temporary validation store could not be created.")
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSecondary)
                    Button("Retry") { session = try? UIValidationSession() }
                }
                .frame(minWidth: 720, minHeight: 480)
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct ValidationWorkspace: View {
    @ObservedObject var session: UIValidationSession
    @ObservedObject var languageStore: AppLanguageStore
    @ObservedObject var themeStore: AppThemeStore
    @State private var appearance: UIValidationHost.Appearance = .system
    @State private var window: NSWindow?
    @State private var controlsHeight: CGFloat = 0
    @State private var requestedProductSize = CGSize(width: 1280, height: 800)
    @State private var productViewportSize: CGSize = .zero
    @State private var isCaptureMode = false
    @State private var simulatesRefresh = false
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if !isCaptureMode {
                controls
                Divider()
            }
            productContent
        }
        .background(WindowReader { capturedWindow in
            updateWindowMetrics(for: capturedWindow)
            applyRequestedProductSize(to: capturedWindow)
        })
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(appearance == .system ? nil : (appearance == .light ? .light : .dark))
        .onExitCommand {
            if isCaptureMode { exitCaptureMode() }
        }
        .onChange(of: isCaptureMode) { _, _ in
            refreshWindowMetrics()
            applyRequestedProductSize()
        }
        .onChange(of: themeStore.theme) { _, theme in
            appearance = theme == .light ? .light : .dark
        }
        .onChange(of: simulatesRefresh) { _, value in
            session.model.isIndexing = value
        }
        .onChange(of: session.generation) { _, _ in
            simulatesRefresh = false
        }
        .task {
            do {
                try await session.prepare()
            } catch {
                // The status label below makes a failed synthetic seed
                // explicit without exposing a temporary filesystem path.
            }
            refreshWindowMetrics()
            applyRequestedProductSize()
        }
    }

    private var productContent: some View {
        DirectorRootView(model: session.model)
            .environmentObject(languageStore)
            .environmentObject(themeStore)
            .id(session.generation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onAppear { updateProductViewportSize(proxy.size) }
                        .onChange(of: proxy.size) { _, size in
                            updateProductViewportSize(size)
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if isCaptureMode {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Actual product viewport size")
                        .accessibilityValue(productViewportDescription)
                        .allowsHitTesting(false)
                }
            }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            HStack(alignment: .center, spacing: DirectorSpacing.space3) {
                Label("Synthetic Debug validation", systemImage: "ladybug")
                    .font(DirectorTypography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(session.hasError ? "Synthetic data unavailable" : (session.isReady ? "Synthetic data ready" : "Loading synthetic data…"))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .accessibilityValue(session.hasError ? "Unavailable" : (session.isReady ? "Ready" : "Loading"))
                if session.hasError {
                    Button("Retry") {
                        Task {
                            try? await session.prepare()
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retry synthetic validation")
                }
            }

            HStack(alignment: .center, spacing: DirectorSpacing.space3) {
                Picker("Language / 语言", selection: Binding(
                    get: { languageStore.language },
                    set: { languageStore.setLanguage($0) }
                )) {
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }
                .pickerStyle(.menu)

                Picker("Dataset", selection: Binding(
                    get: { session.dataset },
                    set: { value in Task { await session.reset(to: value) } }
                )) {
                    ForEach(UIValidationSession.Dataset.allCases) { dataset in
                        Text(dataset.title).tag(dataset)
                    }
                }
                .pickerStyle(.menu)

                Picker("Appearance", selection: $appearance) {
                    ForEach(UIValidationHost.Appearance.allCases) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.menu)

                Toggle("Refresh loading", isOn: $simulatesRefresh)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityHint("Preview the shared refresh button's native loading state without starting an operation.")

                Menu("Accessibility") {
                    Text("Contrast: \(systemContrast == .increased ? "Increased" : "Standard")")
                    Text("Transparency: \(systemReduceTransparency ? "Reduced" : "Standard")")
                    Text("Motion: \(systemReduceMotion ? "Reduced" : "Standard")")
                    Divider()
                    Text("Controlled by macOS; this host does not change system settings.")
                }
                .accessibilityLabel("Accessibility settings")
                .accessibilityValue(accessibilitySummary)

                Menu("Window Size") {
                    Button("Product viewport · 720 × 480") { setWindowSize(width: 720, height: 480) }
                    Button("Product viewport · 1280 × 800") { setWindowSize(width: 1280, height: 800) }
                    Button("Product viewport · 1600 × 1000") { setWindowSize(width: 1600, height: 1000) }
                }
                .accessibilityLabel("Validation window size")

                Button("Capture view") { enterCaptureMode() }
                    .accessibilityLabel("Capture product view")
                    .help("Hide validation controls and show the selected product viewport. Press Escape to restore controls.")

                Text(productViewportDescription)
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .accessibilityLabel("Actual product viewport size")
                    .accessibilityValue(productViewportDescription)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DirectorSpacing.space4)
        .padding(.vertical, DirectorSpacing.space3)
        .background(.bar)
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear { updateControlsHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in
                        updateControlsHeight(height)
                    }
            }
        }
    }

    private var accessibilitySummary: String {
        let contrast = systemContrast == .increased ? "Increased contrast" : "Standard contrast"
        let transparency = systemReduceTransparency ? "Reduced transparency" : "Standard transparency"
        let motion = systemReduceMotion ? "Reduced motion" : "Standard motion"
        return "\(contrast), \(transparency), \(motion)"
    }

    private func setWindowSize(width: CGFloat, height: CGFloat) {
        requestedProductSize = CGSize(width: width, height: height)
        refreshWindowMetrics()
        applyRequestedProductSize()
    }

    private func enterCaptureMode() {
        isCaptureMode = true
        productViewportSize = .zero
        applyRequestedProductSize(captureMode: true)
    }

    private func exitCaptureMode() {
        isCaptureMode = false
        productViewportSize = .zero
        applyRequestedProductSize(captureMode: false)
    }

    private func updateControlsHeight(_ height: CGFloat) {
        guard height > 0, abs(controlsHeight - height) > 0.5 else { return }
        controlsHeight = height
        applyRequestedProductSize()
    }

    private func updateProductViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, productViewportSize != size else { return }
        productViewportSize = size
    }

    private func applyRequestedProductSize(to targetWindow: NSWindow? = nil, captureMode: Bool? = nil) {
        guard let targetWindow = targetWindow ?? window else { return }
        let showingControls = !(captureMode ?? isCaptureMode)
        let desired = UIValidationCaptureLayout.windowContentSize(
            productSize: requestedProductSize,
            controlsHeight: controlsHeight,
            showsControls: showingControls
        )
        guard let current = targetWindow.contentView?.bounds.size,
              abs(current.width - desired.width) <= 0.5,
              abs(current.height - desired.height) <= 0.5 else {
            targetWindow.setContentSize(desired)
            return
        }
    }

    private func refreshWindowMetrics() {
        guard let window else { return }
        updateWindowMetrics(for: window)
    }

    private func updateWindowMetrics(for targetWindow: NSWindow) {
        window = targetWindow
        applyRequestedProductSize(to: targetWindow)
    }

    private var productViewportDescription: String {
        let reported = UIValidationCaptureLayout.reportedProductViewportSize(
            requested: requestedProductSize,
            measured: productViewportSize,
            captureMode: isCaptureMode
        )
        guard reported.width > 0, reported.height > 0 else {
            return "Product viewport measuring…"
        }
        return "Product \(Int(reported.width.rounded())) × \(Int(reported.height.rounded()))"
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { HostingView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HostingView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
#endif
