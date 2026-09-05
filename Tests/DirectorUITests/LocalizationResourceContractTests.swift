import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

/// Resource contracts for Director-owned localization call sites.
final class LocalizationResourceContractTests: XCTestCase {
    private let languages = ["en", "zh-Hans"]

    func testLocalizedStringsHaveMatchingUniqueKeysAndPlaceholders() throws {
        var parsed: [String: [String: String]] = [:]
        for language in languages {
            let entries = try stringEntries(for: language)
            parsed[language] = entries.values
            XCTAssertTrue(entries.duplicates.isEmpty, "Duplicate .strings keys in \(language): \(entries.duplicates)")
        }
        XCTAssertEqual(Set(parsed["en"]!.keys), Set(parsed["zh-Hans"]!.keys))
        for key in parsed["en"]!.keys {
            XCTAssertEqual(placeholderSignature(in: parsed["en"]![key]!), placeholderSignature(in: parsed["zh-Hans"]![key]!), "Placeholder mismatch: \(key)")
        }
    }

    func testStringsDictHasMatchingKeysAndRequiredPluralEntries() throws {
        var keys: [String: Set<String>] = [:]
        for language in languages {
            let url = resourceURL(language: language, name: "Localizable.stringsdict")
            keys[language] = pluralKeys(at: url)
        }
        XCTAssertEqual(keys["en"], keys["zh-Hans"])
        let englishPlaceholders = pluralPlaceholders(language: "en")
        let chinesePlaceholders = pluralPlaceholders(language: "zh-Hans")
        XCTAssertEqual(Set(englishPlaceholders.keys), Set(chinesePlaceholders.keys))
        for key in englishPlaceholders.keys {
            let sharedCategories = Set(englishPlaceholders[key]!.keys).intersection(chinesePlaceholders[key]!.keys)
            for category in sharedCategories {
                XCTAssertEqual(
                    englishPlaceholders[key]![category],
                    chinesePlaceholders[key]![category],
                    "Plural placeholder mismatch: \(key) [\(category)]"
                )
            }
        }
        for key in ["task.rawCallCount", "task.callCount", "task.failureCount", "review.errorCount", "review.warningCount", "review.infoCount", "review.parserCoverageNotices", "data.sessionCount"] {
            XCTAssertTrue(keys["en"]!.contains(key), "Missing plural resource: \(key)")
        }
    }

    func testOwnedCallsiteLiteralKeysExistInBothLocales() throws {
        let source = try productionSourceFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let keys = callsiteKeys(in: source)
        for language in languages {
            let resourceKeys = Set(try stringEntries(for: language).values.keys)
            let pluralKeys = pluralKeys(at: resourceURL(language: language, name: "Localizable.stringsdict"))
            let missing = keys.subtracting(resourceKeys).subtracting(pluralKeys)
            XCTAssertTrue(missing.isEmpty, "Missing \(language) callsite keys: \(missing.sorted())")
        }
    }

    func testEnumDescriptorKeysExistInBothLocales() throws {
        var keys = TimelineMode.allCases.map { "timeline.mode.\($0.rawValue)" }
        keys += InvocationKind.allCases.map { "invocation.kind.\($0.rawValue)" }
        keys += InvocationStatus.allCases.map { "status.\($0.rawValue)" }
        keys += EvidenceConfidence.allCases.map { "confidence.\($0.rawValue)" }
        keys += InvocationEvaluationLabel.allCases.map { "evaluation.\($0.rawValue)" }
        keys += ReviewSeverity.allCases.map { "review.severity.\($0.rawValue)" }
        keys += CoverageState.allCases.map { "coverage.\($0.rawValue)" }
        keys += RemediationStatus.allCases.map { "remediation.\($0.rawValue)" }
        keys += ResourceKind.allCases.map { "enum.\($0.rawValue)" }
        keys += ResourceScope.allCases.map { "enum.\($0.rawValue)" }
        keys += ResourceOwnership.allCases.map { "enum.\($0.rawValue)" }
        keys += ResourceOrigin.allCases.map { "enum.\($0.rawValue)" }
        keys += RuntimeStatus.allCases.map { "status.\($0.rawValue)" }
        let indexingPhases: [IndexingProgress.Phase] = [.idle, .scanning, .parsing, .committing, .completed, .cancelled]
        keys += indexingPhases.map { "indexing.phase.\($0.rawValue)" }
        keys += ["relation.kind.uses", "relation.kind.invokes", "relation.kind.contains"]
        keys += ["source.category.skills", "source.category.agents", "source.category.plugins", "source.category.projects"]
        for language in languages {
            let resourceKeys = Set(try stringEntries(for: language).values.keys)
            let missing = Set(keys).subtracting(resourceKeys)
            XCTAssertTrue(missing.isEmpty, "Missing \(language) descriptor keys: \(missing.sorted())")
        }
    }

