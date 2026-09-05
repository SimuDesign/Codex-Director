import Foundation

/// Design-system motion tokens (DESIGN_SYSTEM_V1 §10).
/// Views must honor Reduce Motion by replacing travel/morphing with opacity
/// transitions or immediate state changes.
public enum DirectorMotion {
    /// Hover and tiny feedback.
    public static let instant: TimeInterval = 0.12
    /// Selection and disclosure.
    public static let standard: TimeInterval = 0.2
    /// Inspector or overlay transition.
    public static let emphasized: TimeInterval = 0.32
    /// User-requested invocation playback, per meaningful step.
    public static let narrativeStep: TimeInterval = 0.48
}
