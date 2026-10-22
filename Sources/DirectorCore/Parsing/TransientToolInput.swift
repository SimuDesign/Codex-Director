import Foundation

/// A deliberately small, bounded static adapter, not a JavaScript evaluator.
/// Only literal tool calls in supported eager expression positions are
/// returned. Deferred callbacks, functions and uncertain control flow are not
/// execution evidence.
enum TransientToolInput {
    enum ResultBinding {
        case direct
        case aggregate
        case unbound
    }

    struct Call {
        let name: String
        let input: String
        let resultBinding: ResultBinding

        init(name: String, input: String, resultBinding: ResultBinding = .direct) {
            self.name = name
            self.input = input
            self.resultBinding = resultBinding
        }
    }

    struct Extraction {
        let calls: [Call]
        let wasLimited: Bool
    }

    private enum TokenKind {
        case identifier
        case string
        case punctuation
        case opaque
    }

    private struct Token {
        let value: String
        let kind: TokenKind
        let lineBreakBefore: Bool

        var isString: Bool { kind == .string }
        var isIdentifier: Bool { kind == .identifier }
    }

    private struct Tokenization {
        let tokens: [Token]
        let wasLimited: Bool
        let structurallyInvalid: Bool
    }

    private struct StatementDispatch {
        let tokens: [Token]
        let wasLimited: Bool
        let structurallyInvalid: Bool
    }

    private struct LiteralFieldParsing {
        let values: [String: String]?
        let wasLimited: Bool
        let structurallyInvalid: Bool
    }

    private enum StatementDecision {
        case supported
        case validBarrier
        case structurallyInvalid
    }

    private struct Delimiter {
        let value: String
        let aggregateResult: Bool
    }

