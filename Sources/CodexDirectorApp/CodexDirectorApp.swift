import SwiftUI
import DirectorUI
import DirectorCore

private final class LaunchMemoryPreferences: @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func data(for key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data, for key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

@MainActor
private final class AppLaunchState: ObservableObject {
    @Published private(set) var model: DirectorAppModel
    private let startupController: DirectorStartupController

    init(useMemoryPreferences: Bool = false) {
        // This model is deliberately service-less but not synthetic. It lets
        // the main window and all six destinations render immediately while
        // the real container is opened off the main actor.
        if useMemoryPreferences {
            let preferences = LaunchMemoryPreferences()
            model = DirectorAppModel(
                classificationOverrides: ResourceClassificationOverrideStore(
                    readData: { preferences.data(for: ResourceClassificationOverrideStore.defaultsKey) },
                    writeData: { preferences.set($0, for: ResourceClassificationOverrideStore.defaultsKey) },
                    removeData: { preferences.remove(ResourceClassificationOverrideStore.defaultsKey) }
                ),
                evaluationStore: InvocationEvaluationStore(
                    readData: { preferences.data(for: InvocationEvaluationStore.defaultsKey) },
                    writeData: { preferences.set($0, for: InvocationEvaluationStore.defaultsKey); return true },
                    removeData: { preferences.remove(InvocationEvaluationStore.defaultsKey); return true }
                ),
                previewMode: false,
                bootstrapPending: true
            )
        } else {
            model = DirectorAppModel(previewMode: false, bootstrapPending: true)
        }
        startupController = DirectorStartupController(
            cacheFactory: {
                await AppContainer.cacheStoreWithoutDatabase()
            },
            servicesFactory: {
                let container = await AppContainer.bootstrapAsync()
                return DirectorStartupServices(
                    store: container.store,
                    readStore: container.readStore,
                    coordinator: container.coordinator,
                    configuration: container.configuration,
                    snapshotStore: nil,
                    capabilityExportCoordinator: container.capabilityExportCoordinator,
                    safeError: container.bootstrapError
                )
            }
        )
    }

    func bootstrap() {
        startupController.start(model: model)
    }
}

/// Codex Director — local AI capability management and observability.
@main
struct CodexDirectorApp: App {
    private let validationMode: Bool
    @StateObject private var languageStore: AppLanguageStore
    @StateObject private var themeStore: AppThemeStore
    @StateObject private var launchState: AppLaunchState

    init() {
#if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "DirectorUIValidationMode") as? Bool == true {
            validationMode = true
            _languageStore = StateObject(wrappedValue: AppLanguageStore(memoryLanguage: .simplifiedChinese))
            _themeStore = StateObject(wrappedValue: AppThemeStore(memoryTheme: .dark))
            _launchState = StateObject(wrappedValue: AppLaunchState(useMemoryPreferences: true))
            return
        }
#endif
        validationMode = false
        _languageStore = StateObject(wrappedValue: AppLanguageStore(defaults: .standard))
        _themeStore = StateObject(wrappedValue: AppThemeStore(defaults: .standard))
        _launchState = StateObject(wrappedValue: AppLaunchState())
    }

    var body: some Scene {
        WindowGroup(validationMode ? "Codex Director Validation" : DirectorUI.productName) {
            Group {
#if DEBUG
            if validationMode {
                UIValidationHost(languageStore: languageStore, themeStore: themeStore)
            } else {
                DirectorRootView(model: launchState.model)
                    .preferredColorScheme(themeStore.theme.colorScheme)
            }
#else
            DirectorRootView(model: launchState.model)
                .preferredColorScheme(themeStore.theme.colorScheme)
#endif
            }
            .task {
                if !validationMode { launchState.bootstrap() }
            }
        }
        .environmentObject(languageStore)
        .environmentObject(themeStore)
        .defaultSize(width: 1280, height: 800)
    }
}
