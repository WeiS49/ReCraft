import Combine
import Foundation

@MainActor
protocol RewriteTaskShortcutRecording: AnyObject {
    var isShortcutRecorderActive: Bool { get }

    func beginShortcutRecording(
        capture: @escaping ShortcutRecorderCapture
    )
    func endShortcutRecording()

    @discardableResult
    func captureUnregisteredBindingIfRecording(
        _ binding: HotKeyBinding
    ) -> Bool
}

extension RewriteTaskHotKeyRegistry: RewriteTaskShortcutRecording {}

struct RewriteTaskSettingsFieldErrors: Equatable {
    var name: String?
    var prompt: String?
    var shortcut: String?
}

@MainActor
final class RewriteTaskSettingsModel: ObservableObject {
    enum StatusTone: Equatable {
        case neutral
        case success
        case warning
        case failure
    }

    enum State: Equatable {
        case ready
        case recovery
        case blocked
    }

    @Published private(set) var state: State = .ready
    @Published private(set) var persistedCatalog: RewriteTaskCatalog?
    @Published private(set) var draftCatalog: RewriteTaskCatalog?
    @Published var selectedTaskID: UUID?
    @Published private(set) var fieldErrors: [UUID: RewriteTaskSettingsFieldErrors] = [:]
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var recordingTaskID: UUID?

    var onRuntimeStateChange: (@MainActor () -> Void)?

    private let persistence: RewriteTaskCatalogPersistence
    private let activator: any RewriteTaskCatalogActivating
    private let shortcutRecorder: any RewriteTaskShortcutRecording
    private var unavailableTaskIDs: Set<UUID> = []
    private var shortcutCaptureErrors: [UUID: String] = [:]
    private var activationErrors: [UUID: String] = [:]

    init(
        persistence: RewriteTaskCatalogPersistence,
        activator: any RewriteTaskCatalogActivating,
        shortcutRecorder: any RewriteTaskShortcutRecording,
        loadImmediately: Bool = true
    ) {
        self.persistence = persistence
        self.activator = activator
        self.shortcutRecorder = shortcutRecorder

        if loadImmediately {
            load()
        }
    }

    var tasks: [RewriteTask] {
        draftCatalog?.tasks ?? []
    }

    var selectedTask: RewriteTask? {
        guard let selectedTaskID else { return nil }
        return draftCatalog?.tasks.first { $0.id == selectedTaskID }
    }

    var isReadOnlyRecovery: Bool {
        state == .recovery
    }

    var isBlockingFailure: Bool {
        state == .blocked
    }

    var isDirty: Bool {
        guard let persistedCatalog, let draftCatalog else { return false }
        return persistedCatalog != draftCatalog
    }

    var canSave: Bool {
        guard state == .ready, draftCatalog != nil, !isSaving else {
            return false
        }
        return isDirty || !unavailableTaskIDs.isEmpty
    }

    var hasUnavailableTaskBindings: Bool {
        !unavailableTaskIDs.isEmpty
    }

    var statusTone: StatusTone {
        switch statusMessage {
        case nil:
            .neutral
        case "Rewrite tasks saved.", "Rewrite tasks reset.":
            .success
        case "Rewrite tasks reset. Some shortcuts are unavailable.":
            .warning
        default:
            .failure
        }
    }

    var activeDisplayTasks: [RewriteTask] {
        state == .ready ? activator.activeTasks : []
    }

    func load() {
        endShortcutRecording()
        shortcutCaptureErrors = [:]
        activationErrors = [:]
        unavailableTaskIDs = []
        statusMessage = nil

        switch persistence.load() {
        case let .ready(catalog, _):
            state = .ready
            persistedCatalog = catalog
            draftCatalog = catalog
            selectedTaskID = catalog.tasks.first?.id
            refreshFieldErrors()

        case .recovery:
            state = .recovery
            persistedCatalog = nil
            draftCatalog = nil
            selectedTaskID = nil
            fieldErrors = [:]
            statusMessage = "Rewrite task settings could not be read. The stored value was left unchanged."
        }
        onRuntimeStateChange?()
    }

