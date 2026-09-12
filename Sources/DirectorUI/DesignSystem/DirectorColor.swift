import SwiftUI
import AppKit
import DirectorCore

/// Design-system color tokens (DESIGN_SYSTEM_V1 §6).
/// Dynamic system colors only; no fixed RGB/hex values without an approved
/// token change.
public enum DirectorColor {
    // MARK: Foundation tokens

    public static let window = Color(nsColor: .windowBackgroundColor)
    public static let content = Color(nsColor: .textBackgroundColor)
    public static let raised = Color(nsColor: .controlBackgroundColor)
    public static let selection = Color(nsColor: .selectedContentBackgroundColor)
    public static let textPrimary = Color(nsColor: .labelColor)
    public static let textSecondary = Color(nsColor: .secondaryLabelColor)
    public static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    /// Supporting metadata remains subordinate to primary content while
    /// retaining enough contrast for source, state, time and unit labels.
    /// Tertiary text is reserved for optional decoration.
    public static let textSupporting = dynamic(
        light: NSColor(red: 0x45 / 255, green: 0x56 / 255, blue: 0x61 / 255, alpha: 1),
        dark: NSColor(red: 0xB7 / 255, green: 0xC8 / 255, blue: 0xCF / 255, alpha: 1)
    )
    public static let separator = Color(nsColor: .separatorColor)
    public static let focus = Color(nsColor: .keyboardFocusIndicatorColor)
    public static let accent = Color.accentColor

    // Shared opaque canvas/panel language promoted from the approved Home
    // refresh. Content surfaces remain opaque; Liquid Glass is reserved for
    // navigation and controls.
    public static let canvas = dynamic(light: NSColor(red: 0xF3 / 255, green: 0xF6 / 255, blue: 0xF8 / 255, alpha: 1), dark: NSColor(red: 0x09 / 255, green: 0x0F / 255, blue: 0x13 / 255, alpha: 1))
    public static let panel = dynamic(light: .white, dark: NSColor(red: 0x11 / 255, green: 0x1A / 255, blue: 0x20 / 255, alpha: 1))
    public static let inset = dynamic(light: NSColor(red: 0xEA / 255, green: 0xF1 / 255, blue: 0xF5 / 255, alpha: 1), dark: NSColor(red: 0x15 / 255, green: 0x22 / 255, blue: 0x2B / 255, alpha: 1))
    /// Shared input surface. The translucent white wash keeps search and
    /// single-select controls visually related without turning content into
    /// glass; Reduce Transparency consumers fall back to `inset`.
    public static let controlField = dynamic(
        light: NSColor(white: 1, alpha: 0.72),
        dark: NSColor(white: 1, alpha: 0.08)
    )
    public static let boundary = dynamic(light: NSColor(red: 0xCA / 255, green: 0xD7 / 255, blue: 0xDF / 255, alpha: 1), dark: NSColor(red: 0x34 / 255, green: 0x46 / 255, blue: 0x50 / 255, alpha: 1))
    public static let emphasis = dynamic(light: NSColor(red: 0x00 / 255, green: 0x6B / 255, blue: 0x83 / 255, alpha: 1), dark: NSColor(red: 0x5F / 255, green: 0xD7 / 255, blue: 0xEE / 255, alpha: 1))
    /// Ambient-only field colors. They are deliberately quieter than text
    /// accents so the environment can be felt without competing with data.
    public static let environmentStrong = dynamic(light: NSColor(red: 0xD9 / 255, green: 0xEE / 255, blue: 0xF0 / 255, alpha: 1), dark: NSColor(red: 0x0C / 255, green: 0x3E / 255, blue: 0x4B / 255, alpha: 1))
    public static let environmentDeep = dynamic(light: NSColor(red: 0xF3 / 255, green: 0xF6 / 255, blue: 0xF8 / 255, alpha: 1), dark: NSColor(red: 0x05 / 255, green: 0x0B / 255, blue: 0x10 / 255, alpha: 1))

