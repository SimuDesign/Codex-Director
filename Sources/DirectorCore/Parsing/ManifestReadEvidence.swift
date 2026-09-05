import Foundation

/// A discovered manifest path used only while resolving one transient tool
/// input. Relative paths are matched as complete path arguments; absolute
/// paths are matched only against a known scan-root-derived path.
struct ManifestReadCandidate: Sendable {
    let key: String
    let relativePath: String
    let absolutePath: String?
}

/// Shared, conservative read evidence parser for Agent and Skill manifests.
/// It intentionally rejects shell composition and mutation syntax: a false
/// negative is safer than attributing a capability from a mixed command.
enum ManifestReadEvidence {
    private static let directReadTools: Set<String> = ["read", "cat", "less", "more", "head", "tail", "wc", "open", "file", "mdcat"]
    private static let shellTools: Set<String> = ["exec_command", "bash", "shell", "sh", "zsh"]

    static func matchingCandidateKeys(
        input: String,
        toolName: String?,
        candidates: [ManifestReadCandidate]
    ) -> Set<String>? {
        guard let toolName, let pathArguments = readPathArguments(input: input, toolName: toolName) else {
            return nil
        }
        let normalizedArguments = Set(pathArguments.compactMap(normalizedPathToken))
        guard !normalizedArguments.isEmpty else { return nil }
        return Set(candidates.compactMap { candidate in
            let relative = normalizedPathToken(candidate.relativePath)
            let absolute = candidate.absolutePath.flatMap(normalizedPathToken)
            guard normalizedArguments.contains(where: { $0 == relative || ($0.hasPrefix("/") && $0 == absolute) }) else {
                return nil
            }
            return candidate.key
        })
    }

    private static func readPathArguments(input: String, toolName: String) -> [String]? {
        let command: String
        let isDirect = directReadTools.contains(toolName)
        if isDirect {
            command = input
        } else if shellTools.contains(toolName) {
            command = shellCommand(fromInput: input) ?? input
        } else {
            return nil
        }

        guard !containsUnsafeShellSyntax(command) else { return nil }
        let words = shellWords(command)
        guard !words.isEmpty else { return nil }
        if isDirect {
            // Direct read tools may receive either a complete command-like
            // input (`read path`) or just the path argument.
            return words
        }
        guard isReadExecutable(words) else { return nil }
        return Array(words.dropFirst())
    }

    private static func isReadExecutable(_ words: [String]) -> Bool {
        guard let executable = words.first else { return false }
        if directReadTools.contains(executable) { return true }
        if executable == "sed" {
            let options = words.dropFirst().filter { $0.hasPrefix("-") }
            guard !options.contains(where: { $0 == "--in-place" || $0.hasPrefix("--in-place=") }) else {
                return false
            }
            // `-i`, `-i.bak`, and combinations such as `-ni` all enable
            // in-place mutation. Other long options (for example `--quiet`)
            // remain eligible for conservative read evidence.
            return !options.contains { option in
                !option.hasPrefix("--") && option.dropFirst().contains("i")
            }
        }
        return false
    }

    private static func containsUnsafeShellSyntax(_ command: String) -> Bool {
        var single = false
        var double = false
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            // Newlines begin another shell command, and an unquoted hash
            // starts a comment. Reject both so a manifest path in a later or
            // non-executing context cannot be mistaken for read evidence.
            if character == "\n" || character == "\r" {
                return true
            }
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if single {
                if character == "'" { single = false }
            } else if double {
                if character == "\"" { double = false }
            } else if character == "'" {
                single = true
            } else if character == "\"" {
                double = true
            } else if ";|&><`#".contains(character) {
                return true
            } else if character == "$", command.index(after: index) < command.endIndex,
                      command[command.index(after: index)] == "(" {
                return true
            }
            index = command.index(after: index)
        }
        return single || double || escaped
    }

    private static func normalizedPathToken(_ token: String) -> String? {
        var path = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty else { return nil }
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.contains("../") && path != ".." else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return path
    }

    /// Extracts the command from the exec harness input without retaining it.
    private static func shellCommand(fromInput input: String) -> String? {
        for key in ["command\":", "cmd\":", "command:", "cmd:"] {
            guard let marker = input.range(of: key) else { continue }
            var rest = input[marker.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
            guard let quote = rest.first, quote == "'" || quote == "\"" else { continue }
            rest = rest.dropFirst()
            var result = ""
            var index = rest.startIndex
            while index < rest.endIndex {
                let character = rest[index]
                if character == quote { break }
                if character == "\\", rest.index(after: index) < rest.endIndex {
                    index = rest.index(after: index)
                    result.append(rest[index])
                } else {
                    result.append(character)
                }
                index = rest.index(after: index)
            }
            if !result.isEmpty { return result }
        }
        return nil
    }

    /// Minimal shell tokenizer; operators are rejected separately before use.
    private static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var single = false
        var double = false
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if single {
                if character == "'" { single = false } else { current.append(character) }
            } else if double {
                if character == "\"" { double = false } else { current.append(character) }
            } else if character == "'" {
                single = true
            } else if character == "\"" {
                double = true
            } else if character == " " || character == "\t" || character == "\n" {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
            index = command.index(after: index)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
