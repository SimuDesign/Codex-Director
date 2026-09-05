import Foundation
import SwiftUI

/// The two application-owned appearance choices.
///
/// Codex Director deliberately does not mirror or mutate the system
/// appearance. A missing or invalid preference resolves to Dark so the
/// product has one deterministic first-launch presentation.
public enum AppTheme: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case light
    case dark

    public var id: String { rawValue }

    public var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    public static func resolve(_ rawValue: String?) -> AppTheme {
        guard let rawValue, let theme = AppTheme(rawValue: rawValue) else {
            return .dark
        }
        return theme
    }
}

/// Shared app-level appearance state.
///
/// Production uses one dedicated UserDefaults key. Memory and closure-backed
/// initializers keep tests and the Debug validation host isolated from the
/// user's real preferences.
@MainActor
public final class AppThemeStore: ObservableObject {
    public static let preferenceKey = "com.peiweitang.CodexDirector.theme"

    @Published public private(set) var theme: AppTheme

    private let writePreference: (String) -> Void

    public convenience init() {
        self.init(defaults: .standard)
    }

    public init(defaults: UserDefaults) {
        theme = AppTheme.resolve(defaults.string(forKey: Self.preferenceKey))
        writePreference = { rawValue in
            defaults.set(rawValue, forKey: Self.preferenceKey)
        }
    }

    public init(memoryTheme: AppTheme = .dark) {
        theme = memoryTheme
        writePreference = { _ in }
    }

    public init(readPreference: @escaping () -> String?, writePreference: @escaping (String) -> Void) {
        theme = AppTheme.resolve(readPreference())
        self.writePreference = writePreference
    }

    public func setTheme(_ theme: AppTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        writePreference(theme.rawValue)
    }

    public func setTheme(rawValue: String?) {
        setTheme(AppTheme.resolve(rawValue))
    }
}
