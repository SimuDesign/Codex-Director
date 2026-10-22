import Foundation

/// A discovered manifest path used only while resolving one transient tool
/// input. Relative paths are matched as complete path arguments; absolute
/// paths are matched only against a known scan-root-derived path.
struct ManifestReadCandidate: Sendable {
    let key: String
    let relativePath: String
    let absolutePath: String?
    var projectID: String? = nil
}

/// Shared, conservative read evidence parser for Agent and Skill manifests.
/// Allows unconditional read-only sequences, rejecting conditional or mixed
/// mutation syntax. False negatives are safer than invented use evidence.
enum ManifestReadEvidence {
    private static let directReadTools: Set<String> = ["read", "read_file", "read_text_file", "cat", "less", "more", "head", "tail", "mdcat"]
    private static let shellTools: Set<String> = ["exec_command", "bash", "shell", "sh", "zsh"]

    static func matchingCandidateKeys(
        input: String,
        toolName: String?,
        candidates: [ManifestReadCandidate],
        projectID: String? = nil,
        workingDirectory: String? = nil
    ) -> Set<String>? {
        guard let toolName, let pathArguments = readPathArguments(input: input, toolName: toolName) else {
            return nil
        }
        let normalizedArguments = Set(pathArguments.compactMap(normalizedPathToken))
        guard !normalizedArguments.isEmpty else { return nil }
        let explicitWorkdir = TransientToolInput.arguments(input)?["workdir"] as? String
        let directory = explicitWorkdir ?? workingDirectory
        var keys = Set<String>()
        for argument in normalizedArguments {
            let full = argument.hasPrefix("/") ? argument : directory.flatMap { dir in
                dir.hasPrefix("/") ? URL(fileURLWithPath: dir).appendingPathComponent(argument).standardizedFileURL.path : nil
            }
            let absoluteMatches = full.map { full in candidates.filter { $0.absolutePath.flatMap(normalizedPathToken) == full } } ?? []
            let matches: [ManifestReadCandidate]
            if !absoluteMatches.isEmpty || argument.hasPrefix("/") || directory != nil {
                matches = absoluteMatches
            } else {
                let relative = candidates.filter { normalizedPathToken($0.relativePath) == argument }
                // Without project context, a relative collision stays
                // ambiguous instead of silently choosing the global copy.
                if let projectID {
                    let local = relative.filter { $0.projectID == projectID }
                    matches = local.isEmpty ? relative.filter { $0.projectID == nil } : local
                } else { matches = relative }
            }
            let ids = Set(matches.map(\.key))
            if ids.count == 1 { keys.formUnion(ids) }
        }
        return keys
    }

    private static func readPathArguments(input: String, toolName: String) -> [String]? {
        let command: String
        let isDirect = directReadTools.contains(toolName)
        if isDirect {
            if let arguments = TransientToolInput.arguments(input) {
                guard let path = (arguments["path"] ?? arguments["file_path"]) as? String else { return nil }
                return [path]
            }
            command = input
        } else if shellTools.contains(toolName) {
            if let arguments = TransientToolInput.arguments(input) {
                guard arguments["workdir"] == nil || arguments["workdir"] is String else { return nil }
                guard let value = (arguments["cmd"] ?? arguments["command"]) as? String else { return nil }
                command = value
            } else { command = shellCommand(fromInput: input) ?? input }
        } else {
            return nil
        }

        guard command.utf8.count <= 262_144, let segments = readSegments(command) else { return nil }
        let groups = segments.map(shellWords)
        guard groups.allSatisfy({ !$0.isEmpty }) else { return nil }
        if isDirect {
            // Direct read tools may receive either a complete command-like
            // input (`read path`) or just the path argument.
            return groups.flatMap { $0 }
        }
        guard groups.allSatisfy(isReadExecutable) else { return nil }
        for words in groups where words.first == "sed" {
            let operands = words.dropFirst().filter { !$0.hasPrefix("-") }
            guard let program = operands.first,
                  program.range(of: #"^(\d+|\$)(,(\d+|\$))?p$"#, options: .regularExpression) != nil else { return nil }
        }
        return groups.flatMap { $0.dropFirst() }
    }

    /// Accept only unconditional sequences of read-only commands. `&&` and
    /// `||` remain excluded: a later read might never have executed.
    private static func readSegments(_ command: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil }
                // Substitution executes even inside double quotes.
                if active == "\"", character == "$" || character == "`" { return nil }
                current.append(character); continue
            }
            if character == "'" || character == "\"" { quote = character; current.append(character); continue }
            if "|&><`#$(){}".contains(character) { return nil }
            if character == ";" || character == "\n" || character == "\r" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current); current = "" }
            } else { current.append(character) }
        }
        guard quote == nil, !escaped else { return nil }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result.isEmpty || result.count > 64 ? nil : result
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
