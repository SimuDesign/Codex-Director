import Foundation

/// The deterministic Review Lite rule set.
public enum IntegrityRules {
    /// All MVP1 rules in evaluation order. Rule 5 stays disabled.
    public static let all: [ReviewRule] = [
        MissingSourceRule(),
        UnmatchedResultRule(),
        ParserCoverageRule(),
        StaleQuotaRule(),
        DisabledReviewGateRule(),
    ]

    public static func evaluate(
        context: ReviewContext,
        rules: [ReviewRule] = all
    ) -> [ReviewFinding] {
        rules.flatMap { $0.evaluate(context: context) }
    }
}

/// Rule 1: a declared resource source root or manifest file is missing.
public struct MissingSourceRule: ReviewRule {
    public let id = "rule.missing-source"
    public let name = "Declared source is missing or unavailable"
    public let applicability = "Resources whose declared source root or manifest file no longer exists."

    public func evaluate(context: ReviewContext) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        for resource in context.resources {
            guard let relativePath = resource.relativeSourcePath else { continue }
            guard let root = context.scanRoots.first(where: { $0.id == resource.sourceRootID }) else { continue }
            let sourceURL = root.url.appendingPathComponent(relativePath)
            if !context.fileSystem.exists(sourceURL) {
                findings.append(makeFinding(
                    ruleID: id,
                    resourceID: resource.id,
                    sessionID: nil,
                    severity: .warning,
                    summary: "Declared source is missing or unavailable",
                    evidenceSummary: "\(resource.sourceRootID)/\(relativePath) does not exist",
                    coverage: .complete,
                    confidence: .exact,
                    createdAt: context.now
                ))
            }
        }
        return findings
    }
}

/// Rule 2: an invocation has no matching result, and coverage is sufficient
/// to state that fact.
public struct UnmatchedResultRule: ReviewRule {
    public let id = "rule.unmatched-result"
    public let name = "Invocation without a matching result"
    public let applicability = "Calls in sessions with complete coverage whose status is started or unknown."

    public func evaluate(context: ReviewContext) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        for session in context.sessions where session.coverage == .complete {
            for call in context.invocationsBySession[session.id] ?? []
            where call.status == .started || call.status == .unknown {
                findings.append(makeFinding(
                    ruleID: id,
                    resourceID: call.resourceID,
                    sessionID: session.id,
                    severity: .warning,
                    summary: "Invocation has no matching result",
                    evidenceSummary: "\(call.id) (\(call.resourceID ?? call.kind.rawValue)) ended with status \(call.status.rawValue)",
                    coverage: .complete,
                    confidence: .exact,
                    createdAt: context.now
                ))
            }
        }
        return findings
    }
}

/// Rule 3: the parser encountered unsupported or malformed evidence.
public struct ParserCoverageRule: ReviewRule {
    public let id = "rule.parser-coverage"
    public let name = "Parser encountered unsupported or malformed evidence"
    public let applicability = "Sessions whose index coverage is partial."

    public func evaluate(context: ReviewContext) -> [ReviewFinding] {
        context.sessions
            .filter { $0.coverage == .partial }
            .map { session in
                makeFinding(
                    ruleID: id,
                    resourceID: nil,
                    sessionID: session.id,
                    severity: .info,
                    summary: "Parser encountered unsupported or malformed evidence",
                    evidenceSummary: "Session coverage is partial; some lines or event types were not indexed",
                    coverage: .partial,
                    confidence: .exact,
                    createdAt: context.now
                )
            }
    }
}

/// Rule 4: the rate-limit snapshot is stale or past its reset without refresh.
public struct StaleQuotaRule: ReviewRule {
    public let id = "rule.stale-quota"
    public let name = "Rate-limit snapshot is stale or past reset"
    public let applicability = "The newest reported weekly allowance window whose reset time has passed."

    public func evaluate(context: ReviewContext) -> [ReviewFinding] {
        guard let weekly = context.quotaSnapshots.filter(\.isWeeklyWindow)
            .max(by: { $0.capturedAt < $1.capturedAt }),
            weekly.isExpired(at: context.now) else {
            return []
        }
        return [makeFinding(
            ruleID: id,
            resourceID: nil,
            sessionID: nil,
            severity: .warning,
            summary: "Rate-limit snapshot is stale or past reset without refresh",
            evidenceSummary: "Weekly window reset \(weekly.resetsAt.map { $0.formatted() } ?? "unknown") passed and no newer snapshot exists",
            coverage: .complete,
            confidence: .exact,
            createdAt: context.now
        )]
    }
}

/// Rule 5: an explicit structured review requirement is missing from an
/// otherwise complete execution path.
///
/// DISABLED in MVP1: it must remain off unless a structured, project-sourced
/// requirement can be extracted without interpreting Prompt text or asking an
/// LLM to judge behavior.
public struct DisabledReviewGateRule: ReviewRule {
    public let id = "rule.review-gate"
    public let name = "Structured review requirement missing"
    public let applicability = "Disabled: requires a structured project-sourced requirement that MVP1 does not extract."

    public func evaluate(context: ReviewContext) -> [ReviewFinding] {
        []
    }
}
