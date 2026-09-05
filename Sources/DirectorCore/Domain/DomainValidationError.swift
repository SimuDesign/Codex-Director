import Foundation

/// Validation failures rejected at Domain construction and decoding boundaries.
public enum DomainValidationError: Error, Sendable, Equatable, LocalizedError {
    case negativeTokenCount
    case nonFinitePercentage
    case invalidWindowMinutes

    public var errorDescription: String? {
        switch self {
        case .negativeTokenCount:
            return "Token counts must be non-negative."
        case .nonFinitePercentage:
            return "Percentages must be finite."
        case .invalidWindowMinutes:
            return "Window minutes must be positive."
        }
    }
}
