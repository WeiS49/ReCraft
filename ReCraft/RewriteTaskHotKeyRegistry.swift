import Foundation

typealias RewriteTaskHotKeyAction = @MainActor @Sendable (RewriteTask) async -> Void
typealias ShortcutRecorderCapture = @MainActor @Sendable (HotKeyBinding) -> Void

enum RewriteTaskLaunchRegistrationFailure: Error, Equatable {
    case unavailable
}

struct RewriteTaskLaunchRegistrationResult: Equatable {
    let activeTaskIDs: [UUID]
    let unavailableByTaskID: [UUID: RewriteTaskLaunchRegistrationFailure]
}

struct RewriteTaskActivationReceipt: Equatable {
    let previousWorkingTaskIDs: [UUID]
    let activeTaskIDs: [UUID]
}

enum RewriteTaskHotKeyActivationError: Error, Equatable {
    case invalidCatalog([RewriteTaskCatalogValidationIssue])
    case taskActionUnavailable
    case candidateUnavailable(taskID: UUID)
    case persistenceFailed
    case restoreFailed

    var isBlocking: Bool {
        switch self {
        case .restoreFailed:
            true
        case .invalidCatalog, .taskActionUnavailable,
             .candidateUnavailable, .persistenceFailed:
            false
        }
    }
}

@MainActor
protocol RewriteTaskCatalogActivating: AnyObject {
    var activeTasks: [RewriteTask] { get }

    func activateAllOrNothing(
        _ candidate: RewriteTaskCatalog,
        persist: () throws -> Void
    ) throws -> RewriteTaskActivationReceipt

    func activateAfterRecoveryReset(
        _ catalog: RewriteTaskCatalog
    ) -> RewriteTaskLaunchRegistrationResult
}

@MainActor
final class RewriteTaskHotKeyRegistry: RewriteTaskCatalogActivating {
    private struct ActiveTaskRegistration {
        let task: RewriteTask
        let registration: any GlobalHotKeyRegistration
    }

    private enum RegistrationBatchResult {
        case success([ActiveTaskRegistration])
        case failure(taskID: UUID, partial: [ActiveTaskRegistration])
    }

    private struct UnregistrationBatchOutcome {
        let cleanupPending: [ActiveTaskRegistration]

        var isComplete: Bool {
            cleanupPending.isEmpty
        }
    }

    private let registrar: any GlobalHotKeyRegistering
    private var deterministicRegistration: (any GlobalHotKeyRegistration)?
    private var taskRegistrations: [ActiveTaskRegistration] = []
    private var cleanupPendingTaskRegistrations: [ActiveTaskRegistration] = []
    private var taskAction: RewriteTaskHotKeyAction?
    private var recorderCapture: ShortcutRecorderCapture?
    private var nextRuntimeIdentifier: UInt32 = 1_000
    private(set) var isBlockingFailure = false

    init(registrar: any GlobalHotKeyRegistering = CarbonGlobalHotKeyRegistrar()) {
        self.registrar = registrar
    }

    var activeTasks: [RewriteTask] {
        isBlockingFailure ? [] : taskRegistrations.map(\.task)
    }

    var isShortcutRecorderActive: Bool {
        recorderCapture != nil
    }

    func setTaskAction(_ action: @escaping RewriteTaskHotKeyAction) {
        taskAction = action
    }

    func registerDeterministic(
        action: @escaping GlobalHotKeyAction
    ) throws {
        if let deterministicRegistration {
            try deterministicRegistration.unregister()
            self.deterministicRegistration = nil
        }

        let binding = HotKeyBinding.deterministicReplacement
        deterministicRegistration = try registrar.register(
            binding: binding,
            identifier: makeRuntimeIdentifier()
        ) { [weak self] in
            guard let self else { return }
            if self.captureIfRecording(binding) {
                return
            }
            await action()
        }
    }

    func registerTasksAtLaunch(
        _ catalog: RewriteTaskCatalog
    ) -> RewriteTaskLaunchRegistrationResult {
        precondition(taskRegistrations.isEmpty)

        var unavailableByTaskID: [UUID: RewriteTaskLaunchRegistrationFailure] = [:]
        for task in catalog.tasks {
            do {
                taskRegistrations.append(try makeRegistration(for: task))
            } catch {
                unavailableByTaskID[task.id] = .unavailable
            }
        }

        return RewriteTaskLaunchRegistrationResult(
            activeTaskIDs: taskRegistrations.map(\.task.id),
            unavailableByTaskID: unavailableByTaskID
        )
    }

    func activateAfterRecoveryReset(
        _ catalog: RewriteTaskCatalog
    ) -> RewriteTaskLaunchRegistrationResult {
        precondition(taskRegistrations.isEmpty)
        return registerTasksAtLaunch(catalog)
    }

