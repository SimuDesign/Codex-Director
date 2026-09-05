/// Parser and index coverage state for a session or an assessment.
public enum CoverageState: String, Codable, Sendable, CaseIterable {
    /// All expected evidence was parsed.
    case complete
    /// Some expected evidence was parsed; gaps are known.
    case partial
    /// No evidence could be obtained.
    case unavailable
    /// Coverage could not be determined.
    case unknown

    /// Conservative merge for incremental indexing:
    /// `partial` dominates `complete`; `unavailable`/`unknown` never become
    /// `complete` without a full reparse.
    public static func mergedCoverage(_ prior: CoverageState, _ new: CoverageState) -> CoverageState {
        if prior == .complete && new == .complete { return .complete }
        if prior == .partial || new == .partial { return .partial }
        if prior == .unavailable || new == .unavailable { return .unavailable }
        return .unknown
    }
}
