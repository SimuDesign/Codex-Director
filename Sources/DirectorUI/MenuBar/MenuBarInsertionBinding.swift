import SwiftUI
import DirectorCore

/// The single insertion binding used by the app's MenuBarExtra.
///
/// Keeping the binding at the app-scoped preference boundary is important:
/// reading the nested model alone does not invalidate a Scene when Settings
/// changes the shared preference. The explicit read below registers the
/// observable dependency while the getter remains live for an in-flight
/// toggle.
@MainActor
public enum MenuBarInsertionBinding {
    public static func make(
        preferences: MenuBarPreferences,
        model: DirectorAppModel
    ) -> Binding<Bool> {
        _ = preferences.isEnabled
        return Binding(
            get: { preferences.isEnabled },
            set: { model.setMenuBarEnabled($0) }
        )
    }
}