    func activateAllOrNothing(
        _ candidate: RewriteTaskCatalog,
        persist: () throws -> Void
    ) throws -> RewriteTaskActivationReceipt {
        guard !isBlockingFailure else {
            throw RewriteTaskHotKeyActivationError.restoreFailed
        }
        let issues = RewriteTaskCatalogValidator.issues(in: candidate)
        guard issues.isEmpty else {
            throw RewriteTaskHotKeyActivationError.invalidCatalog(issues)
        }
        guard taskAction != nil else {
            throw RewriteTaskHotKeyActivationError.taskActionUnavailable
        }

        let previousRegistrations = taskRegistrations
        let previousTasks = previousRegistrations.map(\.task)
        do {
            try deactivatePreviousRegistrations(previousRegistrations)
        } catch let error as RewriteTaskHotKeyActivationError {
            if error.isBlocking {
                enterBlockingFailure()
            }
            throw error
        } catch {
            enterBlockingFailure()
            throw RewriteTaskHotKeyActivationError.restoreFailed
        }
        taskRegistrations = []

        let candidateRegistrations: [ActiveTaskRegistration]
        switch makeRegistrations(for: candidate.tasks) {
        case let .success(registrations):
            candidateRegistrations = registrations
        case let .failure(taskID, partial):
            let cleanup = unregisterBatch(partial)
            guard cleanup.isComplete else {
                retainForCleanup(cleanup.cleanupPending)
                enterBlockingFailure()
                throw RewriteTaskHotKeyActivationError.restoreFailed
            }
            guard restore(previousTasks) else {
                enterBlockingFailure()
                throw RewriteTaskHotKeyActivationError.restoreFailed
            }
            throw RewriteTaskHotKeyActivationError.candidateUnavailable(
                taskID: taskID
            )
        }

        do {
            try persist()
        } catch {
            let cleanup = unregisterBatch(candidateRegistrations)
            guard cleanup.isComplete else {
                retainForCleanup(cleanup.cleanupPending)
                enterBlockingFailure()
                throw RewriteTaskHotKeyActivationError.restoreFailed
            }
            guard restore(previousTasks) else {
                enterBlockingFailure()
                throw RewriteTaskHotKeyActivationError.restoreFailed
            }
            throw RewriteTaskHotKeyActivationError.persistenceFailed
        }

        taskRegistrations = candidateRegistrations
        return RewriteTaskActivationReceipt(
            previousWorkingTaskIDs: previousTasks.map(\.id),
            activeTaskIDs: candidate.tasks.map(\.id)
        )
    }

    func beginShortcutRecording(
        capture: @escaping ShortcutRecorderCapture
    ) {
        guard !isBlockingFailure else { return }
        recorderCapture = capture
    }

    func endShortcutRecording() {
        recorderCapture = nil
    }

    @discardableResult
    func captureUnregisteredBindingIfRecording(_ binding: HotKeyBinding) -> Bool {
        guard !isBlockingFailure else { return false }
        return captureIfRecording(binding)
    }

    func unregisterAll() throws {
        let cleanup = unregisterBatch(
            taskRegistrations + cleanupPendingTaskRegistrations
        )
        taskRegistrations = []
        cleanupPendingTaskRegistrations = cleanup.cleanupPending

        var deterministicCleanupFailed = false
        if let deterministicRegistration {
            do {
                try deterministicRegistration.unregister()
                self.deterministicRegistration = nil
            } catch {
                deterministicCleanupFailed = true
            }
        }

        if !cleanup.isComplete {
            enterBlockingFailure()
        }
        guard cleanup.isComplete, !deterministicCleanupFailed else {
            throw RewriteTaskHotKeyActivationError.restoreFailed
        }
    }

    private func makeRegistration(
        for task: RewriteTask
    ) throws -> ActiveTaskRegistration {
        let binding = task.shortcut
        let registration = try registrar.register(
            binding: binding,
            identifier: makeRuntimeIdentifier()
        ) { [weak self] in
            guard let self else { return }
            guard !self.isBlockingFailure else { return }
            if self.captureIfRecording(binding) {
                return
            }
            guard let action = self.taskAction else { return }
            await action(task)
        }
        return ActiveTaskRegistration(task: task, registration: registration)
    }

    private func makeRegistrations(
        for tasks: [RewriteTask]
    ) -> RegistrationBatchResult {
        var registrations: [ActiveTaskRegistration] = []
        for task in tasks {
            do {
                registrations.append(try makeRegistration(for: task))
            } catch {
                return .failure(taskID: task.id, partial: registrations)
            }
        }
        return .success(registrations)
    }

    private func deactivatePreviousRegistrations(
        _ previous: [ActiveTaskRegistration]
    ) throws {
        let cleanup = unregisterBatch(previous)
        guard cleanup.isComplete else {
            taskRegistrations = []
            retainForCleanup(cleanup.cleanupPending)
            throw RewriteTaskHotKeyActivationError.restoreFailed
        }
    }

    private func restore(_ tasks: [RewriteTask]) -> Bool {
        switch makeRegistrations(for: tasks) {
        case let .success(restored):
            taskRegistrations = restored
            return true
        case let .failure(_, partial):
            let cleanup = unregisterBatch(partial)
            taskRegistrations = []
            retainForCleanup(cleanup.cleanupPending)
            return false
        }
    }

    private func unregisterBatch(
        _ registrations: [ActiveTaskRegistration]
    ) -> UnregistrationBatchOutcome {
        var cleanupPending: [ActiveTaskRegistration] = []
        for activeRegistration in registrations.reversed() {
            do {
                try activeRegistration.registration.unregister()
            } catch {
                cleanupPending.append(activeRegistration)
            }
        }
        return UnregistrationBatchOutcome(cleanupPending: cleanupPending)
    }

    private func retainForCleanup(
        _ registrations: [ActiveTaskRegistration]
    ) {
        cleanupPendingTaskRegistrations.append(contentsOf: registrations)
    }

    private func captureIfRecording(_ binding: HotKeyBinding) -> Bool {
        guard let recorderCapture else { return false }
        recorderCapture(binding)
        return true
    }

    private func enterBlockingFailure() {
        isBlockingFailure = true
        recorderCapture = nil
    }

    private func makeRuntimeIdentifier() -> UInt32 {
        let identifier = nextRuntimeIdentifier
        nextRuntimeIdentifier = nextRuntimeIdentifier == UInt32.max
            ? 1_000
            : nextRuntimeIdentifier + 1
        return identifier
    }
}