    private static let maximumInputBytes = 262_144
    private static let maximumTokens = 32_768
    private static let maximumCalls = 64
    private static let maximumNesting = 64
    private static let evidenceKeys: Set<String> = [
        "cmd", "command", "workdir", "path", "file_path", "agent_type",
    ]
    private static let controlKeywords: Set<String> = [
        "if", "else", "for", "while", "switch", "try", "catch", "finally",
        "function", "class", "return", "throw", "delete", "with", "do",
    ]
    private static let supportedOutputCalls: Set<String> = [
        "text", "image", "audio", "generatedImage", "notify", "store",
    ]
    private static let protectedRuntimeNames: Set<String> =
        supportedOutputCalls.union(["tools", "ALL_TOOLS", "Promise"])
    private static let reservedIdentifierNames: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "enum", "export", "extends", "false",
        "finally", "for", "function", "if", "implements", "import", "in", "instanceof",
        "interface", "let", "new", "null", "package", "private", "protected", "public",
        "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof",
        "var", "void", "while", "with", "yield",
    ]
    private static let bindingForbiddenNames: Set<String> =
        reservedIdentifierNames.union(["arguments", "eval"])
    private static let assignmentOperators: Set<String> = [
        "=", "+=", "-=", "*=", "%=", "&=", "|=", "^=", "&&=", "||=", "??=",
        "<<=", ">>=", ">>>=", "**=",
    ]

    static func arguments(_ input: String) -> [String: Any]? {
        guard input.utf8.count <= maximumInputBytes, let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func normalizedName(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    /// Compatibility entry point retained for existing resolver tests. An
    /// empty array means no supported literal call was established.
    static func literalCalls(_ input: String) -> [Call]? {
        extractLiteralCalls(input).calls
    }

    /// Performs one bounded tokenization and one structural pass. Only a
    /// syntax-validated limited suffix may preserve calls proved by earlier
    /// eager expressions; malformed or unproved source rejects the wrapper.
    /// The diagnostic bit contains no source text.
    static func extractLiteralCalls(_ input: String) -> Extraction {
        #if canImport(Darwin)
        return autoreleasepool {
            extractLiteralCallsWithinPool(input)
        }
        #else
        return extractLiteralCallsWithinPool(input)
        #endif
    }

    private static func extractLiteralCallsWithinPool(_ input: String) -> Extraction {
        guard input.utf8.count <= maximumInputBytes else {
            return Extraction(calls: [], wasLimited: true)
        }

        let tokenization = tokenize(input)
        guard !tokenization.structurallyInvalid, !tokenization.wasLimited else {
            return Extraction(calls: [], wasLimited: true)
        }
        guard !tokenization.tokens.contains(where: { $0.value == "<template-expression>" }) else {
            // Interpolation bodies are intentionally opaque. Without parsing
            // them, their syntax cannot be proved, so the whole wrapper is
            // rejected rather than retaining a potentially impossible prefix.
            return Extraction(calls: [], wasLimited: true)
        }
        guard hasValidDelimiterStructure(tokenization.tokens) else {
            return Extraction(calls: [], wasLimited: true)
        }
        guard !containsProtectedRuntimeBindingDeclaration(tokenization.tokens) else {
            // A top-level lexical binding is in the temporal dead zone from
            // scope entry, while `var` is hoisted. Either can invalidate an
            // apparently earlier reference to the canonical runtime bridge.
            return Extraction(calls: [], wasLimited: true)
        }
        guard !containsStructurallyInvalidToolCall(tokenization.tokens) else {
            return Extraction(calls: [], wasLimited: true)
        }
        let dispatch = dispatchAllowlistedTopLevelPrefix(tokenization.tokens)
        guard !dispatch.structurallyInvalid else {
            return Extraction(calls: [], wasLimited: true)
        }
        let tokens = dispatch.tokens
        var calls: [Call] = []
        var wasLimited = tokenization.wasLimited || dispatch.wasLimited
        var delimiters: [Delimiter] = []
        let deferredParameterStarts = deferredArrowParameterStarts(tokens)
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            if deferredParameterStarts.contains(index) {
                return Extraction(calls: calls, wasLimited: true)
            }

            if token.value == ";", delimiters.isEmpty {
                index += 1
                continue
            }

            if controlKeywords.contains(token.value) || token.value == "=>" ||
                token.value == "&&" || token.value == "||" || token.value == "?" ||
                ["exit", "eval", "yield_control", "break", "continue"].contains(token.value) {
                return Extraction(calls: calls, wasLimited: true)
            }

            if isProtectedBindingOrReassignment(tokens, at: index) {
                return Extraction(calls: calls, wasLimited: true)
            }

            if isAllToolsCatalogOutputStart(tokens, at: index) {
                guard let catalogEnd = safeAllToolsCatalogOutputEnd(tokens, at: index) else {
                    // A near miss is not ordinary output: accepting only a
                    // prefix of malformed callback grammar could invent work
                    // from a wrapper that JavaScript would never execute.
                    return Extraction(calls: [], wasLimited: true)
                }
                // The catalog expression is allowlisted output-only work. It
                // is skipped rather than evaluated, and makes a later outer
                // result non-authoritative for individual operations.
                wasLimited = true
                index = catalogEnd
                continue
            }

            if token.value == "<template-expression>" ||
                (token.isIdentifier && index + 1 < tokens.count &&
                    ["<template>", "<template-expression>"].contains(tokens[index + 1].value)) {
                // Template interpolation and tagged templates are eager
                // execution. The recognizer deliberately does not interpret
                // their JavaScript; retain only proof established before it.
                return Extraction(calls: calls, wasLimited: true)
            }

            if isUnsupportedAwait(tokens, at: index) || isUnsupportedCall(tokens, at: index) {
                return Extraction(calls: calls, wasLimited: true)
            }

            if !delimiters.contains(where: { $0.value == "{" }),
               isToolCallStart(tokens, at: index) {
                let aggregateResult = delimiters.contains(where: \.aggregateResult)
                let resultBinding: ResultBinding = aggregateResult
                    ? .aggregate
                    : (index > 0 && tokens[index - 1].value == "await" ? .direct : .unbound)
                let parsed = parseCall(tokens, at: index, resultBinding: resultBinding)
                if parsed.structurallyInvalid {
                    return Extraction(calls: [], wasLimited: true)
                }
                if let call = parsed.call {
                    if calls.count == maximumCalls {
                        wasLimited = true
                        break
                    }
                    calls.append(call)
                } else {
                    // This is an eager tools call, but its identity-bearing
                    // arguments were not literal. Preserve earlier proof and
                    // stop before guessing calls that might not be reached.
                    return Extraction(calls: calls, wasLimited: true)
                }
                if parsed.wasLimited { wasLimited = true }
                if let endIndex = parsed.endIndex {
                    index = endIndex
                    continue
                }
            }

            switch token.value {
            case "(", "[", "{":
                guard delimiters.count < maximumNesting else {
                    return Extraction(calls: [], wasLimited: true)
                }
                let aggregate = token.value == "(" && isPromiseAggregateOpen(tokens, at: index)
                delimiters.append(Delimiter(value: token.value, aggregateResult: aggregate || delimiters.contains(where: \.aggregateResult)))
            case ")", "]", "}":
                guard let expected = openingDelimiter(for: token.value), delimiters.last?.value == expected else {
                    return Extraction(calls: [], wasLimited: true)
                }
                delimiters.removeLast()
            default:
                break
            }
            index += 1
        }

        if !delimiters.isEmpty { return Extraction(calls: [], wasLimited: true) }
        return Extraction(calls: calls, wasLimited: wasLimited)
    }

    /// Splits only at top-level semicolons and admits a deliberately small set
    /// of eager statement shapes. A second finite grammar recognizes valid
    /// execution barriers whose reachability is unknown. Anything outside
    /// both grammars is rejected as structurally unproved, so malformed source
    /// cannot preserve an apparent prefix from JavaScript that would not run.
    private static func dispatchAllowlistedTopLevelPrefix(_ tokens: [Token]) -> StatementDispatch {
        var stack: [String] = []
        var statementStart = 0
        var index = 0
        var firstBarrierStart: Int?
        var topLevelBindings: [String: Bool] = [:]

        func decision(for range: Range<Int>) -> StatementDecision {
            guard !range.isEmpty else { return .supported }
            if isAllToolsCatalogOutputStart(tokens, at: range.lowerBound) {
                guard let end = safeAllToolsCatalogOutputEnd(tokens, at: range.lowerBound),
                      end == range.upperBound else { return .structurallyInvalid }
                return .supported
            }
            if isStaticLiteralExpression(tokens, range: range) ||
                isExactToolExpression(tokens, range: range) ||
                isExactPromiseAggregateExpression(tokens, range: range) ||
                isExactLiteralOutputExpression(tokens, range: range) {
                return .supported
            }
            if range.count >= 4, tokens[range.lowerBound].value == "const",
               isBindingIdentifier(tokens[range.lowerBound + 1]),
               tokens[range.lowerBound + 2].value == "=" {
                let valueRange = (range.lowerBound + 3)..<range.upperBound
                if isStaticLiteralExpression(tokens, range: valueRange) ||
                    isExactToolExpression(tokens, range: valueRange) ||
                    isExactPromiseAggregateExpression(tokens, range: valueRange) {
                    return .supported
                }
            }
            return isSyntacticallyValidBarrier(tokens, range: range)
                ? .validBarrier : .structurallyInvalid
        }

        func finish(_ end: Int) -> StatementDispatch? {
            let range = statementStart..<end
            if range.count >= 2,
               ["const", "let", "var"].contains(tokens[range.lowerBound].value),
               isBindingIdentifier(tokens[range.lowerBound + 1]) {
                let name = tokens[range.lowerBound + 1].value
                let isLexical = tokens[range.lowerBound].value != "var"
                if let existingIsLexical = topLevelBindings[name], existingIsLexical || isLexical {
                    return StatementDispatch(tokens: [], wasLimited: true, structurallyInvalid: true)
                }
                topLevelBindings[name] = isLexical
            }
            switch decision(for: range) {
            case .supported:
                return nil
            case .validBarrier:
                if firstBarrierStart == nil { firstBarrierStart = statementStart }
                return nil
            case .structurallyInvalid:
                return StatementDispatch(tokens: [], wasLimited: true, structurallyInvalid: true)
            }
        }

        while index < tokens.count {
            let value = tokens[index].value
            if let close = closingDelimiter(for: value) {
                stack.append(close)
            } else if openingDelimiter(for: value) != nil {
                if !stack.isEmpty { stack.removeLast() }
            } else if value == ";", stack.isEmpty {
                if let result = finish(index) { return result }
                statementStart = index + 1
            }
            index += 1
        }
        if let result = finish(tokens.count) { return result }
        if let firstBarrierStart {
            return StatementDispatch(
                tokens: Array(tokens[..<firstBarrierStart]),
                wasLimited: true,
                structurallyInvalid: false
            )
        }
        return StatementDispatch(tokens: tokens, wasLimited: false, structurallyInvalid: false)
    }

    private static func isStaticLiteralExpression(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count == 1 else { return false }
        let token = tokens[range.lowerBound]
        if token.isString || ["<template>", "<regex>"].contains(token.value) { return true }
        return token.isIdentifier && (
            isASCIIDecimalInteger(token.value) || ["true", "false", "null"].contains(token.value)
        )
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isASCIIDecimalInteger(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy(isASCIIDigit) else { return false }
        return bytes.count == 1 || bytes[0] != 48
    }

    private static func isIdentifierName(_ token: Token) -> Bool {
        let bytes = Array(token.value.utf8)
        guard token.isIdentifier, let first = bytes.first,
              isASCIILetter(first) || first == 95 || first == 36 else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIILetter($0) || isASCIIDigit($0) || $0 == 95 || $0 == 36
        }
    }

    private static func isRootReferenceIdentifier(_ token: Token) -> Bool {
        isIdentifierName(token) && !reservedIdentifierNames.contains(token.value)
    }

    private static func isBindingIdentifier(_ token: Token) -> Bool {
        isIdentifierName(token) && !bindingForbiddenNames.contains(token.value)
    }

    private static func isExactToolExpression(_ tokens: [Token], range: Range<Int>) -> Bool {
        var index = range.lowerBound
        if index < range.upperBound, tokens[index].value == "await" { index += 1 }
        guard index < range.upperBound, isToolCallStart(tokens, at: index) else { return false }
        return parseCall(tokens, at: index, resultBinding: .direct).endIndex == range.upperBound
    }

    private static func isExactPromiseAggregateExpression(_ tokens: [Token], range: Range<Int>) -> Bool {
        var index = range.lowerBound
        if index < range.upperBound, tokens[index].value == "await" { index += 1 }
        guard index + 5 < range.upperBound,
              tokens[index].value == "Promise", tokens[index + 1].value == ".",
              ["all", "allSettled"].contains(tokens[index + 2].value),
              tokens[index + 3].value == "(", tokens[index + 4].value == "[" else { return false }
        let outer = matchingDelimiter(tokens, from: index + 3)
        let array = matchingDelimiter(tokens, from: index + 4)
        guard let outerClose = outer.index, let arrayClose = array.index,
              outerClose == range.upperBound - 1, arrayClose + 1 == outerClose else { return false }

        var cursor = index + 5
        while cursor < arrayClose {
            guard isToolCallStart(tokens, at: cursor) else { return false }
            let parsed = parseCall(tokens, at: cursor, resultBinding: .aggregate)
            guard let end = parsed.endIndex, end <= arrayClose else { return false }
            cursor = end
            if cursor == arrayClose { break }
            guard tokens[cursor].value == "," else { return false }
            cursor += 1
        }
        return cursor == arrayClose
    }

    private static func isExactLiteralOutputExpression(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count >= 3, tokens[range.lowerBound].value == "text",
              tokens[range.lowerBound + 1].value == "(" else { return false }
        let outer = matchingDelimiter(tokens, from: range.lowerBound + 1)
        guard let close = outer.index, close == range.upperBound - 1 else { return false }
        let argumentRange = (range.lowerBound + 2)..<close
        return argumentRange.isEmpty || isStaticLiteralExpression(tokens, range: argumentRange) ||
            isExactToolExpression(tokens, range: argumentRange)
    }

    /// Valid barriers are deliberately narrower than JavaScript. They prove
    /// enough syntax to retain earlier calls, but are never scanned for new
    /// evidence and always make result binding uncertain.
    private static func isSyntacticallyValidBarrier(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        if range.count == 1, tokens[range.lowerBound].value == "<template-expression>" { return true }
        if let last = range.last, ["<template>", "<template-expression>"].contains(tokens[last].value),
           isSimpleReference(tokens, range: range.lowerBound..<last) { return true }
        if isSimpleReference(tokens, range: range) || isValidCallExpression(tokens, range: range) { return true }
        if tokens[range.lowerBound].value == "await" {
            let valueRange = (range.lowerBound + 1)..<range.upperBound
            return isSimpleReference(tokens, range: valueRange) ||
                isValidCallExpression(tokens, range: valueRange)
        }
        return isValidDeclarationBarrier(tokens, range: range) ||
            isValidAssignmentBarrier(tokens, range: range) ||
            isValidUpdateOrDeleteBarrier(tokens, range: range) ||
            isValidConditionalBarrier(tokens, range: range) ||
            isValidIndexedOutputForLoopBarrier(tokens, range: range) ||
            isValidOutputForLoopBarrier(tokens, range: range) ||
            isValidOutputCallbackBarrier(tokens, range: range)
    }

    private static func isSimpleReference(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        var index = range.lowerBound
        guard isRootReferenceIdentifier(tokens[index]) else { return false }
        index += 1
        while index < range.upperBound {
            guard index + 1 < range.upperBound, tokens[index].value == ".",
                  isIdentifierName(tokens[index + 1]) else { return false }
            index += 2
        }
        return true
    }

    private static func isSimpleValueExpression(_ tokens: [Token], range: Range<Int>) -> Bool {
        isStaticLiteralExpression(tokens, range: range) || isSimpleReference(tokens, range: range)
    }

    private static func isValidCallExpression(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count >= 3 else { return false }
        var openIndex: Int?
        for index in range where tokens[index].value == "(" {
            openIndex = index
            break
        }
        guard let openIndex, openIndex > range.lowerBound,
              isSimpleReference(tokens, range: range.lowerBound..<openIndex) else { return false }
        let match = matchingDelimiter(tokens, from: openIndex)
        guard let close = match.index, close == range.upperBound - 1 else { return false }
        return isValidSimpleArgumentList(tokens, range: (openIndex + 1)..<close)
    }

    private static func isValidSimpleArgumentList(_ tokens: [Token], range: Range<Int>) -> Bool {
        if range.isEmpty { return true }
        var start = range.lowerBound
        var sawArgument = false
        for index in range where tokens[index].value == "," {
            guard start < index, isSimpleValueExpression(tokens, range: start..<index) else { return false }
            sawArgument = true
            start = index + 1
        }
        if start == range.upperBound { return sawArgument }
        return isSimpleValueExpression(tokens, range: start..<range.upperBound)
    }

    private static func isValidDeclarationBarrier(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count >= 4, ["const", "let", "var"].contains(tokens[range.lowerBound].value),
              isBindingIdentifier(tokens[range.lowerBound + 1]),
              tokens[range.lowerBound + 2].value == "=" else { return false }
        let valueRange = (range.lowerBound + 3)..<range.upperBound
        if isSimpleValueExpression(tokens, range: valueRange) ||
            isValidCallExpression(tokens, range: valueRange) { return true }
        guard !valueRange.isEmpty, tokens[valueRange.lowerBound].value == "await" else { return false }
        let awaited = (valueRange.lowerBound + 1)..<valueRange.upperBound
        return isSimpleReference(tokens, range: awaited) || isValidCallExpression(tokens, range: awaited)
    }

    private static func assignmentOperatorLength(_ tokens: [Token], at index: Int, upperBound: Int) -> Int? {
        guard index < upperBound else { return nil }
        return assignmentOperators.contains(tokens[index].value) ? 1 : nil
    }

    private static func isAssignableReference(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard !range.isEmpty, isRootReferenceIdentifier(tokens[range.lowerBound]),
              !bindingForbiddenNames.contains(tokens[range.lowerBound].value) else { return false }
        var index = range.lowerBound + 1
        while index < range.upperBound {
            if index + 1 < range.upperBound, tokens[index].value == ".",
               isIdentifierName(tokens[index + 1]) {
                index += 2
                continue
            }
            if tokens[index].value == "[" {
                let match = matchingDelimiter(tokens, from: index)
                guard let close = match.index, close < range.upperBound,
                      isSimpleValueExpression(tokens, range: (index + 1)..<close) else { return false }
                index = close + 1
                continue
            }
            return false
        }
        return true
    }

    private static func isValidAssignmentBarrier(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count >= 3 else { return false }
        for index in (range.lowerBound + 1)..<range.upperBound {
            guard let length = assignmentOperatorLength(tokens, at: index, upperBound: range.upperBound) else {
                continue
            }
            let valueStart = index + length
            return isAssignableReference(tokens, range: range.lowerBound..<index) &&
                valueStart < range.upperBound &&
                isSimpleValueExpression(tokens, range: valueStart..<range.upperBound)
        }
        return false
    }

    private static func isValidUpdateOrDeleteBarrier(_ tokens: [Token], range: Range<Int>) -> Bool {
        if tokens[range.lowerBound].value == "delete" {
            let target = (range.lowerBound + 1)..<range.upperBound
            guard isAssignableReference(tokens, range: target) else { return false }
            return tokens[target].contains { [".", "["].contains($0.value) }
        }
        if range.count >= 2, ["++", "--"].contains(tokens[range.lowerBound].value) {
            return isAssignableReference(tokens, range: (range.lowerBound + 1)..<range.upperBound)
        }
        if range.count >= 2, ["++", "--"].contains(tokens[range.upperBound - 1].value),
           !tokens[range.upperBound - 1].lineBreakBefore {
            return isAssignableReference(tokens, range: range.lowerBound..<(range.upperBound - 1))
        }
        return false
    }

    private static func isValidConditionalBarrier(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count >= 5, tokens[range.lowerBound].value == "if",
              tokens[range.lowerBound + 1].value == "(" else { return false }
        let condition = matchingDelimiter(tokens, from: range.lowerBound + 1)
        guard let conditionClose = condition.index,
              isSimpleValueExpression(tokens, range: (range.lowerBound + 2)..<conditionClose),
              conditionClose + 1 < range.upperBound else { return false }
        var bodyStart = conditionClose + 1
        var bodyUpper = range.upperBound
        if tokens[bodyStart].value == "{" {
            let body = matchingDelimiter(tokens, from: bodyStart)
            guard let close = body.index, close == range.upperBound - 1 else { return false }
            bodyStart += 1
            bodyUpper = close
            if bodyStart < bodyUpper, tokens[bodyUpper - 1].value == ";" { bodyUpper -= 1 }
        }
        let bodyRange = bodyStart..<bodyUpper
        return isValidCallExpression(tokens, range: bodyRange) ||
            isExactToolExpression(tokens, range: bodyRange)
    }

    /// Covers the observed result-formatting loop without admitting general
    /// C-style loops. The header and output projection must match exactly;
    /// the body is skipped and never treated as invocation evidence.
    private static func isValidIndexedOutputForLoopBarrier(
        _ tokens: [Token], range: Range<Int>
    ) -> Bool {
        guard range.count >= 25, tokens[range.lowerBound].value == "for",
              tokens[range.lowerBound + 1].value == "(" else { return false }
        let header = matchingDelimiter(tokens, from: range.lowerBound + 1)
        guard let headerClose = header.index, headerClose + 1 < range.upperBound else { return false }

        var cursor = range.lowerBound + 2
        guard cursor + 11 < headerClose, tokens[cursor].value == "let",
              isBindingIdentifier(tokens[cursor + 1]), tokens[cursor + 2].value == "=",
              tokens[cursor + 3].value == "0", tokens[cursor + 4].value == ";" else { return false }
        let indexName = tokens[cursor + 1].value
        cursor += 5
        guard tokens[cursor].value == indexName, tokens[cursor + 1].value == "<",
              isRootReferenceIdentifier(tokens[cursor + 2]), tokens[cursor + 3].value == ".",
              tokens[cursor + 4].value == "length", tokens[cursor + 5].value == ";" else { return false }
        let sourceName = tokens[cursor + 2].value
        cursor += 6
        guard tokens[cursor].value == indexName, tokens[cursor + 1].value == "++",
              !tokens[cursor + 1].lineBreakBefore, cursor + 2 == headerClose else { return false }

        var bodyRange = (headerClose + 1)..<range.upperBound
        if tokens[bodyRange.lowerBound].value == "{" {
            let body = matchingDelimiter(tokens, from: bodyRange.lowerBound)
            guard let close = body.index, close == range.upperBound - 1 else { return false }
            bodyRange = (bodyRange.lowerBound + 1)..<close
            if !bodyRange.isEmpty, tokens[bodyRange.upperBound - 1].value == ";" {
                bodyRange = bodyRange.lowerBound..<(bodyRange.upperBound - 1)
            }
        }
        guard bodyRange.count >= 12, tokens[bodyRange.lowerBound].value == "text",
              tokens[bodyRange.lowerBound + 1].value == "(" else { return false }
        let outputCall = matchingDelimiter(tokens, from: bodyRange.lowerBound + 1)
        guard let outputClose = outputCall.index, outputClose == bodyRange.upperBound - 1,
              tokens[bodyRange.lowerBound + 2].value == "{" else { return false }
        let object = matchingDelimiter(tokens, from: bodyRange.lowerBound + 2)
        guard let objectClose = object.index, objectClose == outputClose - 1 else { return false }

        cursor = bodyRange.lowerBound + 3
        guard cursor + 8 == objectClose, tokens[cursor].value == indexName,
              tokens[cursor + 1].value == ",", isIdentifierName(tokens[cursor + 2]),
              tokens[cursor + 3].value == ":", tokens[cursor + 4].value == sourceName,
              tokens[cursor + 5].value == "[", tokens[cursor + 6].value == indexName,
              tokens[cursor + 7].value == "]" else { return false }
        return true
    }

    private static func isValidOutputForLoopBarrier(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count >= 12, tokens[range.lowerBound].value == "for",
              tokens[range.lowerBound + 1].value == "(" else { return false }
        let header = matchingDelimiter(tokens, from: range.lowerBound + 1)
        guard let headerClose = header.index, headerClose + 1 < range.upperBound,
              tokens[headerClose + 1].value == "{" else { return false }
        let body = matchingDelimiter(tokens, from: headerClose + 1)
        guard let bodyClose = body.index, bodyClose == range.upperBound - 1 else { return false }

        let headerStart = range.lowerBound + 2
        guard headerStart + 3 < headerClose, tokens[headerStart].value == "const",
              isBindingIdentifier(tokens[headerStart + 1]), tokens[headerStart + 2].value == "of",
              isSimpleReference(tokens, range: (headerStart + 3)..<headerClose) else { return false }
        var bodyUpper = bodyClose
        if headerClose + 2 < bodyUpper, tokens[bodyUpper - 1].value == ";" { bodyUpper -= 1 }
        let bodyRange = (headerClose + 2)..<bodyUpper
        guard !bodyRange.isEmpty, tokens[bodyRange.lowerBound].value == "text" else { return false }
        return isValidCallExpression(tokens, range: bodyRange)
    }

    private static func isValidOutputCallbackBarrier(_ tokens: [Token], range: Range<Int>) -> Bool {
        guard range.count >= 8 else { return false }
        var methodDot: Int?
        for index in (range.lowerBound + 1)..<(range.upperBound - 2) where
            tokens[index].value == "." && tokens[index + 1].value == "forEach" &&
            tokens[index + 2].value == "(" {
            methodDot = index
            break
        }
        guard let methodDot, isSimpleReference(tokens, range: range.lowerBound..<methodDot) else { return false }
        let outer = matchingDelimiter(tokens, from: methodDot + 2)
        guard let outerClose = outer.index, outerClose == range.upperBound - 1 else { return false }
        let callbackRange = (methodDot + 3)..<outerClose
        var parameters = Set<String>()
        var arrowIndex: Int
        if callbackRange.isEmpty { return false }
        if tokens[callbackRange.lowerBound].value == "(" {
            let parameterList = matchingDelimiter(tokens, from: callbackRange.lowerBound)
            guard let close = parameterList.index, close + 1 < callbackRange.upperBound,
                  tokens[close + 1].value == "=>" else { return false }
            var cursor = callbackRange.lowerBound + 1
            while cursor < close {
                guard isBindingIdentifier(tokens[cursor]),
                      parameters.insert(tokens[cursor].value).inserted else { return false }
                cursor += 1
                if cursor == close { break }
                guard tokens[cursor].value == "," else { return false }
                cursor += 1
            }
            guard !parameters.isEmpty else { return false }
            arrowIndex = close + 1
        } else {
            guard isBindingIdentifier(tokens[callbackRange.lowerBound]),
                  callbackRange.lowerBound + 1 < callbackRange.upperBound,
                  tokens[callbackRange.lowerBound + 1].value == "=>" else { return false }
            parameters.insert(tokens[callbackRange.lowerBound].value)
            arrowIndex = callbackRange.lowerBound + 1
        }
        return isValidOutputCallbackBody(
            tokens,
            range: (arrowIndex + 1)..<callbackRange.upperBound,
            parameters: parameters
        )
    }

    private static func isValidOutputCallbackBody(
        _ tokens: [Token], range: Range<Int>, parameters: Set<String>
    ) -> Bool {
        guard range.count >= 3, tokens[range.lowerBound].value == "text",
              tokens[range.lowerBound + 1].value == "(" else { return false }
        let call = matchingDelimiter(tokens, from: range.lowerBound + 1)
        guard let close = call.index, close == range.upperBound - 1 else { return false }
        let argument = (range.lowerBound + 2)..<close
        if isSimpleValueExpression(tokens, range: argument) {
            return parameters.contains(tokens[argument.lowerBound].value)
        }
        guard !argument.isEmpty, tokens[argument.lowerBound].value == "{" else { return false }
        let object = matchingDelimiter(tokens, from: argument.lowerBound)
        guard let objectClose = object.index, objectClose == argument.upperBound - 1 else { return false }
        var start = argument.lowerBound + 1
        var protoSetterCount = 0
        while start < objectClose {
            var end = start
            while end < objectClose, tokens[end].value != "," { end += 1 }
            if end - start >= 2, tokens[start].value == "__proto__", tokens[start + 1].value == ":" {
                protoSetterCount += 1
                if protoSetterCount > 1 { return false }
            }
            guard isValidOutputObjectField(tokens, range: start..<end, parameters: parameters) else { return false }
            start = end + 1
        }
        return start == objectClose || start == objectClose + 1
    }

    private static func isValidOutputObjectField(
        _ tokens: [Token], range: Range<Int>, parameters: Set<String>
    ) -> Bool {
        guard !range.isEmpty else { return false }
        if range.count == 1, isIdentifierName(tokens[range.lowerBound]) {
            return parameters.contains(tokens[range.lowerBound].value)
        }
        if range.count == 2, tokens[range.lowerBound].value == "...",
           isIdentifierName(tokens[range.lowerBound + 1]) {
            return parameters.contains(tokens[range.lowerBound + 1].value)
        }
        guard range.count >= 3, isIdentifierName(tokens[range.lowerBound]),
              tokens[range.lowerBound + 1].value == ":" else { return false }
        let valueRange = (range.lowerBound + 2)..<range.upperBound
        if isStaticLiteralExpression(tokens, range: valueRange) { return true }
        guard isSimpleReference(tokens, range: valueRange) else { return false }
        return parameters.contains(tokens[valueRange.lowerBound].value)
    }

    private static func isToolCallStart(_ tokens: [Token], at index: Int) -> Bool {
        guard index + 4 < tokens.count else { return false }
        return tokens[index].isIdentifier && tokens[index].value == "tools" &&
            tokens[index + 1].value == "." && isIdentifierName(tokens[index + 2]) &&
            tokens[index + 3].value == "(" && tokens[index + 4].value == "{"
    }

    private static func isProtectedBindingOrReassignment(_ tokens: [Token], at index: Int) -> Bool {
        if ["const", "let", "var"].contains(tokens[index].value),
           declarationPatternBindsProtectedName(tokens, after: index) {
            return true
        }

        if ["{", "["].contains(tokens[index].value),
           destructuringPatternAssignsProtectedName(tokens, at: index) {
            return true
        }

        guard tokens[index].isIdentifier,
              protectedRuntimeNames.contains(tokens[index].value),
              index + 1 < tokens.count else { return false }
        if hasPrefixUpdateOperator(tokens, before: index) ||
           isAssignmentOperator(tokens, at: index + 1) ||
           isUpdateOperator(tokens, at: index + 1) { return true }
        guard ["tools", "ALL_TOOLS", "Promise"].contains(tokens[index].value) else { return false }
        if index + 3 < tokens.count,
           tokens[index + 1].value == ".", tokens[index + 2].isIdentifier,
           (isAssignmentOperator(tokens, at: index + 3) || isUpdateOperator(tokens, at: index + 3)) { return true }
        if tokens[index + 1].value == "[" {
            let match = matchingDelimiter(tokens, from: index + 1)
            if let close = match.index,
               isAssignmentOperator(tokens, at: close + 1) || isUpdateOperator(tokens, at: close + 1) { return true }
        }
        return false
    }

    private static func containsProtectedRuntimeBindingDeclaration(_ tokens: [Token]) -> Bool {
        var stack: [String] = []
        for index in tokens.indices {
            let value = tokens[index].value
            if let close = closingDelimiter(for: value) {
                stack.append(close)
                continue
            }
            if openingDelimiter(for: value) != nil {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if stack.isEmpty, ["const", "let", "var"].contains(value),
               declarationPatternBindsProtectedName(tokens, after: index) {
                return true
            }
        }
        return false
    }

    private static func hasPrefixUpdateOperator(_ tokens: [Token], before index: Int) -> Bool {
        index >= 1 && ["++", "--"].contains(tokens[index - 1].value)
    }

    private static func isUpdateOperator(_ tokens: [Token], at index: Int) -> Bool {
        index < tokens.count && ["++", "--"].contains(tokens[index].value)
    }

    private static func declarationPatternBindsProtectedName(_ tokens: [Token], after declarationIndex: Int) -> Bool {
        var stack: [String] = []
        var sawProtectedName = false
        var index = declarationIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            if let close = closingDelimiter(for: token.value) {
                guard stack.count < maximumNesting else { return true }
                stack.append(close)
            } else if openingDelimiter(for: token.value) != nil {
                guard stack.last == token.value else { return true }
                stack.removeLast()
            } else if token.value == "=", stack.isEmpty {
                return sawProtectedName
            } else if [";", ","].contains(token.value), stack.isEmpty {
                return false
            } else if token.isIdentifier, protectedRuntimeNames.contains(token.value) {
                sawProtectedName = true
            }
            index += 1
        }
        return false
    }

    private static func destructuringPatternAssignsProtectedName(_ tokens: [Token], at index: Int) -> Bool {
        let match = matchingDelimiter(tokens, from: index)
        guard let close = match.index, isAssignmentOperator(tokens, at: close + 1) else { return false }
        return tokens[(index + 1)..<close].contains {
            $0.isIdentifier && protectedRuntimeNames.contains($0.value)
        }
    }

    private enum CatalogCallbackKind { case filter, map }

    /// Recognizes only the privacy-safe output catalog shape used to inspect
    /// ALL_TOOLS metadata. Callback bodies are validated as data projection,
    /// then skipped whole; they are never scanned as execution evidence.
    private static func safeAllToolsCatalogOutputEnd(_ tokens: [Token], at index: Int) -> Int? {
        guard isAllToolsCatalogOutputStart(tokens, at: index) else { return nil }
        let outer = matchingDelimiter(tokens, from: index + 1)
        let filter = matchingDelimiter(tokens, from: index + 5)
        guard let outerClose = outer.index, let filterClose = filter.index,
              filterClose < outerClose,
              isSafeCatalogCallback(tokens, range: (index + 6)..<filterClose, kind: .filter) else { return nil }

        var cursor = filterClose + 1
        if cursor < outerClose {
            guard cursor + 2 < outerClose,
                  tokens[cursor].value == ".", tokens[cursor + 1].value == "map",
                  tokens[cursor + 2].value == "(" else { return nil }
            let map = matchingDelimiter(tokens, from: cursor + 2)
            guard let mapClose = map.index, mapClose < outerClose,
                  isSafeCatalogCallback(tokens, range: (cursor + 3)..<mapClose, kind: .map) else { return nil }
            cursor = mapClose + 1
        }
        return cursor == outerClose ? outerClose + 1 : nil
    }

    private static func isAllToolsCatalogOutputStart(_ tokens: [Token], at index: Int) -> Bool {
        guard index + 5 < tokens.count else { return false }
        return tokens[index].value == "text" && tokens[index + 1].value == "(" &&
            tokens[index + 2].value == "ALL_TOOLS" && tokens[index + 3].value == "." &&
            tokens[index + 4].value == "filter" && tokens[index + 5].value == "("
    }

    private static func isSafeCatalogCallback(
        _ tokens: [Token], range: Range<Int>, kind: CatalogCallbackKind
    ) -> Bool {
        guard range.count >= 3 else { return false }
        let callback = Array(tokens[range])
        guard isBindingIdentifier(callback[0]), callback[1].value == "=>" else { return false }
        let parameter = callback[0].value
        guard !protectedRuntimeNames.contains(parameter) else { return false }
        switch kind {
        case .filter:
            return isExactCatalogFilterCallback(callback, parameter: parameter)
        case .map:
            return isExactCatalogMapCallback(callback, parameter: parameter)
        }
    }

    private static func isExactCatalogFilterCallback(_ tokens: [Token], parameter: String) -> Bool {
        var index = 2
        func consume(_ value: String) -> Bool {
            guard index < tokens.count, tokens[index].value == value else { return false }
            index += 1
            return true
        }

        guard consume("<regex>"), consume("."), consume("test"), consume("("),
              consume(parameter), consume("."), consume("name") else { return false }
        if consume(")") { return index == tokens.count }
        guard consume("+"), index < tokens.count, tokens[index].isString else { return false }
        index += 1
        guard consume("+"), consume(parameter), consume("."), consume("description"),
              consume(")") else { return false }
        return index == tokens.count
    }

    private static func isExactCatalogMapCallback(_ tokens: [Token], parameter: String) -> Bool {
        var index = 2
        func consume(_ value: String) -> Bool {
            guard index < tokens.count, tokens[index].value == value else { return false }
            index += 1
            return true
        }
        func consumeStaticInteger() -> Bool {
            guard index < tokens.count, tokens[index].isIdentifier,
                  isASCIIDecimalInteger(tokens[index].value) else { return false }
            index += 1
            return true
        }

        guard consume("("), consume("{"), consume("name"), consume(":"),
              consume(parameter), consume("."), consume("name") else { return false }
        if consume("}") {
            return consume(")") && index == tokens.count
        }
        guard consume(","), consume("description"), consume(":"),
              consume(parameter), consume("."), consume("description") else { return false }
        if consume(".") {
            guard consume("slice"), consume("("), consumeStaticInteger(), consume(","),
                  consumeStaticInteger(), consume(")") else { return false }
        }
        guard consume("}"), consume(")") else { return false }
        return index == tokens.count
    }

    private static func isAssignmentOperator(_ tokens: [Token], at index: Int) -> Bool {
        index < tokens.count && assignmentOperators.contains(tokens[index].value)
    }

    /// Unknown awaited work or a call outside the small supported wrapper set
    /// is an execution barrier. Calls before it remain evidence, but calls
    /// after it may be unreachable and are never guessed.
    private static func isUnsupportedAwait(_ tokens: [Token], at index: Int) -> Bool {
        guard tokens[index].value == "await" else { return false }
        guard index + 1 < tokens.count else { return true }
        if tokens[index + 1].value == "tools" { return false }
        return !(index + 4 < tokens.count &&
            tokens[index + 1].value == "Promise" && tokens[index + 2].value == "." &&
            ["all", "allSettled"].contains(tokens[index + 3].value) && tokens[index + 4].value == "(")
    }

    private static func isUnsupportedCall(_ tokens: [Token], at index: Int) -> Bool {
        guard tokens[index].isIdentifier else { return false }
        if tokens[index].value == "tools" { return false }
        if supportedOutputCalls.contains(tokens[index].value),
           index + 1 < tokens.count, tokens[index + 1].value == "(" {
            return false
        }
        if index >= 2, tokens[index - 2].value == "Promise", tokens[index - 1].value == ".",
           ["all", "allSettled"].contains(tokens[index].value),
           index + 1 < tokens.count, tokens[index + 1].value == "(" {
            return false
        }
        if index + 1 < tokens.count, tokens[index + 1].value == "(" { return true }
        if index + 3 < tokens.count, tokens[index + 1].value == ".",
           tokens[index + 2].isIdentifier, tokens[index + 3].value == "(" {
            return !(
                tokens[index].value == "Promise" &&
                ["all", "allSettled"].contains(tokens[index + 2].value)
            )
        }
        return false
    }

    /// Returns the beginning of each deferred arrow parameter region. Default
    /// expressions in that region are not treated as wrapper execution
    /// evidence even though their tokens precede the arrow itself.
    private static func deferredArrowParameterStarts(_ tokens: [Token]) -> Set<Int> {
        var starts = Set<Int>()
        for arrow in tokens.indices where tokens[arrow].value == "=>" {
            guard arrow > 0 else { continue }
            let previous = arrow - 1
            if tokens[previous].isIdentifier {
                starts.insert(previous)
                continue
            }
            guard openingDelimiter(for: tokens[previous].value) != nil else {
                starts.insert(arrow)
                continue
            }
            var stack = [tokens[previous].value]
            var cursor = previous
            while cursor > 0 {
                cursor -= 1
                let value = tokens[cursor].value
                if openingDelimiter(for: value) != nil {
                    stack.append(value)
                } else if let close = closingDelimiter(for: value) {
                    guard stack.last == close else { break }
                    stack.removeLast()
                    if stack.isEmpty {
                        starts.insert(cursor)
                        break
                    }
                }
            }
        }
        return starts
    }

    private static func isPromiseAggregateOpen(_ tokens: [Token], at index: Int) -> Bool {
        guard index >= 3 else { return false }
        return tokens[index - 3].value == "Promise" && tokens[index - 2].value == "." &&
            ["all", "allSettled"].contains(tokens[index - 1].value)
    }

    private static func openingDelimiter(for closing: String) -> String? {
        switch closing {
        case ")": return "("
        case "]": return "["
        case "}": return "{"
        default: return nil
        }
    }

    private static func hasValidDelimiterStructure(_ tokens: [Token]) -> Bool {
        var stack: [String] = []
        for token in tokens {
            if let close = closingDelimiter(for: token.value) {
                guard stack.count < maximumNesting else { return false }
                stack.append(close)
            } else if openingDelimiter(for: token.value) != nil {
                guard stack.last == token.value else { return false }
                stack.removeLast()
            }
        }
        return stack.isEmpty
    }

    private static func closingDelimiter(for opening: String) -> String? {
        switch opening {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        default: return nil
        }
    }

    private static func matchingDelimiter(_ tokens: [Token], from start: Int) -> (index: Int?, wasLimited: Bool) {
        guard start < tokens.count, let firstClose = closingDelimiter(for: tokens[start].value) else {
            return (nil, true)
        }
        var stack: [String] = [firstClose]
        var index = start + 1
        while index < tokens.count {
            let value = tokens[index].value
            if let close = closingDelimiter(for: value) {
                guard stack.count < maximumNesting else { return (nil, true) }
                stack.append(close)
            } else if openingDelimiter(for: value) != nil {
                guard stack.last == value else { return (nil, true) }
                stack.removeLast()
                if stack.isEmpty { return (index, false) }
            }
            index += 1
        }
        return (nil, true)
    }

    private static func containsStructurallyInvalidToolCall(_ tokens: [Token]) -> Bool {
        for index in tokens.indices where isToolCallStart(tokens, at: index) {
            if parseCall(tokens, at: index, resultBinding: .unbound).structurallyInvalid {
                return true
            }
        }
        return false
    }

    private static func parseCall(_ tokens: [Token], at index: Int, resultBinding: ResultBinding)
        -> (call: Call?, endIndex: Int?, wasLimited: Bool, structurallyInvalid: Bool) {
        let objectMatch = matchingDelimiter(tokens, from: index + 4)
        guard let objectEnd = objectMatch.index else {
            return (nil, nil, objectMatch.wasLimited, true)
        }
        guard objectEnd + 1 < tokens.count, tokens[objectEnd + 1].value == ")" else {
            return (nil, objectEnd + 1, false, true)
        }

        let fields = literalFields(tokens, range: (index + 5)..<objectEnd)
        if fields.structurallyInvalid {
            return (nil, objectEnd + 2, true, true)
        }
        guard let fieldsValues = fields.values,
              let data = try? JSONSerialization.data(withJSONObject: fieldsValues, options: [.sortedKeys]) else {
            return (nil, objectEnd + 2, fields.wasLimited, false)
        }
        return (
            Call(
                name: tokens[index + 2].value,
                input: String(decoding: data, as: UTF8.self),
                resultBinding: resultBinding
            ),
            objectEnd + 2,
            fields.wasLimited,
            false
        )
    }

    /// Reads only allowlisted literal fields from one object literal. Any
    /// supported dynamic sibling makes the tool invocation itself uncertain:
    /// evaluating that sibling may throw or mutate state before the call.
    private static func literalFields(_ tokens: [Token], range: Range<Int>) -> LiteralFieldParsing {
        var values: [String: String] = [:]
        var sawEvidenceKeys = Set<String>()
        var hasDynamicEvaluation = false
        var protoSetterCount = 0
        var wasLimited = false
        var fieldStart = range.lowerBound
        var stack: [String] = []
        var index = range.lowerBound

        func parseField(_ fieldRange: Range<Int>) -> Bool {
            guard !fieldRange.isEmpty else { return false }
            let field = Array(tokens[fieldRange])

            if field.first?.value == "..." {
                guard field.count > 1,
                      isSimpleReference(field, range: 1..<field.count) else { return false }
                hasDynamicEvaluation = true
                wasLimited = true
                return true
            }

            if field.first?.value == "[" {
                let key = matchingDelimiter(field, from: 0)
                guard let keyClose = key.index, keyClose + 2 < field.count,
                      field[keyClose + 1].value == ":",
                      isSimpleValueExpression(field, range: 1..<keyClose) else { return false }
                let valueRange = (keyClose + 2)..<field.count
                guard isStaticLiteralExpression(field, range: valueRange) ||
                        isSimpleReference(field, range: valueRange) ||
                        isValidCallExpression(field, range: valueRange) else { return false }
                hasDynamicEvaluation = true
                wasLimited = true
                return true
            }

            if field.count == 1 {
                guard isRootReferenceIdentifier(field[0]) else { return false }
                hasDynamicEvaluation = true
                wasLimited = true
                return true
            }

            guard field.count >= 3, field[1].value == ":" else { return false }
            let keyToken = field[0]
            guard isIdentifierName(keyToken) || keyToken.isString else { return false }
            let key = keyToken.value
            if key == "__proto__" {
                protoSetterCount += 1
                if protoSetterCount > 1 { return false }
            }
            let valueRange = 2..<field.count
            let valueTokens = field
            guard isStaticLiteralExpression(valueTokens, range: valueRange) ||
                    isSimpleReference(valueTokens, range: valueRange) ||
                    isValidCallExpression(valueTokens, range: valueRange) else { return false }

            let isDynamic = isSimpleReference(valueTokens, range: valueRange) ||
                isValidCallExpression(valueTokens, range: valueRange)
            if !evidenceKeys.contains(key) {
                if isDynamic {
                    hasDynamicEvaluation = true
                    wasLimited = true
                }
                return true
            }
            guard sawEvidenceKeys.insert(key).inserted else {
                hasDynamicEvaluation = true
                wasLimited = true
                return true
            }
            if field.count == 3, field[2].isString {
                values[key] = field[2].value
            } else {
                hasDynamicEvaluation = true
                wasLimited = true
            }
            return true
        }

        while index < range.upperBound {
            let value = tokens[index].value
            if let close = closingDelimiter(for: value) {
                guard stack.count < maximumNesting else {
                    return LiteralFieldParsing(values: nil, wasLimited: true, structurallyInvalid: true)
                }
                stack.append(close)
            } else if openingDelimiter(for: value) != nil {
                guard stack.last == value else {
                    return LiteralFieldParsing(values: nil, wasLimited: true, structurallyInvalid: true)
                }
                stack.removeLast()
            } else if value == ",", stack.isEmpty {
                guard parseField(fieldStart..<index) else {
                    return LiteralFieldParsing(values: nil, wasLimited: true, structurallyInvalid: true)
                }
                fieldStart = index + 1
            }
            index += 1
        }
        guard stack.isEmpty else {
            return LiteralFieldParsing(values: nil, wasLimited: true, structurallyInvalid: true)
        }
        if fieldStart < range.upperBound {
            guard parseField(fieldStart..<range.upperBound) else {
                return LiteralFieldParsing(values: nil, wasLimited: true, structurallyInvalid: true)
            }
        } else if !range.isEmpty, tokens[range.upperBound - 1].value != "," {
            return LiteralFieldParsing(values: nil, wasLimited: true, structurallyInvalid: true)
        }
        return LiteralFieldParsing(
            values: hasDynamicEvaluation ? nil : values,
            wasLimited: wasLimited,
            structurallyInvalid: false
        )
    }

    /// This is intentionally a small approved subset, not a JavaScript regex
    /// parser. Catalog discovery needs literal words, safe separators, groups
    /// and alternation only; all unproved metasyntax fails closed.
    private static func isStructurallyValidRegex(_ pattern: String, flags: String) -> Bool {
        let allowedFlags = Set("dgimsuvy")
        var seenFlags = Set<Character>()
        for flag in flags {
            guard allowedFlags.contains(flag), seenFlags.insert(flag).inserted else { return false }
        }
        guard !(seenFlags.contains("u") && seenFlags.contains("v")) else { return false }

        let characters = Array(pattern)
        var lowerBound = 0
        var upperBound = characters.count
        if characters.first == "^" { lowerBound += 1 }
        if characters.last == "$" { upperBound -= 1 }
        guard lowerBound < upperBound else { return false }

        var parenthesisDepth = 0
        var expectsTerm = true
        for character in characters[lowerBound..<upperBound] {
            if character.isLetter || character.isNumber ||
                ["_", "-", " "].contains(character) {
                expectsTerm = false
                continue
            }
            switch character {
            case "(":
                parenthesisDepth += 1
                expectsTerm = true
            case ")":
                guard parenthesisDepth > 0, !expectsTerm else { return false }
                parenthesisDepth -= 1
                expectsTerm = false
            case "|":
                guard !expectsTerm else { return false }
                expectsTerm = true
            default:
                return false
            }
        }
        return !expectsTerm && parenthesisDepth == 0
    }

    private static func tokenize(_ input: String) -> Tokenization {
        let characters = Array(input)
        var tokens: [Token] = []
        var index = 0
        var wasLimited = false
        var structurallyInvalid = false
        var pendingLineBreak = false

        func append(_ value: String, _ kind: TokenKind) -> Bool {
            guard tokens.count < maximumTokens else { return false }
            tokens.append(Token(value: value, kind: kind, lineBreakBefore: pendingLineBreak))
            pendingLineBreak = false
            return true
        }

        func isLineTerminator(_ character: Character) -> Bool {
            character == "\n" || character == "\r" ||
                character == "\u{2028}" || character == "\u{2029}"
        }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                if isLineTerminator(character) { pendingLineBreak = true }
                index += 1
                continue
            }

            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                index += 2
                while index < characters.count, !isLineTerminator(characters[index]) { index += 1 }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    if isLineTerminator(characters[index]) { pendingLineBreak = true }
                    index += 1
                }
                guard index + 1 < characters.count else { structurallyInvalid = true; break }
                index += 2
                continue
            }

            if character == "\"" || character == "'" {
                let quote = character
                var value = ""
                var closed = false
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    if current == "\n" || current == "\r" {
                        index = characters.count
                        break
                    }
                    if current == quote { closed = true; index += 1; break }
                    if current == "\\" {
                        index += 1
                        guard index < characters.count else { break }
                        switch characters[index] {
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        case "b": value.append("\u{08}")
                        case "f": value.append("\u{0C}")
                        case "v": value.append("\u{0B}")
                        case "\\", "'", "\"", "/": value.append(characters[index])
                        default:
                            closed = false
                            index = characters.count
                            continue
                        }
                    } else {
                        value.append(current)
                    }
                    index += 1
                }
                guard closed else { structurallyInvalid = true; break }
                guard append(value, .string) else { wasLimited = true; break }
                continue
            }

            if character == "`" {
                index += 1
                var escaped = false
                var closed = false
                var hasInterpolation = false
                var hasUnverifiedEscape = false
                while index < characters.count {
                    let current = characters[index]
                    if escaped { escaped = false; index += 1; continue }
                    if current == "\\" {
                        hasUnverifiedEscape = true
                        escaped = true
                        index += 1
                        continue
                    }
                    if current == "$", index + 1 < characters.count, characters[index + 1] == "{" {
                        hasInterpolation = true
                    }
                    if current == "`" { closed = true; index += 1; break }
                    index += 1
                }
                guard closed else { structurallyInvalid = true; break }
                guard !hasUnverifiedEscape else { structurallyInvalid = true; break }
                let value = hasInterpolation ? "<template-expression>" : "<template>"
                guard append(value, .opaque) else { wasLimited = true; break }
                continue
            }

            if character == "/" {
                index += 1
                var pattern = ""
                var escaped = false
                var inCharacterClass = false
                var closed = false
                while index < characters.count {
                    let current = characters[index]
                    if escaped {
                        pattern.append(current)
                        escaped = false
                        index += 1
                        continue
                    }
                    if current == "\\" {
                        pattern.append(current)
                        escaped = true
                        index += 1
                        continue
                    }
                    if current == "[" { inCharacterClass = true }
                    if current == "]" { inCharacterClass = false }
                    if current == "/", !inCharacterClass { closed = true; index += 1; break }
                    if isLineTerminator(current) { break }
                    pattern.append(current)
                    index += 1
                }
                guard closed else { structurallyInvalid = true; break }
                let flagsStart = index
                while index < characters.count, characters[index].isLetter { index += 1 }
                let flags = String(characters[flagsStart..<index])
                guard isStructurallyValidRegex(pattern, flags: flags) else {
                    structurallyInvalid = true
                    break
                }
                guard append("<regex>", .opaque) else { wasLimited = true; break }
                continue
            }

            if character.isLetter || character.isNumber || character == "_" || character == "$" {
                let start = index
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber ||
                      characters[index] == "_" || characters[index] == "$" { index += 1 }
                guard append(String(characters[start..<index]), .identifier) else { wasLimited = true; break }
                continue
            }

            let four = index + 3 < characters.count ? String(characters[index...index + 3]) : ""
            if four == ">>>=" {
                guard append(four, .punctuation) else { wasLimited = true; break }
                index += 4
                continue
            }
            let three = index + 2 < characters.count ? String(characters[index...index + 2]) : ""
            if ["...", "&&=", "||=", "??=", "<<=", ">>=", "**="].contains(three) {
                guard append(three, .punctuation) else { wasLimited = true; break }
                index += 3
                continue
            }
            let pair = index + 1 < characters.count ? String(characters[index...index + 1]) : ""
            if [
                "&&", "||", "=>", "??", "?.", "==", "!=", "<=", ">=", "++", "--",
                "+=", "-=", "*=", "%=", "&=", "|=", "^=", "<<", ">>", "**",
            ].contains(pair) {
                guard append(pair, .punctuation) else { wasLimited = true; break }
                index += 2
                continue
            }
            guard append(String(character), .punctuation) else { wasLimited = true; break }
            index += 1
        }
        return Tokenization(tokens: tokens, wasLimited: wasLimited, structurallyInvalid: structurallyInvalid)
    }
}