    // Scheme A accents. These are the only fixed accent values in the UI;
    // views consume them through `DirectorAccentTone` and never declare RGB
    // colors themselves. Dark-mode teal must remain readable as data text;
    // the deeper environment colors remain separate ambient-only tokens.
    public static let accentBlue = dynamic(light: NSColor(red: 0x08 / 255, green: 0x79 / 255, blue: 0xD9 / 255, alpha: 1), dark: NSColor(red: 0x15 / 255, green: 0x9D / 255, blue: 0xFF / 255, alpha: 1))
    public static let accentIce = dynamic(light: NSColor(red: 0x11 / 255, green: 0x8E / 255, blue: 0xAE / 255, alpha: 1), dark: NSColor(red: 0x49 / 255, green: 0xCA / 255, blue: 0xFF / 255, alpha: 1))
    public static let accentMint = dynamic(light: NSColor(red: 0x14 / 255, green: 0x8F / 255, blue: 0x7E / 255, alpha: 1), dark: NSColor(red: 0x79 / 255, green: 0xEA / 255, blue: 0xD8 / 255, alpha: 1))
    public static let accentTeal = dynamic(light: NSColor(red: 0x00 / 255, green: 0x6B / 255, blue: 0x83 / 255, alpha: 1), dark: NSColor(red: 0x5F / 255, green: 0xD7 / 255, blue: 0xEE / 255, alpha: 1))
    /// Small data labels use a dedicated readable text role instead of a
    /// visualization fill endpoint. The endpoint remains an accent for bars,
    /// rings and other non-text marks.
    public static let dataText = dynamic(
        light: NSColor(red: 0x00 / 255, green: 0x6B / 255, blue: 0x83 / 255, alpha: 1),
        dark: NSColor(red: 0x5F / 255, green: 0xD7 / 255, blue: 0xEE / 255, alpha: 1)
    )
    public static let emphasisText = accentBlue
    public static let environmentLight = accentTeal.opacity(0.14)

