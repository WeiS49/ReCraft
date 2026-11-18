import AppKit
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
                    RewriteTaskSettingsView(model: appDelegate.taskSettings)
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
    let apiKeySettings: APIKeySettingsModel
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
        let apiKeyStore = OpenAIAPIKeyStore()
        let hotKeyRegistry = RewriteTaskHotKeyRegistry()
        let persistence = RewriteTaskCatalogPersistence(
            store: UserDefaultsRewriteTaskCatalogStore()
        )
        let taskSettings = RewriteTaskSettingsModel(
            persistence: persistence,
            activator: hotKeyRegistry,
            shortcutRecorder: hotKeyRegistry,
            loadImmediately: !isRunningUnitTests
        )

        self.isRunningUnitTests = isRunningUnitTests
        self.apiKeySettings = APIKeySettingsModel(store: apiKeyStore)
        self.taskSettings = taskSettings
        coordinator = AppCoordinator(
            apiKeyStore: apiKeyStore,
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
    @ObservedObject var apiKeySettings: APIKeySettingsModel
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

        Text(
            apiKeySettings.isConfigured
                ? "OpenAI API Key: Configured"
                : "OpenAI API Key: Not configured"
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

private struct APIKeySettingsView: View {
    @ObservedObject var model: APIKeySettingsModel
    @State private var isConfirmingDeletion = false

    var body: some View {
        Form {
            Section("OpenAI API Key") {
                Text(
                    model.isConfigured
                        ? "An API key is stored in macOS Keychain. Enter a new key to update it."
                        : "Enter an API key. ReCraft stores it only in macOS Keychain."
                )
                .foregroundStyle(.secondary)

                SecureField("API key", text: $model.draftKey)
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
                            isConfirmingDeletion = true
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
        .formStyle(.grouped)
        .frame(width: 460, height: 240)
        .task {
            await model.refresh()
        }
        .onDisappear {
            model.clearDraft()
        }
        .confirmationDialog(
            "Delete the OpenAI API key from Keychain?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete API Key", role: .destructive) {
                Task {
                    await model.delete()
                }
            }
        }
    }
}
