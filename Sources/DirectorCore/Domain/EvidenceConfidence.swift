/// Evidence confidence for every recorded fact.
///
/// `exact` requires a structured, verifiable event. `inferred` is derived from
/// multiple signals. `unknown` means evidence is insufficient. An `inferred`
/// or `unknown` value must never be upgraded to `exact`.
public enum EvidenceConfidence: String, Codable, Sendable, CaseIterable {
    case exact
    case inferred
    case unknown
}
