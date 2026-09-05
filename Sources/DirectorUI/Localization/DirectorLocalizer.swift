import Foundation

/// Single presentation localization boundary for Director-owned copy.
/// Resource names, source text, IDs, paths, and raw evidence bypass this type.
public struct DirectorLocalizer {
    public let language: AppLanguage
    public let locale: Locale

    private let bundle: Bundle

    public init(language: AppLanguage) {
        self.init(language: language, bundle: .module)
    }

    public init(language: AppLanguage, bundle: Bundle) {
        self.language = language
        locale = language.locale
        self.bundle = bundle
    }

    public func text(_ key: String, fallback: String) -> String {
        let localized = localizedBundle?.localizedString(forKey: key, value: nil, table: "Localizable") ?? key
        return localized == key ? fallback : localized
    }

    public func text(_ key: String) -> String {
        text(key, fallback: key)
    }

    public func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        format(key, fallback: fallback, arguments: arguments)
    }

    /// Array overload keeps view helper wrappers from passing an entire
    /// CVarArg array as a single format argument.
    public func format(_ key: String, fallback: String, arguments: [CVarArg]) -> String {
        let template = text(key, fallback: fallback)
        return String(format: template, locale: locale, arguments: arguments)
    }

    public func plural(_ key: String, count: Int, fallback: String) -> String {
        let template = localizedBundle?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback
        let formatted = String(format: template, locale: locale, arguments: [Int64(count)])
        // A malformed/incomplete bundle can expose the stringsdict selector
        // literally. Keep the API safe and deterministic by formatting the
        // caller's source fallback rather than leaking Foundation syntax.
        if formatted.contains("%#@count@") {
            return String(format: fallback, locale: locale, arguments: [Int64(count)])
        }
        return formatted
    }

    public func date(_ date: Date, style: Date.FormatStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)) -> String {
        date.formatted(style.locale(locale))
    }

    public func enumLabel(_ value: LocalizedEnumValue) -> String {
        text(value.key, fallback: value.fallback)
    }

    /// Returns presentation aliases while preserving the canonical searchable
    /// metadata. Callers should append these to raw names/IDs, not replace
    /// them.
    public func searchAliases(for key: String) -> [String] {
        let aliases = text("search.aliases.\(key)", fallback: "")
        return Array(Set(LocalizedSearch.aliases(for: key) + aliases.split(separator: "|").map(String.init)))
    }

    private var localizedBundle: Bundle? {
        for candidate in [language.rawValue, language.rawValue.lowercased()] {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let localizedBundle = Bundle(path: path) {
                return localizedBundle
            }
        }
        // Never fall through to the host's preferred language when a
        // requested localization directory is absent. English is the
        // deterministic source fallback for an incomplete bundle.
        return englishBundle
    }

    private var englishBundle: Bundle? {
        for candidate in [AppLanguage.english.rawValue, AppLanguage.english.rawValue.lowercased()] {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let englishBundle = Bundle(path: path) {
                return englishBundle
            }
        }
        return nil
    }

}