    func setUnavailableTaskIDs(_ taskIDs: Set<UUID>) {
        unavailableTaskIDs = taskIDs
        refreshFieldErrors()
        onRuntimeStateChange?()
    }

    func selectTask(_ taskID: UUID?) {
        guard let taskID else {
            endShortcutRecording()
            selectedTaskID = nil
            return
        }
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        if recordingTaskID != taskID {
            endShortcutRecording()
        }
        selectedTaskID = taskID
    }

    func addTask() {
        guard state == .ready, var catalog = draftCatalog else { return }
        endShortcutRecording()

        let task = RewriteTask(
            id: UUID(),
            name: "New Task",
            prompt: "",
            shortcut: HotKeyBinding(virtualKey: UInt32.max, modifiers: 0)
        )
        catalog.tasks.append(task)
        draftCatalog = catalog
        selectedTaskID = task.id
        statusMessage = nil
        refreshFieldErrors()
    }

    func updateSelectedTaskName(_ name: String) {
        updateSelectedTask { $0.name = name }
    }

    func updateSelectedTaskPrompt(_ prompt: String) {
        updateSelectedTask { $0.prompt = prompt }
    }

    func deleteTaskAfterConfirmation(_ taskID: UUID) {
        guard state == .ready,
              var catalog = draftCatalog,
              let index = catalog.tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        catalog.tasks.remove(at: index)
        draftCatalog = catalog
        shortcutCaptureErrors[taskID] = nil
        activationErrors[taskID] = nil

        if recordingTaskID == taskID {
            endShortcutRecording()
        }

        if selectedTaskID == taskID {
            if catalog.tasks.isEmpty {
                selectedTaskID = nil
            } else {
                selectedTaskID = catalog.tasks[min(index, catalog.tasks.count - 1)].id
            }
        }

        statusMessage = nil
        refreshFieldErrors()
    }

    func save() {
        guard state == .ready,
              let candidate = draftCatalog,
              canSave else {
            return
        }

        endShortcutRecording()

        shortcutCaptureErrors = [:]
        activationErrors = [:]
        let issues = RewriteTaskCatalogValidator.issues(in: candidate)
        guard issues.isEmpty else {
            applyValidationIssues(issues)
            statusMessage = "Correct the highlighted task settings before saving."
            return
        }

        let preparedSave: RewriteTaskCatalogPersistence.PreparedSave
        do {
            preparedSave = try persistence.prepareSave(candidate)
        } catch let error as RewriteTaskCatalogPersistence.SaveError {
            handlePreparationError(error)
            return
        } catch {
            statusMessage = "Rewrite task settings could not be prepared for saving."
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            _ = try activator.activateAllOrNothing(candidate) {
                try persistence.commit(preparedSave)
            }
            persistedCatalog = candidate
            draftCatalog = candidate
            unavailableTaskIDs = []
            statusMessage = "Rewrite tasks saved."
            refreshFieldErrors()
            onRuntimeStateChange?()
        } catch let error as RewriteTaskHotKeyActivationError {
            handleActivationError(error)
        } catch {
            statusMessage = "Rewrite tasks could not be saved. The previous configuration remains active."
        }
    }

    func cancel() {
        guard state == .ready, let persistedCatalog else { return }
        endShortcutRecording()

        let previousSelection = selectedTaskID
        draftCatalog = persistedCatalog
        if let previousSelection,
           persistedCatalog.tasks.contains(where: { $0.id == previousSelection }) {
            selectedTaskID = previousSelection
        } else {
            selectedTaskID = persistedCatalog.tasks.first?.id
        }

        shortcutCaptureErrors = [:]
        activationErrors = [:]
        statusMessage = nil
        refreshFieldErrors()
    }

    func settingsWindowDidClose() {
        endShortcutRecording()
        cancel()
    }

