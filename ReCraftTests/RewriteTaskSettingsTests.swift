import Carbon.HIToolbox
import XCTest
@testable import ReCraft

final class RewriteTaskSettingsModelTests: XCTestCase {
    @MainActor
    func testInitialCatalogLoadsAndAddRemainsDraftOnly() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.tasks, RewriteTaskCatalog.initial.tasks)
        XCTAssertEqual(model.selectedTaskID, RewriteTaskCatalog.initial.tasks.first?.id)
        XCTAssertEqual(try storedCatalog(in: store), .initial)

        model.addTask()

        XCTAssertEqual(model.tasks.count, 4)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(runtime.activationAttempts.count, 0)
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        let addedTask = try XCTUnwrap(model.selectedTask)
        XCTAssertEqual(addedTask.name, "New Task")
        XCTAssertEqual(model.fieldErrors[addedTask.id]?.prompt, "Prompt is required.")
        XCTAssertEqual(
            model.fieldErrors[addedTask.id]?.shortcut,
            "Record a shortcut using an A–Z key."
        )
    }

    @MainActor
    func testSwitchingSelectionPreservesCatalogWideUnsavedEdits() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)
        let firstID = RewriteTaskCatalog.initial.tasks[0].id
        let secondID = RewriteTaskCatalog.initial.tasks[1].id

        model.selectTask(firstID)
        model.updateSelectedTaskName("Edited first")
        model.selectTask(secondID)
        model.updateSelectedTaskPrompt("Edited second prompt")
        model.selectTask(firstID)

        XCTAssertEqual(model.selectedTask?.name, "Edited first")
        XCTAssertEqual(
            model.tasks.first(where: { $0.id == secondID })?.prompt,
            "Edited second prompt"
        )
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        XCTAssertEqual(runtime.activationAttempts.count, 0)
    }

    @MainActor
    func testSaveActivatesAndPersistsTheWholeCatalog() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)
        let firstID = RewriteTaskCatalog.initial.tasks[0].id
        let secondID = RewriteTaskCatalog.initial.tasks[1].id

        model.selectTask(firstID)
        model.updateSelectedTaskName("Edited first")
        model.selectTask(secondID)
        model.updateSelectedTaskPrompt("Edited second prompt")
        let candidate = try XCTUnwrap(model.draftCatalog)
        model.beginShortcutRecording(for: secondID)
        XCTAssertTrue(runtime.isShortcutRecorderActive)

        model.save()

        XCTAssertEqual(runtime.activationAttempts, [candidate])
        XCTAssertEqual(runtime.activeTasks, candidate.tasks)
        XCTAssertEqual(try storedCatalog(in: store), candidate)
        XCTAssertEqual(model.persistedCatalog, candidate)
        XCTAssertEqual(model.draftCatalog, candidate)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(runtime.isShortcutRecorderActive)
        XCTAssertEqual(model.statusMessage, "Rewrite tasks saved.")
        XCTAssertEqual(model.statusTone, .success)
    }

    @MainActor
    func testInlineValidationRejectsBlankFieldsReservedAndDuplicateShortcuts() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)
        let firstTask = RewriteTaskCatalog.initial.tasks[0]
        let secondTask = RewriteTaskCatalog.initial.tasks[1]

        model.selectTask(firstTask.id)
        model.updateSelectedTaskName(" \n ")
        model.updateSelectedTaskPrompt("\t")
        model.beginShortcutRecording(for: firstTask.id)
        runtime.captureRegistered(secondTask.shortcut)

        XCTAssertEqual(model.fieldErrors[firstTask.id]?.name, "Name is required.")
        XCTAssertEqual(model.fieldErrors[firstTask.id]?.prompt, "Prompt is required.")
        XCTAssertEqual(
            model.fieldErrors[firstTask.id]?.shortcut,
            "This shortcut is assigned to another task."
        )
        XCTAssertEqual(
            model.fieldErrors[secondTask.id]?.shortcut,
            "This shortcut is assigned to another task."
        )

        runtime.captureRegistered(.deterministicReplacement)
        XCTAssertEqual(
            model.fieldErrors[firstTask.id]?.shortcut,
            "⌃⌥⌘R is reserved for the test replacement."
        )

        model.save()
        XCTAssertEqual(runtime.activationAttempts.count, 0)
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        XCTAssertEqual(
            model.statusMessage,
            "Correct the highlighted task settings before saving."
        )
    }

    @MainActor
    func testFailedActivationPreservesDraftAndPreviousStoredCatalog() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)
        let firstID = RewriteTaskCatalog.initial.tasks[0].id

        model.selectTask(firstID)
        model.updateSelectedTaskPrompt("Unsaved corrected prompt")
        let failedDraft = try XCTUnwrap(model.draftCatalog)
        runtime.nextActivationError = .candidateUnavailable(taskID: firstID)

        model.save()

        XCTAssertEqual(model.draftCatalog, failedDraft)
        XCTAssertEqual(model.persistedCatalog, .initial)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        XCTAssertEqual(
            model.fieldErrors[firstID]?.shortcut,
            "This shortcut could not be registered. Choose another shortcut."
        )
    }

    @MainActor
    func testRestoreFailureEntersBlockingStateAndPreventsAnotherSave() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime(
            activeTasks: RewriteTaskCatalog.initial.tasks
        )
        let model = makeModel(store: store, runtime: runtime)

        model.updateSelectedTaskPrompt("Draft that cannot be restored")
        runtime.nextActivationError = .restoreFailed
        model.save()

        XCTAssertEqual(model.state, .blocked)
        XCTAssertTrue(model.isBlockingFailure)
        XCTAssertFalse(model.canSave)
        XCTAssertTrue(model.activeDisplayTasks.isEmpty)
        XCTAssertEqual(model.persistedCatalog, .initial)
        XCTAssertEqual(try storedCatalog(in: store), .initial)

        let attemptsAfterFailure = runtime.activationAttempts.count
        model.updateSelectedTaskName("Ignored while blocked")
        model.addTask()
        model.save()
        XCTAssertEqual(runtime.activationAttempts.count, attemptsAfterFailure)
        XCTAssertEqual(model.tasks.count, 3)
    }

    @MainActor
    func testPersistenceFailureKeepsDraftAndPreviousRuntime() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime(activeTasks: RewriteTaskCatalog.initial.tasks)
        let model = makeModel(store: store, runtime: runtime)

        model.updateSelectedTaskName("Unsaved after write failure")
        let failedDraft = try XCTUnwrap(model.draftCatalog)
        store.shouldFailWrites = true

        model.save()

        XCTAssertEqual(model.draftCatalog, failedDraft)
        XCTAssertEqual(model.persistedCatalog, .initial)
        XCTAssertEqual(runtime.activeTasks, RewriteTaskCatalog.initial.tasks)
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        XCTAssertEqual(
            model.statusMessage,
            "Rewrite tasks could not be saved. The previous configuration remains active."
        )
    }

    @MainActor
    func testCancelAndWindowCloseDiscardOnlyDraft() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)
        let firstID = RewriteTaskCatalog.initial.tasks[0].id

        model.updateSelectedTaskPrompt("First unsaved prompt")
        model.cancel()
        XCTAssertEqual(model.draftCatalog, .initial)
        XCTAssertFalse(model.isDirty)

        model.updateSelectedTaskPrompt("Second unsaved prompt")
        model.beginShortcutRecording(for: firstID)
        XCTAssertTrue(runtime.isShortcutRecorderActive)

        model.settingsWindowDidClose()

        XCTAssertEqual(model.draftCatalog, .initial)
        XCTAssertEqual(model.persistedCatalog, .initial)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(runtime.isShortcutRecorderActive)
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        XCTAssertEqual(runtime.activationAttempts.count, 0)
    }

    @MainActor
    func testConfirmedDeletionCanPersistAnEmptyCatalog() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)

        for taskID in model.tasks.map(\.id) {
            model.deleteTaskAfterConfirmation(taskID)
        }

        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(model.selectedTaskID)
        XCTAssertEqual(model.persistedCatalog, .initial)
        XCTAssertEqual(runtime.activationAttempts.count, 0)

        model.save()

        let saved = try XCTUnwrap(model.persistedCatalog)
        XCTAssertTrue(saved.tasks.isEmpty)
        XCTAssertEqual(try storedCatalog(in: store), saved)
        XCTAssertTrue(runtime.activeTasks.isEmpty)
    }

    @MainActor
    func testCorruptCatalogRemainsReadOnlyUntilConfirmedReset() throws {
        let corruptData = Data("not a catalog".utf8)
        let store = MemoryRewriteTaskCatalogStore(value: .data(corruptData))
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)

        XCTAssertEqual(model.state, .recovery)
        XCTAssertTrue(model.isReadOnlyRecovery)
        XCTAssertNil(model.draftCatalog)
        model.addTask()
        model.save()
        XCTAssertEqual(store.value, .data(corruptData))
        XCTAssertEqual(runtime.activationAttempts.count, 0)

        model.resetAfterUserConfirmation()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.persistedCatalog, .initial)
        XCTAssertEqual(model.draftCatalog, .initial)
        XCTAssertEqual(runtime.activeTasks, RewriteTaskCatalog.initial.tasks)
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        XCTAssertEqual(model.statusTone, .success)
    }

    @MainActor
    func testConfirmedRecoveryResetPersistsAndMarksUnavailableDefaults() throws {
        let corruptData = Data("not a catalog".utf8)
        let store = MemoryRewriteTaskCatalogStore(value: .data(corruptData))
        let runtime = FakeRewriteTaskSettingsRuntime()
        let unavailableID = RewriteTaskCatalog.initial.tasks[1].id
        runtime.recoveryUnavailableTaskIDs = [unavailableID]
        let model = makeModel(store: store, runtime: runtime)

        model.resetAfterUserConfirmation()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(try storedCatalog(in: store), .initial)
        XCTAssertEqual(
            runtime.activeTasks.map(\.id),
            RewriteTaskCatalog.initial.tasks
                .filter { $0.id != unavailableID }
                .map(\.id)
        )
        XCTAssertTrue(model.hasUnavailableTaskBindings)
        XCTAssertEqual(
            model.fieldErrors[unavailableID]?.shortcut,
            "This shortcut is unavailable. Record another shortcut or try saving again."
        )
        XCTAssertEqual(model.statusTone, .warning)
    }

    @MainActor
    func testRecorderAcceptsRegisteredAndNewChordsOnlyDuringFocusedSession() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)
        let firstTask = RewriteTaskCatalog.initial.tasks[0]
        let unregisteredBinding = HotKeyBinding(
            virtualKey: RewriteTaskCatalog.initial.tasks[2].shortcut.virtualKey,
            modifiers: HotKeyBinding.controlModifier | HotKeyBinding.shiftModifier
        )

        XCTAssertFalse(
            model.captureUnregisteredShortcutFromFocusedRecorder(unregisteredBinding)
        )
        XCTAssertEqual(model.selectedTask?.shortcut, firstTask.shortcut)

        model.beginShortcutRecording(for: firstTask.id)
        runtime.captureRegistered(.formalEnglish)
        XCTAssertEqual(model.selectedTask?.shortcut, .formalEnglish)

        XCTAssertTrue(
            model.captureUnregisteredShortcutFromFocusedRecorder(unregisteredBinding)
        )
        XCTAssertEqual(model.selectedTask?.shortcut, unregisteredBinding)

        model.rejectRecorderInput("Use at least two modifier keys.", for: firstTask.id)
        XCTAssertEqual(
            model.fieldErrors[firstTask.id]?.shortcut,
            "Use at least two modifier keys."
        )

        model.endShortcutRecording()
        XCTAssertFalse(runtime.isShortcutRecorderActive)
    }

    @MainActor
    func testStartupUnavailableStateIsIndependentFromDraftValidation() {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime()
        let model = makeModel(store: store, runtime: runtime)
        let firstID = RewriteTaskCatalog.initial.tasks[0].id

        model.setUnavailableTaskIDs([firstID])
        XCTAssertTrue(model.hasUnavailableTaskBindings)
        XCTAssertTrue(model.canSave)

        model.selectTask(RewriteTaskCatalog.initial.tasks[1].id)
        model.updateSelectedTaskPrompt("")

        XCTAssertTrue(model.hasUnavailableTaskBindings)
        XCTAssertEqual(model.fieldErrors[RewriteTaskCatalog.initial.tasks[1].id]?.prompt, "Prompt is required.")
    }

    @MainActor
    func testTwoUnavailableStartupBindingsCanBeCorrectedInOneSave() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let runtime = FakeRewriteTaskSettingsRuntime(
            activeTasks: [RewriteTaskCatalog.initial.tasks[2]]
        )
        let model = makeModel(store: store, runtime: runtime)
        let first = RewriteTaskCatalog.initial.tasks[0]
        let second = RewriteTaskCatalog.initial.tasks[1]
        model.setUnavailableTaskIDs([first.id, second.id])

        let firstReplacement = HotKeyBinding(
            virtualKey: UInt32(kVK_ANSI_Q),
            modifiers: HotKeyBinding.controlModifier | HotKeyBinding.commandModifier
        )
        let secondReplacement = HotKeyBinding(
            virtualKey: UInt32(kVK_ANSI_W),
            modifiers: HotKeyBinding.optionModifier | HotKeyBinding.commandModifier
        )
        model.selectTask(first.id)
        model.beginShortcutRecording(for: first.id)
        runtime.captureRegistered(firstReplacement)
        model.selectTask(second.id)
        model.beginShortcutRecording(for: second.id)
        runtime.captureRegistered(secondReplacement)

        XCTAssertNil(model.fieldErrors[first.id]?.shortcut)
        XCTAssertNil(model.fieldErrors[second.id]?.shortcut)
        model.save()

        XCTAssertFalse(model.hasUnavailableTaskBindings)
        XCTAssertEqual(model.persistedCatalog?.tasks[0].shortcut, firstReplacement)
        XCTAssertEqual(model.persistedCatalog?.tasks[1].shortcut, secondReplacement)
        XCTAssertEqual(try storedCatalog(in: store), model.persistedCatalog)
    }

    @MainActor
    private func makeModel(
        store: MemoryRewriteTaskCatalogStore,
        runtime: FakeRewriteTaskSettingsRuntime
    ) -> RewriteTaskSettingsModel {
        RewriteTaskSettingsModel(
            persistence: RewriteTaskCatalogPersistence(store: store),
            activator: runtime,
            shortcutRecorder: runtime
        )
    }

    @MainActor
    private func storedCatalog(
        in store: MemoryRewriteTaskCatalogStore
    ) throws -> RewriteTaskCatalog {
        guard case let .data(data) = store.value else {
            XCTFail("Expected catalog data")
            throw TestError.missingCatalog
        }
        return try JSONDecoder().decode(RewriteTaskCatalog.self, from: data)
    }

    private enum TestError: Error {
        case missingCatalog
    }
}