    func testPlaceholderScannerHandlesPrecisionWidthPositionsAndEscapes() {
        let positional = placeholderSignature(in: "%2$@ %1$lld %4$.1f %3$08.2f %%")
        let sequential = placeholderSignature(in: "%lld %@ %.1f %08.2f")

        XCTAssertEqual(positional, [1: "integer", 2: "object", 3: "floating", 4: "floating"])
        XCTAssertEqual(sequential, positional)
        XCTAssertNotEqual(placeholderSignature(in: "%lld %@"), placeholderSignature(in: "%@ %lld"))
    }

    private func productionSourceFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directories = [root.appendingPathComponent("Sources/DirectorUI"), root.appendingPathComponent("Sources/CodexDirectorApp")]
        return directories.flatMap { directory in
            (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? [])
                .filter { url in
                    guard url.pathExtension == "swift" else { return false }
                    let components = url.pathComponents
                    return !components.contains("Localization") && !components.contains("Validation") && !components.contains("Fixtures")
                }
        }
    }

    private func resourceURL(language: String, name: String) -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("Sources/DirectorUI/Resources/\(language).lproj/\(name)")
    }

    private func stringEntries(for language: String) throws -> (values: [String: String], duplicates: [String]) {
        let content = try String(contentsOf: resourceURL(language: language, name: "Localizable.strings"), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: "^\\s*\"((?:\\\\.|[^\"])*)\"\\s*=\\s*\"((?:\\\\.|[^\"])*)\"\\s*;", options: .anchorsMatchLines)
        var values: [String: String] = [:]
        var duplicates: [String] = []
        for match in expression.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
            guard let keyRange = Range(match.range(at: 1), in: content), let valueRange = Range(match.range(at: 2), in: content) else { continue }
            let key = String(content[keyRange])
            if values[key] != nil { duplicates.append(key) }
            values[key] = String(content[valueRange])
        }
        return (values, duplicates)
    }

    private func callsiteKeys(in source: String) -> Set<String> {
        // Match only the localization/display helpers owned by DirectorUI. A generic
        // `key:` matcher would also collect unrelated parser/configuration literals.
        let patterns = [
            "\\b(?:t|text|format|plural|copy|section|sectionTitle|TableColumn|Picker)\\(\\s*\"([^\"]+)\""
        ]
        // These are intentionally fixed language-choice labels, not localizable UI copy.
        let fixedLanguageOptions: Set<String> = ["简体中文", "English", "语言 / Language"]
        var result = Set<String>()
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) {
                    let key = String(source[range])
                    if !key.contains("\\(") && !fixedLanguageOptions.contains(key) { result.insert(key) }
                }
            }
        }
        return result
    }

    /// Returns argument-index to printf argument type. Non-positional
    /// arguments receive indices in encounter order; positional arguments
    /// are therefore safely reorderable across locales. `%%` is a literal
    /// percent and intentionally does not consume an argument.
    private func placeholderSignature(in value: String) -> [Int: String] {
        let characters = Array(value)
        var arguments: [Int: String] = [:]
        var nextImplicitIndex = 1
        var cursor = 0

        func assign(_ index: Int, _ type: String) {
            if let existing = arguments[index], existing != type {
                arguments[index] = "invalid"
            } else {
                arguments[index] = type
            }
        }

        func conversionType(_ conversion: Character) -> String? {
            switch conversion {
            case "@": return "object"
            case "d", "i", "o", "u", "x", "X": return "integer"
            case "a", "A", "e", "E", "f", "F", "g", "G": return "floating"
            case "c", "C": return "character"
            case "s", "S": return "string"
            case "p": return "pointer"
            default: return nil
            }
        }

        while cursor < characters.count {
            guard characters[cursor] == "%" else {
                cursor += 1
                continue
            }
            guard cursor + 1 < characters.count else { break }
            if characters[cursor + 1] == "%" {
                cursor += 2
                continue
            }

            var index = cursor + 1
            var explicitArgumentIndex: Int?
            let possibleIndexStart = index
            while index < characters.count, characters[index].isNumber { index += 1 }
            if index > possibleIndexStart, index < characters.count, characters[index] == "$" {
                explicitArgumentIndex = Int(String(characters[possibleIndexStart..<index]))
                index += 1
            } else {
                index = possibleIndexStart
            }

            // Flags, width, precision, and length are syntax, not types.
            while index < characters.count, "-+ #0'".contains(characters[index]) { index += 1 }
            if index < characters.count, characters[index] == "*" {
                index += 1
                let widthIndexStart = index
                while index < characters.count, characters[index].isNumber { index += 1 }
                if index > widthIndexStart, index < characters.count, characters[index] == "$" {
                    assign(Int(String(characters[widthIndexStart..<index])) ?? nextImplicitIndex, "integer")
                    index += 1
                } else {
                    assign(nextImplicitIndex, "integer")
                    nextImplicitIndex += 1
                }
            } else {
                while index < characters.count, characters[index].isNumber { index += 1 }
            }
            if index < characters.count, characters[index] == "." {
                index += 1
                if index < characters.count, characters[index] == "*" {
                    index += 1
                    let precisionIndexStart = index
                    while index < characters.count, characters[index].isNumber { index += 1 }
                    if index > precisionIndexStart, index < characters.count, characters[index] == "$" {
                        assign(Int(String(characters[precisionIndexStart..<index])) ?? nextImplicitIndex, "integer")
                        index += 1
                    } else {
                        assign(nextImplicitIndex, "integer")
                        nextImplicitIndex += 1
                    }
                } else {
                    while index < characters.count, characters[index].isNumber { index += 1 }
                }
            }
            while index < characters.count, "hljztL".contains(characters[index]) { index += 1 }
            guard index < characters.count, let type = conversionType(characters[index]) else {
                cursor = max(index + 1, cursor + 1)
                continue
            }

            let argumentIndex = explicitArgumentIndex ?? nextImplicitIndex
            assign(argumentIndex, type)
            if explicitArgumentIndex == nil { nextImplicitIndex += 1 }
            cursor = index + 1
        }
        return arguments
    }

    private func pluralPlaceholders(language: String) -> [String: [String: [Int: String]]] {
        guard let dictionary = NSDictionary(contentsOf: resourceURL(language: language, name: "Localizable.stringsdict")) as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [String: [String: [Int: String]]]()) { result, element in
            guard let entry = element.value as? [String: Any], let count = entry["count"] as? [String: Any] else { return }
            result[element.key] = count.reduce(into: [String: [Int: String]]()) { categories, categoryValue in
                guard categoryValue.key == "one" || categoryValue.key == "other", let string = categoryValue.value as? String else { return }
                categories[categoryValue.key] = placeholderSignature(in: string)
            }
        }
    }

    private func pluralKeys(at url: URL) -> Set<String> {
        guard let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { return [] }
        return Set(dictionary.keys)
    }
}
