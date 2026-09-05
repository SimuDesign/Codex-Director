import SwiftUI

/// Design-system shape tokens (DESIGN_SYSTEM_V1 §8.2).
/// Native Liquid Glass and system controls keep their own shapes.
public enum DirectorRadius {
    public static let compact: CGFloat = 6
    public static let control: CGFloat = 8
    public static let panel: CGFloat = 12
    public static let floating: CGFloat = 16
    public static let contentPanel: CGFloat = 12
    public static let metric: CGFloat = 12
    public static let ribbon: CGFloat = 10
    public static let hero: CGFloat = 16
    /// Approved outer outline for the Home Card Atlas modules. This is a
    /// Home-only presentation role and does not replace other page panels.
    public static let homeModule: CGFloat = 18
    /// System capsule shape for status pills and suitable top-level controls.
    public static let capsule = Capsule()
}