    func resetAfterUserConfirmation() {
        guard state == .recovery else { return }

        let preparedReset: RewriteTaskCatalogPersistence.PreparedSave
        do {
            preparedReset = try persistence.prepareResetAfterUserConfirmation()
        } catch {
            statusMessage = "Rewrite task settings could not be reset. The stored value was left unchanged."
            return
        }

        let initialCatalog = preparedReset.catalog
        do {
            try persistence.commit(preparedReset)
            let registration = activator.activateAfterRecoveryReset(initialCatalog)
            state = .ready
            persistedCatalog = initialCatalog
            draftCatalog = initialCatalog
            selectedTaskID = initialCatalog.tasks.first?.id
            unavailableTaskIDs = Set(registration.unavailableByTaskID.keys)
            shortcutCaptureErrors = [:]
            activationErrors = [:]
            statusMessage = registration.unavailableByTaskID.isEmpty
                ? "Rewrite tasks reset."
                : "Rewrite tasks reset. Some shortcuts are unavailable."
            refreshFieldErrors()
            onRuntimeStateChange?()
        } catch {
            statusMessage = "Rewrite task settings could not be reset. The stored value was left unchanged."
        }
    }

    func beginShortcutRecording(for taskID: UUID) {
        guard state == .ready,
              tasks.contains(where: { $0.id == taskID }) else {
            return
        }

        recordingTaskID = taskID
        shortcutCaptureErrors[taskID] = nil
        refreshFieldErrors()
        shortcutRecorder.beginShortcutRecording { [weak self] binding in
            self?.acceptRecordedShortcut(binding, for: taskID)
        }
    }

    func endShortcutRecording() {
        guard recordingTaskID != nil || shortcutRecorder.isShortcutRecorderActive else {
            return
        }
        shortcutRecorder.endShortcutRecording()
        recordingTaskID = nil
    }

    @discardableResult
    func captureUnregisteredShortcutFromFocusedRecorder(
        _ binding: HotKeyBinding
    ) -> Bool {
        shortcutRecorder.captureUnregisteredBindingIfRecording(binding)
    }

    func rejectRecorderInput(_ message: String, for taskID: UUID) {
        guard recordingTaskID == taskID else { return }
        shortcutCaptureErrors[taskID] = message
        refreshFieldErrors()
    }

    func isTaskModified(_ taskID: UUID) -> Bool {
        let persistedTask = persistedCatalog?.tasks.first { $0.id == taskID }
        let draftTask = draftCatalog?.tasks.first { $0.id == taskID }
        return persistedTask != draftTask
    }

    private func updateSelectedTask(
        _ update: (inout RewriteTask) -> Void
    ) {
        guard state == .ready,
              let selectedTaskID,
              var catalog = draftCatalog,
              let index = catalog.tasks.firstIndex(where: { $0.id == selectedTaskID }) else {
            return
        }

        update(&catalog.tasks[index])
        draftCatalog = catalog
        statusMessage = nil
        refreshFieldErrors()
    }

    private func acceptRecordedShortcut(
        _ binding: HotKeyBinding,
        for taskID: UUID
    ) {
        guard recordingTaskID == taskID,
              var catalog = draftCatalog,
              let index = catalog.tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }

