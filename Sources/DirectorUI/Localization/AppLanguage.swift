import Foundation
import SwiftUI

/// The two presentation languages supported by Director. Raw values are
/// stable preference values and must not be used to translate stored data.
public enum AppLanguage: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var pickerTitle: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    public static func resolve(_ rawValue: String?) -> AppLanguage {
        guard let rawValue, let language = AppLanguage(rawValue: rawValue) else {
            return .simplifiedChinese
        }
        return language
    }
}

/// Presentation-localized enum input. The fallback is an English source
/// label; it is never a persisted enum value or a user-authored string.
public struct LocalizedEnumValue: Hashable, Sendable {
    public let key: String
    public let fallback: String

    public init(key: String, fallback: String) {
        self.key = key
        self.fallback = fallback
    }
}

/// Shared app-level language state. The production initializer is the only
/// initializer that touches UserDefaults; memory and closure initializers are
/// intentionally suitable for previews and isolated validation sessions.
@MainActor
public final class AppLanguageStore: ObservableObject {
    public static let preferenceKey = "com.peiweitang.CodexDirector.language"

    @Published public private(set) var language: AppLanguage

    private let writePreference: (String) -> Void

    public var locale: Locale { language.locale }
    public var localizer: DirectorLocalizer { DirectorLocalizer(language: language) }

    /// Production storage. This dedicated key does not alter AppleLanguages
    /// or any other system/global preference.
    public convenience init() {
        self.init(defaults: .standard)
    }

    public init(defaults: UserDefaults) {
        language = AppLanguage.resolve(defaults.string(forKey: Self.preferenceKey))
        writePreference = { rawValue in
            defaults.set(rawValue, forKey: Self.preferenceKey)
        }
    }

    /// Pure-memory construction for previews, tests, and the debug validation
    /// host. It does not instantiate or consult a UserDefaults domain.
    public init(memoryLanguage: AppLanguage) {
        language = memoryLanguage
        writePreference = { _ in }
    }

    /// Injected persistence seam for isolated tests. The closures are the
    /// complete storage boundary and may be backed by memory only.
    public init(readPreference: @escaping () -> String?, writePreference: @escaping (String) -> Void) {
        language = AppLanguage.resolve(readPreference())
        self.writePreference = writePreference
    }

    public func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        writePreference(language.rawValue)
    }

    public func setLanguage(rawValue: String?) {
        setLanguage(AppLanguage.resolve(rawValue))
    }
}
