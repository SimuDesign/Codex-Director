import Foundation

/// A deliberately small, bounded static adapter, not a JavaScript evaluator.
/// Strings, comments and dynamic/control-flow expressions are never evidence.
enum TransientToolInput {
    struct Call {
        let name: String
        let input: String
    }

    private struct Token {
        let value: String
        let literal: Bool
    }

    static func arguments(_ input: String) -> [String: Any]? {
        guard input.utf8.count <= 262_144, let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func normalizedName(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    static func literalCalls(_ input: String) -> [Call]? {
        guard input.utf8.count <= 262_144, let tokens = tokenize(input), tokens.count <= 32_768 else { return nil }
        let forbidden: Set<String> = ["if", "else", "for", "while", "switch", "function", "class", "try", "catch", "return", "throw", "exit", "eval", "yield_control", "?", "&&", "||", "=>", "/"]
        guard !tokens.contains(where: { !$0.literal && forbidden.contains($0.value) }) else { return nil }
        var calls: [Call] = []
        var index = 0
        var blockDepth = 0
        while index + 4 < tokens.count {
            guard !tokens[index].literal, tokens[index].value == "tools", tokens[index + 1].value == ".",
                  !tokens[index + 2].literal, tokens[index + 3].value == "(", tokens[index + 4].value == "{" else {
                if !tokens[index].literal {
                    if tokens[index].value == "{" { blockDepth += 1 }
                    if tokens[index].value == "}" { blockDepth -= 1 }
                }
                index += 1; continue
            }
            guard blockDepth == 0 else { return nil }
            // Nested/dynamic argument objects are not interpreted. Scalar
            // numeric/boolean options are tolerated but never retained.
            let name = tokens[index + 2].value
            var cursor = index + 5
            var fields: [String: String] = [:]
            var invalid = false
            while cursor < tokens.count, tokens[cursor].value != "}" {
                guard cursor + 2 < tokens.count, tokens[cursor + 1].value == ":" else { invalid = true; break }
                let key = tokens[cursor].value
                let value = tokens[cursor + 2]
                guard !["{", "[", "(", "tools"].contains(value.value), cursor + 3 < tokens.count,
                      [",", "}"].contains(tokens[cursor + 3].value) else { invalid = true; break }
                if value.literal {
                    guard fields[key] == nil else { return nil }
                    fields[key] = value.value
                }
                else if ["cmd", "command", "workdir", "path", "file_path", "agent_type"].contains(key) { invalid = true; break }
                cursor += 3
                if tokens[cursor].value == "," { cursor += 1 }
            }
            guard !invalid, cursor + 1 < tokens.count, tokens[cursor].value == "}", tokens[cursor + 1].value == ")" else { return nil }
            guard calls.count < 64, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
            calls.append(Call(name: name, input: String(decoding: data, as: UTF8.self)))
            index = cursor + 2
        }
        return calls
    }

    private static func tokenize(_ input: String) -> [Token]? {
        let chars = Array(input)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace { index += 1; continue }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                index += 2
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                guard index + 1 < chars.count else { return nil }
                index += 2; continue
            }
            // Template strings may interpolate code; do not evaluate them.
            if c == "`" { return nil }
            if c == "\"" || c == "'" {
                let quote = c
                var value = ""
                index += 1
                var closed = false
                while index < chars.count {
                    let current = chars[index]
                    if current == quote { closed = true; index += 1; break }
                    if current == "\\" {
                        index += 1
                        guard index < chars.count else { return nil }
                        switch chars[index] {
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        case "\\", "'", "\"": value.append(chars[index])
                        default: return nil
                        }
                    } else { value.append(current) }
                    index += 1
                }
                guard closed else { return nil }
                tokens.append(Token(value: value, literal: true)); continue
            }
            if c.isLetter || c.isNumber || c == "_" || c == "$" {
                let start = index
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" || chars[index] == "$" { index += 1 }
                tokens.append(Token(value: String(chars[start..<index]), literal: false)); continue
            }
            let pair = index + 1 < chars.count ? String(chars[index...index + 1]) : ""
            if ["&&", "||", "=>"].contains(pair) {
                tokens.append(Token(value: pair, literal: false)); index += 2
            } else { tokens.append(Token(value: String(c), literal: false)); index += 1 }
        }
        return tokens
    }
}