        catalog.tasks[index].shortcut = binding
        draftCatalog = catalog
        shortcutCaptureErrors[taskID] = nil
        activationErrors[taskID] = nil
        statusMessage = nil
        refreshFieldErrors()
    }

    private func refreshFieldErrors() {
        guard let draftCatalog else {
            fieldErrors = [:]
            return
        }

        applyValidationIssues(RewriteTaskCatalogValidator.issues(in: draftCatalog))
    }

    private func applyValidationIssues(
        _ issues: [RewriteTaskCatalogValidationIssue]
    ) {
        var errors: [UUID: RewriteTaskSettingsFieldErrors] = [:]

        for issue in issues {
            switch issue {
            case let .blankName(taskID):
                errors[taskID, default: RewriteTaskSettingsFieldErrors()].name = "Name is required."

            case let .blankPrompt(taskID):
                errors[taskID, default: RewriteTaskSettingsFieldErrors()].prompt = "Prompt is required."

            case let .unsupportedKey(taskID):
                setShortcutError(
                    "Record a shortcut using an A–Z key.",
                    taskID: taskID,
                    errors: &errors
                )

            case let .unsupportedModifiers(taskID):
                setShortcutError(
                    "Use only Command, Control, Option, or Shift.",
                    taskID: taskID,
                    errors: &errors
                )

            case let .insufficientModifiers(taskID):
                setShortcutError(
                    "Use at least two modifier keys.",
                    taskID: taskID,
                    errors: &errors
                )

            case let .reservedShortcut(taskID):
                setShortcutError(
                    "⌃⌥⌘R is reserved for the test replacement.",
                    taskID: taskID,
                    errors: &errors
                )

            case let .duplicateShortcut(taskID, conflictingTaskID):
                let message = "This shortcut is assigned to another task."
                errors[taskID, default: RewriteTaskSettingsFieldErrors()].shortcut = message
                errors[conflictingTaskID, default: RewriteTaskSettingsFieldErrors()].shortcut = message

            case .unsupportedSchemaVersion, .duplicateTaskID:
                break
            }
        }

        for taskID in unavailableTaskIDs {
            let persistedShortcut = persistedCatalog?.tasks
                .first(where: { $0.id == taskID })?.shortcut
            let draftShortcut = draftCatalog?.tasks
                .first(where: { $0.id == taskID })?.shortcut
            if persistedShortcut == draftShortcut,
               errors[taskID]?.shortcut == nil {
                errors[taskID, default: RewriteTaskSettingsFieldErrors()].shortcut =
                    "This shortcut is unavailable. Record another shortcut or try saving again."
            }
        }
        for (taskID, message) in activationErrors {
            errors[taskID, default: RewriteTaskSettingsFieldErrors()].shortcut = message
        }
        for (taskID, message) in shortcutCaptureErrors {
            errors[taskID, default: RewriteTaskSettingsFieldErrors()].shortcut = message
        }

        fieldErrors = errors
    }

    private func setShortcutError(
        _ message: String,
        taskID: UUID,
        errors: inout [UUID: RewriteTaskSettingsFieldErrors]
    ) {
        guard errors[taskID]?.shortcut == nil else { return }
        errors[taskID, default: RewriteTaskSettingsFieldErrors()].shortcut = message
    }

    private func handleActivationError(
        _ error: RewriteTaskHotKeyActivationError
    ) {
        switch error {
        case let .invalidCatalog(issues):
            applyValidationIssues(issues)
            statusMessage = "Correct the highlighted task settings before saving."

        case let .candidateUnavailable(taskID):
            activationErrors[taskID] = "This shortcut could not be registered. Choose another shortcut."
            refreshFieldErrors()
            statusMessage = "Rewrite tasks were not saved. The previous configuration remains active."

        case .persistenceFailed:
            statusMessage = "Rewrite tasks could not be saved. The previous configuration remains active."

        case .taskActionUnavailable:
            statusMessage = "Rewrite tasks are not ready to activate. The previous configuration remains active."

        case .restoreFailed:
            endShortcutRecording()
            state = .blocked
            statusMessage = "Shortcut recovery failed. Quit ReCraft and keep the stored configuration unchanged."
            onRuntimeStateChange?()
        }
    }

    private func handlePreparationError(
        _ error: RewriteTaskCatalogPersistence.SaveError
    ) {
        switch error {
        case let .invalidCatalog(issues):
            applyValidationIssues(issues)
            statusMessage = "Correct the highlighted task settings before saving."

        case .encodingFailed:
            statusMessage = "Rewrite task settings could not be prepared for saving."

        case .storageFailed:
            statusMessage = "Rewrite task settings could not be saved. The previous configuration remains active."
        }
    }

}