@MainActor
private final class MemoryRewriteTaskCatalogStore: RewriteTaskCatalogDataStoring {
    var value: RewriteTaskCatalogStoredValue
    var shouldFailWrites = false

    init(value: RewriteTaskCatalogStoredValue = .missing) {
        self.value = value
    }

    func storedValue() throws -> RewriteTaskCatalogStoredValue {
        value
    }

    func replaceData(_ data: Data) throws {
        guard !shouldFailWrites else {
            throw MemoryStoreError.writeFailed
        }
        value = .data(data)
    }

    func removeValue() throws {
        value = .missing
    }

    private enum MemoryStoreError: Error {
        case writeFailed
    }
}

@MainActor
private final class FakeRewriteTaskSettingsRuntime:
    RewriteTaskCatalogActivating,
    RewriteTaskShortcutRecording
{
    var activeTasks: [RewriteTask]
    var nextActivationError: RewriteTaskHotKeyActivationError?
    var recoveryUnavailableTaskIDs: Set<UUID> = []
    private(set) var activationAttempts: [RewriteTaskCatalog] = []
    private(set) var recoveryActivationAttempts: [RewriteTaskCatalog] = []
    private var recorderCapture: ShortcutRecorderCapture?

    init(activeTasks: [RewriteTask] = []) {
        self.activeTasks = activeTasks
    }

    var isShortcutRecorderActive: Bool {
        recorderCapture != nil
    }

    func activateAllOrNothing(
        _ candidate: RewriteTaskCatalog,
        persist: () throws -> Void
    ) throws -> RewriteTaskActivationReceipt {
        activationAttempts.append(candidate)
        if let nextActivationError {
            self.nextActivationError = nil
            throw nextActivationError
        }

        let previousTasks = activeTasks
        do {
            try persist()
        } catch {
            activeTasks = previousTasks
            throw RewriteTaskHotKeyActivationError.persistenceFailed
        }
        activeTasks = candidate.tasks
        return RewriteTaskActivationReceipt(
            previousWorkingTaskIDs: previousTasks.map(\.id),
            activeTaskIDs: candidate.tasks.map(\.id)
        )
    }

    func activateAfterRecoveryReset(
        _ catalog: RewriteTaskCatalog
    ) -> RewriteTaskLaunchRegistrationResult {
        recoveryActivationAttempts.append(catalog)
        activeTasks = catalog.tasks.filter {
            !recoveryUnavailableTaskIDs.contains($0.id)
        }
        return RewriteTaskLaunchRegistrationResult(
            activeTaskIDs: activeTasks.map(\.id),
            unavailableByTaskID: Dictionary(
                uniqueKeysWithValues: recoveryUnavailableTaskIDs.map {
                    ($0, RewriteTaskLaunchRegistrationFailure.unavailable)
                }
            )
        )
    }

    func beginShortcutRecording(
        capture: @escaping ShortcutRecorderCapture
    ) {
        recorderCapture = capture
    }

    func endShortcutRecording() {
        recorderCapture = nil
    }

    func captureUnregisteredBindingIfRecording(
        _ binding: HotKeyBinding
    ) -> Bool {
        guard let recorderCapture else { return false }
        recorderCapture(binding)
        return true
    }

    func captureRegistered(_ binding: HotKeyBinding) {
        recorderCapture?(binding)
    }
}
