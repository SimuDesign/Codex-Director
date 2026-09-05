import SwiftUI

/// Shared manual-refresh control used by the global toolbar and Settings.
/// Both labels stay in the layout so the control does not jump in width when
/// the scheduler enters or leaves an active source/projection phase.
public struct DirectorRefreshButton: View {
    private let label: String
    private let runningLabel: String
    private let hint: String
    private let isRefreshing: Bool
    private let isAvailable: Bool
    private let size: DirectorPrimaryActionButtonSize
    private let action: () -> Void

    public init(
        label: String,
        runningLabel: String,
        hint: String,
        isRefreshing: Bool,
        isAvailable: Bool,
        size: DirectorPrimaryActionButtonSize = .standard,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.runningLabel = runningLabel
        self.hint = hint
        self.isRefreshing = isRefreshing
        self.isAvailable = isAvailable
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Label(label, systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .opacity(isRefreshing ? 0 : 1)
                    .accessibilityHidden(isRefreshing)

                HStack(spacing: DirectorSpacing.space2) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(size == .toolbar ? .small : .regular)
                        .tint(DirectorColor.primaryActionForeground)
                        .accessibilityHidden(true)
                    Text(runningLabel)
                }
                .opacity(isRefreshing ? 1 : 0)
                .accessibilityHidden(!isRefreshing)
            }
            .fixedSize()
        }
        .buttonStyle(DirectorPrimaryActionButtonStyle(size: size, isProcessing: isRefreshing))
        .disabled(isRefreshing || !isAvailable)
        .accessibilityLabel(isRefreshing ? runningLabel : label)
        .accessibilityHint(hint)
        .help(isRefreshing ? runningLabel : hint)
    }
}
