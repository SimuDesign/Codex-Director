import CoreGraphics

/// Table layout metrics for dense native macOS tables.
///
/// The capability name column keeps a readable default width for the common
/// three-word Skill naming convention while retaining a bounded minimum and
/// maximum so the surrounding table can scroll horizontally when necessary.
public enum DirectorTableMetrics {
    public static let capabilityNameMinimumWidth: CGFloat = 240
    public static let capabilityNameIdealWidth: CGFloat = 280
    public static let capabilityNameMaximumWidth: CGFloat = 360
}
