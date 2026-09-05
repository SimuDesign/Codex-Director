import SwiftUI
import DirectorCore

/// First run: explains local-only, read-only behavior before indexing.
public struct FirstRunView: View {
    public let message: String
    public let canIndex: Bool
    public let isIndexing: Bool
    public let progress: IndexingProgress
    public let startAction: () -> Void
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(
        message: String,
        canIndex: Bool,
        isIndexing: Bool,
        progress: IndexingProgress = .initial,
        startAction: @escaping () -> Void
    ) {
        self.message = message
        self.canIndex = canIndex
        self.isIndexing = isIndexing
        self.progress = progress
        self.startAction = startAction
    }

    public var body: some View {
        VStack(spacing: DirectorSpacing.space6) {
            Image(systemName: "cylinder.split.1x2")
                .font(.largeTitle)
                .foregroundStyle(DirectorColor.accent)
            Text(text("Welcome to Codex Director"))
                .font(DirectorTypography.windowTitle)
            Text(text(message))
                .font(DirectorTypography.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .foregroundStyle(DirectorColor.textSecondary)

            HStack(spacing: DirectorSpacing.space4) {
                Label(text("Local only"), systemImage: "desktopcomputer")
                Label(text("Read-only sources"), systemImage: "eye.slash")
                Label(text("Metadata only"), systemImage: "doc.text.magnifyingglass")
            }
            .font(DirectorTypography.supporting)
            .foregroundStyle(DirectorColor.textSecondary)

            if isIndexing {
                if let bytesRead = progress.currentFileBytesRead, let fileTotal = progress.currentFileTotalBytes {
                    ProgressView(value: Double(bytesRead), total: Double(max(fileTotal, 1)))
                        .progressViewStyle(.linear)
                        .padding(.top, DirectorSpacing.space3)
                } else {
                    ProgressView(text("Indexing…"))
                        .padding(.top, DirectorSpacing.space3)
                }
            } else {
                Button(action: startAction) {
                    Label(text("Start indexing"), systemImage: "play.fill")
                }
                .disabled(!canIndex)
                .help(text(canIndex ? "Index resources and Session logs" : "The derived database is unavailable"))
                .padding(.top, DirectorSpacing.space3)
            }
        }
        .padding(DirectorSpacing.space10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func text(_ key: String) -> String {
        languageStore.localizer.text(key, fallback: key)
    }
}
