import CoreGraphics
import DirectorCore

/// Semantic labels and patterns so state is never communicated by color alone
/// (DESIGN_SYSTEM_V1 §3.4, §6.4).
public enum DirectorSemanticStyle {

    public static func statusLabel(_ status: RuntimeStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .running: return "Running"
        case .success: return "Success"
        case .warning: return "Warning"
        case .failure: return "Failure"
        case .blocked: return "Blocked"
        case .unknown: return "Unknown"
        }
    }

    public static func statusLabel(_ status: RuntimeStatus, localizer: DirectorLocalizer) -> String {
        localizer.enumLabel(LocalizedEnumValue(key: "status.\(status.rawValue)", fallback: statusLabel(status)))
    }

    public static func confidenceLabel(_ confidence: EvidenceConfidence) -> String {
        switch confidence {
        case .exact: return "Exact"
        case .inferred: return "Inferred"
        case .unknown: return "Unknown"
        }
    }

    public static func confidenceLabel(_ confidence: EvidenceConfidence, localizer: DirectorLocalizer) -> String {
        localizer.enumLabel(LocalizedEnumValue(key: "confidence.\(confidence.rawValue)", fallback: confidenceLabel(confidence)))
    }

    public static func confidenceSymbol(_ confidence: EvidenceConfidence) -> String {
        switch confidence {
        case .exact: return "checkmark.circle"
        case .inferred: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Line dash pattern for topology edges: solid / dashed / dotted.
    public static func confidenceLineDash(_ confidence: EvidenceConfidence) -> [CGFloat] {
        switch confidence {
        case .exact: return []
        case .inferred: return [5, 4]
        case .unknown: return [1, 4]
        }
    }
}
