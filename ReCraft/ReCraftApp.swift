import AppKit
import Combine
import SwiftUI

@main
struct ReCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!appDelegate.isRunningUnitTests)) {
            if !appDelegate.isRunningUnitTests {
                MenuContentView(
                    coordinator: appDelegate.coordinator,
                    apiKeySettings: appDelegate.apiKeySettings,
                    taskSettings: appDelegate.taskSettings
                )
            }
        } label: {
            Label(
                "ReCraft",
                systemImage: appDelegate.coordinator.menuBarIconName
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            if !appDelegate.isRunningUnitTests {
                TabView {
                    RewriteTaskSettingsView(
                        model: appDelegate.taskSettings,
                        providerSettings: appDelegate.apiKeySettings
                    )
                        .tabItem {
                            Label("Rewrite Tasks", systemImage: "text.badge.checkmark")
                        }

                    APIKeySettingsView(model: appDelegate.apiKeySettings)
                        .tabItem {
                            Label("API Key", systemImage: "key")
                        }
                }
                .frame(width: 760, height: 540)
                .background {
                    SettingsWindowCloseObserver {
                        appDelegate.taskSettings.settingsWindowDidClose()
                    }
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: AppCoordinator
    let apiKeySettings: ProviderAPIKeySettingsModel
    let taskSettings: RewriteTaskSettingsModel
    let isRunningUnitTests: Bool

    static func isUnitTestHost(environment: [String: String]) -> Bool {
        // Only Xcode's Debug XCTest host may suppress normal App behavior.
        // Benchmark opt-ins never select an alternate shipping runtime.
        #if DEBUG
        environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    override init() {
        let isRunningUnitTests = Self.isUnitTestHost(
            environment: ProcessInfo.processInfo.environment
        )
        let providerSetting = RewriteProviderSetting()
        let openAIKeyStore = KeychainAPIKeyStore(provider: .openai)
        let claudeKeyStore = KeychainAPIKeyStore(provider: .claude)
        let hotKeyRegistry = RewriteTaskHotKeyRegistry()
        let persistence = RewriteTaskCatalogPersistence(
            store: UserDefaultsRewriteTaskCatalogStore()
        )
        let taskSettings = RewriteTaskSettingsModel(
            persistence: persistence,
            activator: hotKeyRegistry,
            shortcutRecorder: hotKeyRegistry,
            promptGenerator: TaskPromptGenerator(
                providerSetting: providerSetting,
                openAIKeyStore: openAIKeyStore,
                claudeKeyStore: claudeKeyStore
            ),
            loadImmediately: !isRunningUnitTests
        )

        self.isRunningUnitTests = isRunningUnitTests
        self.apiKeySettings = ProviderAPIKeySettingsModel(
            setting: providerSetting,
            claudeKeyStore: claudeKeyStore,
            openAIKeyStore: openAIKeyStore
        )
        self.taskSettings = taskSettings
        coordinator = AppCoordinator(
            rewriter: CodingPromptRewriter(
                providerSetting: providerSetting,
                openAIKeyStore: openAIKeyStore,
                claudeKeyStore: claudeKeyStore
            ),
            providerSetting: providerSetting,
            hotKeyRegistry: hotKeyRegistry,
            taskSettings: taskSettings
        )
        super.init()
        guard !isRunningUnitTests else { return }
        taskSettings.onRuntimeStateChange = { [weak coordinator] in
            coordinator?.refreshTaskConfigurationStatus()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnitTests else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        #if DEBUG
        DebugFocusProbe.startIfRequested(arguments: ProcessInfo.processInfo.arguments)
        // A poster-only instance drives another running instance; it must not
        // register the shortcuts itself.
        DebugFocusProbe.postHotKeysIfRequested(arguments: ProcessInfo.processInfo.arguments)
        if ProcessInfo.processInfo.arguments.contains("--debug-poster-only") { return }
        #endif
        coordinator.start()
        Task {
            await apiKeySettings.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isRunningUnitTests else { return }
        coordinator.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningUnitTests else { return .terminateNow }
        guard !coordinator.shouldRefuseTermination else {
            coordinator.refuseQuitWhileProcessing()
            return .terminateCancel
        }
        return .terminateNow
    }
}

private struct MenuContentView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var apiKeySettings: ProviderAPIKeySettingsModel
    @ObservedObject var taskSettings: RewriteTaskSettingsModel

    var body: some View {
        Text("ReCraft")
        Text("Clipboard copy → rewrite → paste")
        Text(coordinator.statusMessage)

        Divider()

        Text(coordinator.accessibilityGranted ? "Accessibility: Granted" : "Accessibility: Required")

        if coordinator.accessibilityGranted {
            Button("Refresh Permission Status") {
                coordinator.refreshAccessibilityStatus()
            }
        } else {
            Button("Grant Accessibility Access…") {
                coordinator.requestAccessibilityAccess()
            }
        }

        Divider()

        Text("Test replacement: ⌃⌥⌘R")
        if taskSettings.isBlockingFailure {
            Text("Rewrite task shortcuts blocked; quit and relaunch")
        } else if !taskSettings.activeDisplayTasks.isEmpty {
            ForEach(taskSettings.activeDisplayTasks) { task in
                Text("\(task.name): \(HotKeyDisplayLabel.make(for: task.shortcut))")
            }
        } else {
            Text("No rewrite task shortcuts configured")
        }

        Divider()

        Text("Rewrite provider: \(apiKeySettings.selectedProvider.displayName)")
        Text(
            apiKeySettings.isConfigured
                ? "\(apiKeySettings.selectedProvider.displayName) API Key: Configured"
                : "\(apiKeySettings.selectedProvider.displayName) API Key: Not configured"
        )
        Button("Settings…") {
            Task { @MainActor in
                await Task.yield()
                NSApplication.shared.activate()
                openSettings()
            }
        }

        if let registrationError = coordinator.hotKeyRegistrationError {
            Text("Shortcut unavailable: \(registrationError)")
        }

        Divider()

        if coordinator.shouldRefuseTermination {
            Text("Replacement in progress")
        } else {
            Button("Quit ReCraft") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

@MainActor
final class APIKeySettingsModel: ObservableObject {
    @Published var draftKey = ""
    @Published private(set) var isConfigured = false
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?

    private let store: any APIKeyStoring

    init(store: any APIKeyStoring) {
        self.store = store
    }

    func refresh() async {
        do {
            isConfigured = try await store.containsKey()
            statusMessage = nil
        } catch {
            isConfigured = false
            statusMessage = "Keychain unavailable"
        }
    }

    func save() async {
        let normalized = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            statusMessage = "Enter an API key"
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            try await store.saveKey(normalized)
            draftKey = ""
            isConfigured = true
            statusMessage = "API key saved"
        } catch {
            statusMessage = "API key could not be saved"
        }
    }

    func delete() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.deleteKey()
            draftKey = ""
            isConfigured = false
            statusMessage = "API key deleted"
        } catch {
            statusMessage = "API key could not be deleted"
        }
    }

    func clearDraft() {
        draftKey = ""
    }
}

/// The global provider choice plus one Keychain key model per provider.
/// The menu and status reflect the key of the currently selected provider.
@MainActor
final class ProviderAPIKeySettingsModel: ObservableObject {
    @Published private(set) var selectedProvider: RewriteProvider
    let claudeKey: APIKeySettingsModel
    let openAIKey: APIKeySettingsModel

    private let setting: RewriteProviderSetting
    private var childObservations: [AnyCancellable] = []

    init(
        setting: RewriteProviderSetting,
        claudeKeyStore: any APIKeyStoring,
        openAIKeyStore: any APIKeyStoring
    ) {
        self.setting = setting
        selectedProvider = setting.current
        claudeKey = APIKeySettingsModel(store: claudeKeyStore)
        openAIKey = APIKeySettingsModel(store: openAIKeyStore)
        for child in [claudeKey, openAIKey] {
            childObservations.append(
                child.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
            )
        }
    }

    var isConfigured: Bool {
        keyModel(for: selectedProvider).isConfigured
    }

    var statusMessage: String? {
        keyModel(for: selectedProvider).statusMessage
    }

    func keyModel(for provider: RewriteProvider) -> APIKeySettingsModel {
        switch provider {
        case .claude:
            claudeKey
        case .openai:
            openAIKey
        }
    }

    /// Persists immediately; the next shortcut uses the new provider.
    func select(_ provider: RewriteProvider) {
        setting.select(provider)
        selectedProvider = provider
    }

    func refresh() async {
        selectedProvider = setting.current
        await claudeKey.refresh()
        await openAIKey.refresh()
    }

    func clearDrafts() {
        claudeKey.clearDraft()
        openAIKey.clearDraft()
    }
}

private struct APIKeySettingsView: View {
    @ObservedObject var model: ProviderAPIKeySettingsModel
    @State private var providerPendingDeletion: RewriteProvider?

    var body: some View {
        Form {
            Section("Rewrite Provider") {
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { model.selectedProvider },
                        set: { model.select($0) }
                    )
                ) {
                    ForEach(RewriteProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                Text("Rewrite task shortcuts send requests only to \(model.selectedProvider.displayName), using its API key. ReCraft never falls back to the other provider.")
                    .foregroundStyle(.secondary)
            }

            ForEach(RewriteProvider.allCases) { provider in
                APIKeySection(
                    provider: provider,
                    isSelected: provider == model.selectedProvider,
                    model: model.keyModel(for: provider),
                    onDelete: { providerPendingDeletion = provider }
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 500)
        .task {
            await model.refresh()
        }
        .onDisappear {
            model.clearDrafts()
        }
        .confirmationDialog(
            "Delete the \(providerPendingDeletion?.displayName ?? "") API key from Keychain?",
            isPresented: Binding(
                get: { providerPendingDeletion != nil },
                set: { if !$0 { providerPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: providerPendingDeletion
        ) { provider in
            Button("Delete API Key", role: .destructive) {
                let keyModel = model.keyModel(for: provider)
                Task {
                    await keyModel.delete()
                }
            }
        }
    }
}

private struct APIKeySection: View {
    let provider: RewriteProvider
    let isSelected: Bool
    @ObservedObject var model: APIKeySettingsModel
    let onDelete: () -> Void

    var body: some View {
        Section(
            isSelected
                ? "\(provider.displayName) API Key (in use)"
                : "\(provider.displayName) API Key"
        ) {
            Text(
                model.isConfigured
                    ? "Configured. The key is stored in macOS Keychain. Enter a new key to update it."
                    : "Not configured. Enter an API key. ReCraft stores it only in macOS Keychain."
            )
            .foregroundStyle(.secondary)

            SecureField("\(provider.displayName) API key", text: $model.draftKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(model.isConfigured ? "Update" : "Save") {
                    Task {
                        await model.save()
                    }
                }
                .disabled(model.isWorking || model.draftKey.isEmpty)

                if model.isConfigured {
                    Button("Delete API Key", role: .destructive) {
                        onDelete()
                    }
                    .disabled(model.isWorking)
                }
            }

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
