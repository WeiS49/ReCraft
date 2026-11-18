import Foundation
import OSLog

struct SingleOperationGate {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func finish() {
        isActive = false
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case processing
        case success
        case warning
        case failure
    }

    @Published private(set) var accessibilityGranted = false
    @Published private(set) var hotKeyRegistrationError: String?
    @Published private(set) var statusMessage = "Starting…"
    @Published private(set) var phase: Phase = .idle

    var shouldRefuseTermination: Bool {
        operationGate.isActive
    }

    var menuBarIconName: String {
        switch phase {
        case .idle:
            "text.cursor"
        case .processing:
            "ellipsis.circle"
        case .success:
            "checkmark.circle"
        case .warning:
            "exclamationmark.circle"
        case .failure:
            "exclamationmark.triangle"
        }
    }

    private let logger = Logger(
        subsystem: "com.local.ReCraftClipboardSpike",
        category: "App"
    )
    private let hotKeyRegistry: RewriteTaskHotKeyRegistry
    private let taskSettings: RewriteTaskSettingsModel
    private let feedback = FeedbackPresenter()
    private let textReplacementService: ClipboardTextReplacementService
    private var started = false
    private var operationGate = SingleOperationGate()

    init(
        apiKeyStore: any APIKeyStoring,
        hotKeyRegistry: RewriteTaskHotKeyRegistry,
        taskSettings: RewriteTaskSettingsModel
    ) {
        self.hotKeyRegistry = hotKeyRegistry
        self.taskSettings = taskSettings
        textReplacementService = ClipboardTextReplacementService(
            apiKeyStore: apiKeyStore
        )
    }

    func start() {
        guard !started else { return }
        started = true

        refreshAccessibilityStatus()

        hotKeyRegistry.setTaskAction { [weak self] task in
            await self?.handleTaskHotKey(task)
        }

        do {
            try hotKeyRegistry.registerDeterministic { [weak self] in
                await self?.handleHotKey()
            }
            hotKeyRegistrationError = nil
            logger.notice("Deterministic shortcut registered")
        } catch {
            hotKeyRegistrationError = "Test replacement shortcut unavailable"
            phase = .failure
            logger.error("Deterministic shortcut registration failed category=registration")
        }

        if let catalog = taskSettings.persistedCatalog,
           !taskSettings.isReadOnlyRecovery {
            let result = hotKeyRegistry.registerTasksAtLaunch(catalog)
            taskSettings.setUnavailableTaskIDs(Set(result.unavailableByTaskID.keys))
            if result.unavailableByTaskID.isEmpty {
                logger.notice("Task shortcuts registered")
            } else {
                logger.error("Some task shortcuts unavailable category=registration")
            }
        }

        updateIdleStatus()
    }

    func stop() {
        do {
            try hotKeyRegistry.unregisterAll()
        } catch {
            logger.error("Shortcut unregistration failed category=registration")
        }
    }

    func refreshAccessibilityStatus() {
        accessibilityGranted = AccessibilityPermission.isTrusted(prompt: false)
        guard !operationGate.isActive else { return }
        updateIdleStatus()
        phase = .idle
    }

    func refreshTaskConfigurationStatus() {
        guard !operationGate.isActive else { return }
        updateIdleStatus()
        phase = .idle
    }

    func requestAccessibilityAccess() {
        _ = AccessibilityPermission.isTrusted(prompt: true)
        refreshAccessibilityStatus()

        if accessibilityGranted {
            feedback.show("Accessibility access granted", kind: .success)
        } else {
            feedback.show(
                "Enable ReCraft Clipboard Spike in Privacy & Security → Accessibility",
                kind: .failure
            )
        }
    }

    func refuseQuitWhileProcessing() {
        guard operationGate.isActive else { return }
        statusMessage = "Replacement in progress"
        feedback.show("Wait for the current replacement to finish", kind: .warning)
    }

    private func handleHotKey() async {
        guard beginOperationIfAllowed() else { return }
        phase = .processing
        statusMessage = "Reading selection…"
        defer { operationGate.finish() }

        handleOutcome(await textReplacementService.replaceSelection())
    }

    private func handleTaskHotKey(_ task: RewriteTask) async {
        guard beginOperationIfAllowed() else { return }
        phase = .processing
        statusMessage = "Running \(task.name)…"
        feedback.show("Running \(task.name)…", kind: .processing)
        defer { operationGate.finish() }

        handleOutcome(await textReplacementService.rewriteSelection(using: task))
    }

    private func beginOperationIfAllowed() -> Bool {
        guard !operationGate.isActive else {
            feedback.show("ReCraft is already processing", kind: .warning)
            return false
        }

        refreshAccessibilityStatus()
        guard accessibilityGranted else {
            _ = AccessibilityPermission.isTrusted(prompt: true)
            phase = .failure
            statusMessage = "Accessibility permission required"
            feedback.show("Accessibility permission required", kind: .failure)
            logger.notice("Shortcut refused: accessibility permission missing")
            return false
        }

        return operationGate.begin()
    }

    private func updateIdleStatus() {
        if !accessibilityGranted {
            statusMessage = "Accessibility permission required"
        } else if taskSettings.isBlockingFailure {
            statusMessage = "Rewrite task shortcuts blocked; quit and relaunch"
        } else if taskSettings.isReadOnlyRecovery {
            statusMessage = "Rewrite task configuration needs recovery"
        } else if taskSettings.hasUnavailableTaskBindings {
            statusMessage = "Some task shortcuts are unavailable"
        } else if hotKeyRegistrationError != nil {
            statusMessage = "Test replacement shortcut unavailable"
        } else {
            statusMessage = "Ready"
        }
    }

    private func handleOutcome(_ outcome: ClipboardTextReplacementService.Outcome) {
        switch outcome {
        case let .replacementSent(context, clipboardRestoration):
            handleReplacementSent(
                context: context,
                clipboardRestoration: clipboardRestoration
            )
        case let .resultCopied(context, reason):
            phase = .warning
            statusMessage = reason.message
            feedback.show(reason.message, kind: .warning)
            logger.notice(
                "Result retained for manual paste reason=\(reason.rawValue, privacy: .public) app=\(context.bundleIdentifier, privacy: .public) role=\(context.role, privacy: .public)"
            )
        case let .refused(reason, context):
            phase = .failure
            statusMessage = reason.message
            feedback.show(reason.message, kind: .failure)
            logger.notice(
                "Replacement refused stage=\(reason.logStage, privacy: .public) category=\(reason.logCategory, privacy: .public) app=\(context?.bundleIdentifier ?? "unknown", privacy: .public) role=\(context?.role ?? "unknown", privacy: .public)"
            )
        }
    }

    private func handleReplacementSent(
        context: ClipboardTextReplacementService.Context,
        clipboardRestoration: ClipboardTextReplacementService.ClipboardRestoration
    ) {
        switch clipboardRestoration {
        case .restored:
            phase = .success
            statusMessage = "Replacement sent"
            feedback.show("Replacement sent", kind: .success)
        case .newerContentPreserved:
            phase = .success
            statusMessage = "Replacement sent; newer clipboard preserved"
            feedback.show("Replacement sent; newer clipboard preserved", kind: .success)
        case .failed:
            phase = .warning
            statusMessage = "Replacement sent; clipboard restore failed"
            feedback.show("Replacement sent; clipboard restore failed", kind: .warning)
        }

        logger.notice(
            "Replacement sent app=\(context.bundleIdentifier, privacy: .public) role=\(context.role, privacy: .public) clipboard=\(clipboardRestoration.rawValue, privacy: .public)"
        )
    }
}