    // Action controls intentionally have their own stops. Light mode uses a
    // deeper opaque rail so a white label and SF Symbol remain readable. Dark
    // mode keeps the existing bright rail with black content.
    public static let actionBlue = dynamic(
        light: NSColor(red: 0x00 / 255, green: 0x65 / 255, blue: 0xB3 / 255, alpha: 1),
        dark: NSColor(red: 0x15 / 255, green: 0x9D / 255, blue: 0xFF / 255, alpha: 1)
    )
    public static let actionIce = dynamic(
        light: NSColor(red: 0x00 / 255, green: 0x73 / 255, blue: 0x8B / 255, alpha: 1),
        dark: NSColor(red: 0x49 / 255, green: 0xCA / 255, blue: 0xFF / 255, alpha: 1)
    )
    public static let actionMint = dynamic(
        light: NSColor(red: 0x08 / 255, green: 0x77 / 255, blue: 0x65 / 255, alpha: 1),
        dark: NSColor(red: 0x79 / 255, green: 0xEA / 255, blue: 0xD8 / 255, alpha: 1)
    )
    public static let actionHoverBlue = dynamic(
        light: NSColor(red: 0x00 / 255, green: 0x58 / 255, blue: 0x9D / 255, alpha: 1),
        dark: NSColor(red: 0x1F / 255, green: 0xA6 / 255, blue: 0xFF / 255, alpha: 1)
    )
    public static let actionHoverIce = dynamic(
        light: NSColor(red: 0x00 / 255, green: 0x66 / 255, blue: 0x7B / 255, alpha: 1),
        dark: NSColor(red: 0x56 / 255, green: 0xD1 / 255, blue: 0xFF / 255, alpha: 1)
    )
    public static let actionHoverMint = dynamic(
        light: NSColor(red: 0x06 / 255, green: 0x69 / 255, blue: 0x56 / 255, alpha: 1),
        dark: NSColor(red: 0x86 / 255, green: 0xF0 / 255, blue: 0xDF / 255, alpha: 1)
    )
    public static let actionPressedBlue = dynamic(
        light: NSColor(red: 0x00 / 255, green: 0x4F / 255, blue: 0x8E / 255, alpha: 1),
        dark: NSColor(red: 0x0C / 255, green: 0x89 / 255, blue: 0xE0 / 255, alpha: 1)
    )
    public static let actionPressedIce = dynamic(
        light: NSColor(red: 0x00 / 255, green: 0x5B / 255, blue: 0x6E / 255, alpha: 1),
        dark: NSColor(red: 0x3D / 255, green: 0xB8 / 255, blue: 0xEC / 255, alpha: 1)
    )
    public static let actionPressedMint = dynamic(
        light: NSColor(red: 0x05 / 255, green: 0x5B / 255, blue: 0x4A / 255, alpha: 1),
        dark: NSColor(red: 0x6C / 255, green: 0xD7 / 255, blue: 0xC7 / 255, alpha: 1)
    )
    /// Disabled actions use a fully opaque neutral rail. Their foreground
    /// stays solid white in Light and black in Dark, preserving text contrast
    /// while the loss of chroma communicates that the action is unavailable.
    public static let actionDisabledBlue = dynamic(
        light: NSColor(red: 0x52 / 255, green: 0x63 / 255, blue: 0x6C / 255, alpha: 1),
        dark: NSColor(red: 0x8A / 255, green: 0x95 / 255, blue: 0x9C / 255, alpha: 1)
    )
    public static let actionDisabledIce = dynamic(
        light: NSColor(red: 0x59 / 255, green: 0x68 / 255, blue: 0x6B / 255, alpha: 1),
        dark: NSColor(red: 0x98 / 255, green: 0xA2 / 255, blue: 0xA6 / 255, alpha: 1)
    )
    public static let actionDisabledMint = dynamic(
        light: NSColor(red: 0x5A / 255, green: 0x69 / 255, blue: 0x65 / 255, alpha: 1),
        dark: NSColor(red: 0xA5 / 255, green: 0xAC / 255, blue: 0xA8 / 255, alpha: 1)
    )
    public static let primaryActionForeground = dynamic(light: .white, dark: .black)
    public static let primaryActionBoundary = actionIce
    public static let primaryActionShadow = actionMint
    /// Navigation retains the original brand rail in both themes, so its
    /// selected label and symbol keep a stable black foreground independent
    /// of the filled action control contract.
    public static let navigationSelectedForeground = Color.black

    public static func accent(_ tone: DirectorAccentTone) -> Color {
        switch tone {
        case .blue: return accentBlue
        case .ice: return accentIce
        case .mint: return accentMint
        case .teal: return accentTeal
        }
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Runtime status tokens (§6.2)

    public static func status(_ status: RuntimeStatus) -> Color {
        switch status {
        case .idle: return Color(nsColor: .systemGray)
        case .running: return Color(nsColor: .systemBlue)
        case .success: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .failure: return Color(nsColor: .systemRed)
        case .blocked: return Color(nsColor: .systemPurple)
        case .unknown: return Color(nsColor: .secondaryLabelColor)
        }
    }

    // MARK: Resource-type tokens (§6.3)

    public static func resource(_ kind: ResourceKind) -> Color {
        switch kind {
        case .agent: return Color(nsColor: .systemIndigo)
        case .skill: return Color(nsColor: .systemBlue)
        case .instruction: return Color(nsColor: .systemGray)
        case .workflow: return Color(nsColor: .systemTeal)
        case .tool: return Color(nsColor: .systemCyan)
        case .plugin: return Color(nsColor: .systemPurple)
        case .mcp: return Color(nsColor: .systemMint)
        case .app: return Color(nsColor: .systemPink)
        case .hook: return Color(nsColor: .systemOrange)
        case .output: return Color(nsColor: .systemGreen)
        case .unknown: return Color(nsColor: .systemGray)
        }
    }
}
