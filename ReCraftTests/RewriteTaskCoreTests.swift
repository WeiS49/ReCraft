import Carbon.HIToolbox
import Foundation
import XCTest
@testable import ReCraft

final class RewriteTaskCatalogTests: XCTestCase {
    func testInitialCatalogMatchesTaskOnlyDefaultsWithoutChangingIdentity() {
        let catalog = RewriteTaskCatalog.initial

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(
            catalog.tasks.map(\.name),
            ["Coding Agent Prompt", "Formal French", "Formal English"]
        )
        XCTAssertEqual(
            catalog.tasks.map { $0.id.uuidString },
            [
                "4CF98FA4-99C4-4CC8-9B9C-11D5D8B11770",
                "A8B0CA67-B6A0-4974-B16B-DC62DE533B86",
                "E61032F4-4CEE-40F3-91CD-10A6F22BCF85",
            ]
        )
        let expectedPrompts = [
            """
            将输入整理成可直接交给 Coding Agent 的清晰任务说明，默认使用原文的主要语言。
            保留用户目标、明确限制及其适用范围和授权边界。允许适度补充与目标直接相关的工程检查、边界情况和验证方式，但不新增无关目标、强制方案或授权。
            不要编造项目事实、文件路径、技术栈、诊断结果或已完成的工作。缺失的信息应转化为执行 Agent 需要查证或必要时确认的事项。
            原文要求先说明、等待决定或获批后再继续时，必须明确保留等待条件，不得简化为仅说明原因，也不得允许自行继续。不得缩小禁止事项的适用范围。
            按明确要求转换人称、角色称谓和责任映射，逐一保留各方的动作与审批条件；未要求改变的责任不擅自转移。仅改变人称不等于改变谁负责行动。
            按任务复杂度组织内容：简单任务保持简短，遵守指定的篇幅、格式和不扩写要求，不强行套完整模板或扩展为全面重构。
            只输出改写后的任务说明，不附加开场白或改写解释，不回答或执行原文要求的工作。
            """,
            """
            将输入翻译或改写成自然、正式、可直接使用的法语。忠实保留事实、意图、人物关系、否定和不确定性，不补充建议、答案或新要求。
            保留代码、标识符和需要精确引用的内容；日期、金额和标点可按法语习惯表达，但不得改变其值。只输出改写结果。
            """,
            """
            将输入翻译或改写成自然、正式、可直接使用的英语。忠实保留事实、意图、人物关系、否定和不确定性，不补充建议、答案或新要求。
            保留代码、标识符和需要精确引用的内容；日期、金额和标点可按英语习惯表达，但不得改变其值。只输出改写结果。
            """,
        ]
        XCTAssertEqual(
            catalog.tasks.map { Data($0.prompt.utf8) },
            expectedPrompts.map { Data($0.utf8) }
        )
        XCTAssertEqual(
            catalog.tasks.map(\.shortcut),
            [.codingAgentPrompt, .formalFrench, .formalEnglish]
        )
        XCTAssertTrue(RewriteTaskCatalogValidator.issues(in: catalog).isEmpty)
    }

    func testCodableRoundTripPreservesIDsAndStoredTextExactly() throws {
        var catalog = RewriteTaskCatalog.initial
        catalog.tasks[0].name = "  Coding Agent Prompt  "
        let prompt = "\t Keep these spaces.\r\ncafe\u{0301} {taskPrompt}\n  "
        catalog.tasks[0].prompt = prompt

        XCTAssertTrue(RewriteTaskCatalogValidator.issues(in: catalog).isEmpty)

        let decoded = try JSONDecoder().decode(
            RewriteTaskCatalog.self,
            from: JSONEncoder().encode(catalog)
        )

        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(decoded.tasks[0].id, catalog.tasks[0].id)
        XCTAssertEqual(decoded.tasks[0].name, "  Coding Agent Prompt  ")
        XCTAssertEqual(Data(decoded.tasks[0].prompt.utf8), Data(prompt.utf8))
    }

    func testValidationRejectsBlankInvalidReservedAndDuplicateValues() {
        let firstID = UUID()
        let secondID = UUID()
        let unsupportedModifiersID = UUID()
        let catalog = RewriteTaskCatalog(
            schemaVersion: RewriteTaskCatalog.currentSchemaVersion,
            tasks: [
                RewriteTask(
                    id: firstID,
                    name: " \n ",
                    prompt: "\t",
                    shortcut: .deterministicReplacement
                ),
                RewriteTask(
                    id: secondID,
                    name: "Valid",
                    prompt: "Valid",
                    shortcut: .deterministicReplacement
                ),
                RewriteTask(
                    id: UUID(),
                    name: "Invalid key",
                    prompt: "Valid",
                    shortcut: HotKeyBinding(
                        virtualKey: UInt32(kVK_ANSI_1),
                        modifiers: HotKeyBinding.commandModifier
                    )
                ),
                RewriteTask(
                    id: unsupportedModifiersID,
                    name: "Unsupported modifiers",
                    prompt: "Valid",
                    shortcut: HotKeyBinding(
                        virtualKey: UInt32(kVK_ANSI_A),
                        modifiers: HotKeyBinding.commandModifier
                            | HotKeyBinding.controlModifier
                            | UInt32(alphaLock)
                    )
                ),
            ]
        )

        let issues = RewriteTaskCatalogValidator.issues(in: catalog)
        XCTAssertTrue(issues.contains(.blankName(taskID: firstID)))
        XCTAssertTrue(issues.contains(.blankPrompt(taskID: firstID)))
        XCTAssertTrue(issues.contains(.reservedShortcut(taskID: firstID)))
        XCTAssertTrue(issues.contains(.reservedShortcut(taskID: secondID)))
        XCTAssertTrue(
            issues.contains(
                .duplicateShortcut(
                    taskID: secondID,
                    conflictingTaskID: firstID
                )
            )
        )
        XCTAssertTrue(issues.contains(where: {
            if case .unsupportedKey = $0 { true } else { false }
        }))
        XCTAssertTrue(issues.contains(where: {
            if case .insufficientModifiers = $0 { true } else { false }
        }))
        XCTAssertTrue(
            issues.contains(.unsupportedModifiers(taskID: unsupportedModifiersID))
        )
    }

    func testDuplicateNamesAreAllowedAndCatalogHasNoCountCap() {
        let keys = HotKeyBinding.supportedLetterKeys
            .filter { $0 != UInt32(kVK_ANSI_R) }
            .sorted()
        let tasks = keys.prefix(20).enumerated().map { index, key in
            RewriteTask(
                id: UUID(),
                name: "Repeated name",
                prompt: "Prompt \(index)",
                shortcut: HotKeyBinding(
                    virtualKey: key,
                    modifiers: HotKeyBinding.controlModifier
                        | HotKeyBinding.optionModifier
                )
            )
        }
        let catalog = RewriteTaskCatalog(
            schemaVersion: RewriteTaskCatalog.currentSchemaVersion,
            tasks: Array(tasks)
        )

        XCTAssertEqual(catalog.tasks.count, 20)
        XCTAssertTrue(RewriteTaskCatalogValidator.issues(in: catalog).isEmpty)
        XCTAssertTrue(
            RewriteTaskCatalogValidator.issues(
                in: RewriteTaskCatalog(
                    schemaVersion: RewriteTaskCatalog.currentSchemaVersion,
                    tasks: []
                )
            ).isEmpty
        )
    }

    @MainActor
    func testDisplayLabelUsesStandardModifierOrderAndProvidedKeyLabel() {
        let binding = HotKeyBinding(
            virtualKey: UInt32(kVK_ANSI_P),
            modifiers: HotKeyBinding.commandModifier
                | HotKeyBinding.shiftModifier
                | HotKeyBinding.optionModifier
                | HotKeyBinding.controlModifier
        )

        XCTAssertEqual(
            HotKeyDisplayLabel.make(for: binding, keyLabel: "p"),
            "⌃⌥⇧⌘P"
        )
    }
}

final class RewriteTaskCatalogPersistenceTests: XCTestCase {
    @MainActor
    func testMissingCatalogSeedsOnceAndThenLoadsIdempotently() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let persistence = RewriteTaskCatalogPersistence(store: store)

        XCTAssertEqual(
            persistence.load(),
            .ready(catalog: .initial, initialized: true)
        )
        XCTAssertEqual(store.replaceCount, 1)
        XCTAssertEqual(
            persistence.load(),
            .ready(catalog: .initial, initialized: false)
        )
        XCTAssertEqual(store.replaceCount, 1)
    }

    @MainActor
    func testExistingV1EditedAndEmptyCatalogsAreNeverReseeded() throws {
        XCTAssertEqual(
            UserDefaultsRewriteTaskCatalogStore.preferenceKey,
            "rewriteTaskCatalog.v1"
        )
        var legacy = RewriteTaskCatalog.initial
        for index in legacy.tasks.indices {
            legacy.tasks[index].prompt = "Legacy stored prompt \(index) that differs from the current default."
        }
        var edited = legacy
        edited.tasks[0].name = "  Renamed task  "
        edited.tasks[0].prompt = "\t Preserve cafe\u{0301} and {taskPrompt}.\r\n  "
        let empty = RewriteTaskCatalog(schemaVersion: 1, tasks: [])

        for catalog in [legacy, edited, empty] {
            let originalData = try JSONEncoder().encode(catalog)
            let store = MemoryRewriteTaskCatalogStore(value: .data(originalData))
            let persistence = RewriteTaskCatalogPersistence(store: store)

            guard case let .ready(loaded, initialized) = persistence.load() else {
                return XCTFail("Expected an existing valid catalog")
            }
            XCTAssertFalse(initialized)
            XCTAssertEqual(loaded, catalog)
            XCTAssertEqual(
                loaded.tasks.map { Data($0.prompt.utf8) },
                catalog.tasks.map { Data($0.prompt.utf8) }
            )
            XCTAssertEqual(store.value, .data(originalData))
            XCTAssertEqual(store.replaceCount, 0)
        }
    }

    @MainActor
    func testSettingsSavesAndReloadsACompletePromptWithoutNormalization() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let persistence = RewriteTaskCatalogPersistence(store: store)
        let registry = RewriteTaskHotKeyRegistry(registrar: FakeGlobalHotKeyRegistrar())
        registry.setTaskAction { _ in }
        let model = RewriteTaskSettingsModel(
            persistence: persistence,
            activator: registry,
            shortcutRecorder: registry
        )
        let taskID = try XCTUnwrap(model.selectedTaskID)
        let prompt = "\t Rewrite only as requested.\r\nPreserve cafe\u{0301} and {taskPrompt}.\n  "
        model.updateSelectedTaskPrompt(prompt)

        XCTAssertNil(model.fieldErrors[taskID]?.prompt)
        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.statusMessage, "Rewrite tasks saved.")
        let activeTask = try XCTUnwrap(registry.activeTasks.first { $0.id == taskID })
        XCTAssertEqual(Data(activeTask.prompt.utf8), Data(prompt.utf8))

        model.load()
        let reloadedTask = try XCTUnwrap(model.selectedTask)
        XCTAssertEqual(reloadedTask.id, taskID)
        XCTAssertEqual(Data(reloadedTask.prompt.utf8), Data(prompt.utf8))
    }

    @MainActor
    func testCorruptAndUnsupportedCatalogsRemainUnchangedInRecovery() throws {
        let corruptData = Data("not-json".utf8)
        let corruptStore = MemoryRewriteTaskCatalogStore(value: .data(corruptData))
        let corruptPersistence = RewriteTaskCatalogPersistence(store: corruptStore)

        XCTAssertEqual(
            corruptPersistence.load(),
            .recovery(reason: .corruptData)
        )
        XCTAssertEqual(corruptStore.value, .data(corruptData))
        XCTAssertEqual(corruptStore.replaceCount, 0)

        let unsupported = RewriteTaskCatalog(schemaVersion: 2, tasks: [])
        let unsupportedData = try JSONEncoder().encode(unsupported)
        let unsupportedStore = MemoryRewriteTaskCatalogStore(
            value: .data(unsupportedData)
        )
        let unsupportedPersistence = RewriteTaskCatalogPersistence(
            store: unsupportedStore
        )

        XCTAssertEqual(
            unsupportedPersistence.load(),
            .recovery(reason: .unsupportedSchemaVersion(2))
        )
        XCTAssertEqual(unsupportedStore.value, .data(unsupportedData))
        XCTAssertEqual(unsupportedStore.replaceCount, 0)
    }

    @MainActor
    func testInvalidStoredTypeAndInvalidCatalogEnterReadOnlyRecovery() throws {
        let invalidTypeStore = MemoryRewriteTaskCatalogStore(value: .invalidType)
        XCTAssertEqual(
            RewriteTaskCatalogPersistence(store: invalidTypeStore).load(),
            .recovery(reason: .invalidStoredType)
        )
        XCTAssertEqual(invalidTypeStore.value, .invalidType)

        var invalidCatalog = RewriteTaskCatalog.initial
        invalidCatalog.tasks[0].prompt = " \n "
        let invalidData = try JSONEncoder().encode(invalidCatalog)
        let invalidCatalogStore = MemoryRewriteTaskCatalogStore(
            value: .data(invalidData)
        )
        let loadState = RewriteTaskCatalogPersistence(
            store: invalidCatalogStore
        ).load()

        guard case let .recovery(reason) = loadState,
              case let .invalidCatalog(issues) = reason else {
            return XCTFail("Expected invalid catalog recovery")
        }
        XCTAssertTrue(
            issues.contains(.blankPrompt(taskID: invalidCatalog.tasks[0].id))
        )
        XCTAssertEqual(invalidCatalogStore.value, .data(invalidData))
        XCTAssertEqual(invalidCatalogStore.replaceCount, 0)
    }

    @MainActor
    func testPreparedSavePersistsThreeFourAndEmptyCatalogs() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let persistence = RewriteTaskCatalogPersistence(store: store)
        _ = persistence.load()

        var fourTasks = RewriteTaskCatalog.initial
        fourTasks.tasks.append(makeTask(name: "Fourth", key: kVK_ANSI_Q))
        let prepared = try persistence.prepareSave(fourTasks)
        XCTAssertEqual(prepared.catalog, fourTasks)
        try persistence.commit(prepared)
        XCTAssertEqual(
            persistence.load(),
            .ready(catalog: fourTasks, initialized: false)
        )

        let empty = RewriteTaskCatalog(
            schemaVersion: RewriteTaskCatalog.currentSchemaVersion,
            tasks: []
        )
        try persistence.save(empty)
        XCTAssertEqual(
            persistence.load(),
            .ready(catalog: empty, initialized: false)
        )
    }

    @MainActor
    func testFailedPreparedCommitLeavesPreviouslyStoredDataUnchanged() throws {
        let store = MemoryRewriteTaskCatalogStore()
        let persistence = RewriteTaskCatalogPersistence(store: store)
        _ = persistence.load()
        let previousValue = store.value

        var candidate = RewriteTaskCatalog.initial
        candidate.tasks[0].prompt = "Edited prompt"
        let prepared = try persistence.prepareSave(candidate)
        store.shouldFailWrites = true

        XCTAssertThrowsError(try persistence.commit(prepared)) { error in
            XCTAssertEqual(
                error as? RewriteTaskCatalogPersistence.SaveError,
                .storageFailed
            )
        }
        XCTAssertEqual(store.value, previousValue)
    }

    @MainActor
    func testResetIsAnExplicitPreparedReplacement() throws {
        let corruptData = Data("corrupt".utf8)
        let store = MemoryRewriteTaskCatalogStore(value: .data(corruptData))
        let persistence = RewriteTaskCatalogPersistence(store: store)

        XCTAssertEqual(persistence.load(), .recovery(reason: .corruptData))
        let preparedReset = try persistence.prepareResetAfterUserConfirmation()
        XCTAssertEqual(preparedReset.catalog, .initial)
        XCTAssertEqual(store.value, .data(corruptData))

        try persistence.commit(preparedReset)
        XCTAssertEqual(
            persistence.load(),
            .ready(catalog: .initial, initialized: false)
        )
    }

    @MainActor
    func testUserDefaultsStoreUsesOnlyItsIsolatedDataKey() {
        let suiteName = "ReCraftTests.RewriteTaskCatalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            "leave-this-invalid-value-untouched",
            forKey: UserDefaultsRewriteTaskCatalogStore.preferenceKey
        )
        let persistence = RewriteTaskCatalogPersistence(
            store: UserDefaultsRewriteTaskCatalogStore(defaults: defaults)
        )

        XCTAssertEqual(
            persistence.load(),
            .recovery(reason: .invalidStoredType)
        )
        XCTAssertEqual(
            defaults.string(
                forKey: UserDefaultsRewriteTaskCatalogStore.preferenceKey
            ),
            "leave-this-invalid-value-untouched"
        )
    }
}

final class RewriteTaskHotKeyRegistryTests: XCTestCase {
    @MainActor
    func testLaunchRegistersTasksIndependentlyAndKeepsDeterministicActive() throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        registrar.registrationShouldFail = { binding, _ in
            binding == .formalFrench
        }
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        try registry.registerDeterministic {}

        let result = registry.registerTasksAtLaunch(.initial)

        XCTAssertEqual(
            result.activeTaskIDs,
            [
                RewriteTaskCatalog.initial.tasks[0].id,
                RewriteTaskCatalog.initial.tasks[2].id,
            ]
        )
        XCTAssertEqual(
            result.unavailableByTaskID,
            [RewriteTaskCatalog.initial.tasks[1].id: .unavailable]
        )
        XCTAssertTrue(registrar.activeBindings.contains(.deterministicReplacement))
        XCTAssertTrue(registrar.activeBindings.contains(.codingAgentPrompt))
        XCTAssertTrue(registrar.activeBindings.contains(.formalEnglish))
    }

    @MainActor
    func testCandidateRegistrationFailureRestoresExactPreviousWorkingSet() throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        _ = registry.registerTasksAtLaunch(.initial)

        var candidate = RewriteTaskCatalog.initial
        let failingTask = makeTask(name: "Fourth", key: kVK_ANSI_Q)
        candidate.tasks.append(failingTask)
        registrar.registrationShouldFail = { binding, _ in
            binding == failingTask.shortcut
        }
        var persistWasCalled = false

        XCTAssertThrowsError(
            try registry.activateAllOrNothing(candidate) {
                persistWasCalled = true
            }
        ) { error in
            XCTAssertEqual(
                error as? RewriteTaskHotKeyActivationError,
                .candidateUnavailable(taskID: failingTask.id)
            )
        }
        XCTAssertFalse(persistWasCalled)
        XCTAssertEqual(registry.activeTasks, RewriteTaskCatalog.initial.tasks)
        XCTAssertEqual(
            Set(registrar.activeBindings),
            Set(RewriteTaskCatalog.initial.tasks.map(\.shortcut))
        )
    }

    @MainActor
    func testRollbackRestoresOnlyTheWorkingLaunchSubset() throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        registrar.registrationShouldFail = { binding, attempt in
            binding == .formalFrench && attempt == 1
        }
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        let launch = registry.registerTasksAtLaunch(.initial)
        XCTAssertEqual(launch.unavailableByTaskID.count, 1)

        let failingTask = makeTask(name: "Fourth", key: kVK_ANSI_Q)
        var candidate = RewriteTaskCatalog.initial
        candidate.tasks.append(failingTask)
        registrar.registrationShouldFail = { binding, _ in
            binding == failingTask.shortcut
        }

        XCTAssertThrowsError(
            try registry.activateAllOrNothing(candidate) {}
        )
        XCTAssertEqual(
            registry.activeTasks.map(\.id),
            [
                RewriteTaskCatalog.initial.tasks[0].id,
                RewriteTaskCatalog.initial.tasks[2].id,
            ]
        )
        XCTAssertFalse(registrar.activeBindings.contains(.formalFrench))
    }

    @MainActor
    func testPersistenceFailureRollsBackCandidateRegistrations() throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        _ = registry.registerTasksAtLaunch(.initial)

        var candidate = RewriteTaskCatalog.initial
        candidate.tasks[0].prompt = "Edited prompt"

        XCTAssertThrowsError(
            try registry.activateAllOrNothing(candidate) {
                throw TestFailure.expected
            }
        ) { error in
            XCTAssertEqual(
                error as? RewriteTaskHotKeyActivationError,
                .persistenceFailed
            )
        }
        XCTAssertEqual(registry.activeTasks, RewriteTaskCatalog.initial.tasks)
    }

    @MainActor
    func testRestoreFailureIsSurfacedAsBlocking() throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        _ = registry.registerTasksAtLaunch(.initial)

        let failingTask = makeTask(name: "Candidate", key: kVK_ANSI_Q)
        let candidate = RewriteTaskCatalog(
            schemaVersion: RewriteTaskCatalog.currentSchemaVersion,
            tasks: [failingTask]
        )
        registrar.registrationShouldFail = { binding, attempt in
            binding == failingTask.shortcut
                || (binding == .codingAgentPrompt && attempt == 2)
        }

        XCTAssertThrowsError(
            try registry.activateAllOrNothing(candidate) {}
        ) { error in
            let activationError = error as? RewriteTaskHotKeyActivationError
            XCTAssertEqual(activationError, .restoreFailed)
            XCTAssertEqual(activationError?.isBlocking, true)
        }
        XCTAssertTrue(registry.isBlockingFailure)
        XCTAssertTrue(registry.activeTasks.isEmpty)
    }

    @MainActor
    func testPartiallyUnregisteredOldSetBlocksRemoteTasksAndSkipsPersistence() async throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let recorder = TaskInvocationRecorder()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { task in
            recorder.tasks.append(task)
        }
        try registry.registerDeterministic {
            recorder.deterministicInvocationCount += 1
        }
        _ = registry.registerTasksAtLaunch(.initial)
        registrar.unregistrationRemovesBindingThenFails = { binding, attempt in
            binding == .formalFrench && attempt == 1
        }

        var didPersist = false
        XCTAssertThrowsError(
            try registry.activateAllOrNothing(.initial) {
                didPersist = true
            }
        ) { error in
            XCTAssertEqual(
                error as? RewriteTaskHotKeyActivationError,
                .restoreFailed
            )
        }

        XCTAssertFalse(didPersist)
        XCTAssertTrue(registry.isBlockingFailure)
        XCTAssertTrue(registry.activeTasks.isEmpty)
        await registrar.invoke(binding: .codingAgentPrompt)
        await registrar.invoke(binding: .formalFrench)
        await registrar.invoke(binding: .formalEnglish)
        XCTAssertTrue(recorder.tasks.isEmpty)
        XCTAssertEqual(
            Set(registrar.activeBindings),
            [.deterministicReplacement]
        )

        await registrar.invoke(binding: .deterministicReplacement)
        XCTAssertEqual(recorder.deterministicInvocationCount, 1)
    }

    @MainActor
    func testUnregisterAllClearsBookkeepingAndContinuesAfterPartialFailure() throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        try registry.registerDeterministic {}
        _ = registry.registerTasksAtLaunch(.initial)
        registrar.unregistrationRemovesBindingThenFails = { binding, attempt in
            binding == .formalFrench && attempt == 1
        }

        XCTAssertThrowsError(try registry.unregisterAll()) { error in
            XCTAssertEqual(
                error as? RewriteTaskHotKeyActivationError,
                .restoreFailed
            )
        }

        XCTAssertTrue(registry.isBlockingFailure)
        XCTAssertTrue(registry.activeTasks.isEmpty)
        XCTAssertTrue(registrar.activeBindings.isEmpty)
        XCTAssertEqual(registrar.unregistrationAttemptCount[.formalFrench], 1)
        XCTAssertNoThrow(try registry.unregisterAll())
        XCTAssertEqual(registrar.unregistrationAttemptCount[.formalFrench], 2)
    }

    @MainActor
    func testCandidateCleanupFailureBlocksResidualTaskRegistration() async throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let recorder = TaskInvocationRecorder()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { task in
            recorder.tasks.append(task)
        }
        try registry.registerDeterministic {
            recorder.deterministicInvocationCount += 1
        }
        _ = registry.registerTasksAtLaunch(.initial)

        let firstCandidate = makeTask(name: "Candidate Q", key: kVK_ANSI_Q)
        let failingCandidate = makeTask(name: "Candidate W", key: kVK_ANSI_W)
        let candidate = RewriteTaskCatalog(
            schemaVersion: RewriteTaskCatalog.currentSchemaVersion,
            tasks: [firstCandidate, failingCandidate]
        )
        registrar.registrationShouldFail = { binding, attempt in
            binding == failingCandidate.shortcut && attempt == 1
        }
        registrar.unregistrationShouldFail = { binding, attempt in
            binding == firstCandidate.shortcut && attempt == 1
        }

        var didPersist = false
        XCTAssertThrowsError(
            try registry.activateAllOrNothing(candidate) {
                didPersist = true
            }
        ) { error in
            XCTAssertEqual(
                error as? RewriteTaskHotKeyActivationError,
                .restoreFailed
            )
        }

        XCTAssertFalse(didPersist)
        XCTAssertTrue(registry.isBlockingFailure)
        await registrar.invoke(binding: firstCandidate.shortcut)
        XCTAssertTrue(recorder.tasks.isEmpty)
        await registrar.invoke(binding: .deterministicReplacement)
        XCTAssertEqual(recorder.deterministicInvocationCount, 1)
    }

    @MainActor
    func testSuccessfulActivationReturnsReceiptAndInvokesTaskSnapshot() async throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let recorder = TaskInvocationRecorder()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { task in
            recorder.tasks.append(task)
        }
        _ = registry.registerTasksAtLaunch(.initial)

        var candidate = RewriteTaskCatalog.initial
        candidate.tasks[0].prompt = "Edited prompt"
        var didPersist = false
        let receipt = try registry.activateAllOrNothing(candidate) {
            didPersist = true
        }
        candidate.tasks[0].prompt = "Later unsaved edit"

        await registrar.invoke(binding: .codingAgentPrompt)

        XCTAssertTrue(didPersist)
        XCTAssertEqual(
            receipt.previousWorkingTaskIDs,
            RewriteTaskCatalog.initial.tasks.map(\.id)
        )
        XCTAssertEqual(receipt.activeTaskIDs, candidate.tasks.map(\.id))
        XCTAssertEqual(recorder.tasks.count, 1)
        XCTAssertEqual(recorder.tasks[0].prompt, "Edited prompt")
    }

    @MainActor
    func testInFlightSnapshotSurvivesLaterEditAndDeletion() async throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let recorder = SuspendedTaskInvocationRecorder()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { task in
            await recorder.recordAndSuspend(task)
        }
        var originalCatalog = RewriteTaskCatalog.initial
        let originalPrompt = "\t Original cafe\u{0301} {taskPrompt}\r\n  "
        originalCatalog.tasks[0].prompt = originalPrompt
        _ = registry.registerTasksAtLaunch(originalCatalog)

        let firstInvocation = Task { @MainActor in
            await registrar.invoke(binding: .codingAgentPrompt)
        }
        while recorder.tasks.count < 1 {
            await Task.yield()
        }

        var editedCatalog = originalCatalog
        let editedPrompt = "\r\n Edited after invocation began: cafe\u{0301} {taskPrompt}\t"
        editedCatalog.tasks[0].prompt = editedPrompt
        _ = try registry.activateAllOrNothing(editedCatalog) {}
        recorder.resume()
        await firstInvocation.value

        XCTAssertEqual(
            Data(recorder.tasks[0].prompt.utf8),
            Data(originalPrompt.utf8)
        )

        let secondInvocation = Task { @MainActor in
            await registrar.invoke(binding: .codingAgentPrompt)
        }
        while recorder.tasks.count < 2 {
            await Task.yield()
        }

        let emptyCatalog = RewriteTaskCatalog(
            schemaVersion: RewriteTaskCatalog.currentSchemaVersion,
            tasks: []
        )
        _ = try registry.activateAllOrNothing(emptyCatalog) {}
        recorder.resume()
        await secondInvocation.value

        XCTAssertEqual(
            Data(recorder.tasks[1].prompt.utf8),
            Data(editedPrompt.utf8)
        )
        await registrar.invoke(binding: .codingAgentPrompt)
        XCTAssertEqual(recorder.tasks.count, 2)
    }

    @MainActor
    func testRecorderGateCapturesRegisteredTaskAndDeterministicBindings() async throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let recorder = TaskInvocationRecorder()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { task in
            recorder.tasks.append(task)
        }
        try registry.registerDeterministic {
            recorder.deterministicInvocationCount += 1
        }
        _ = registry.registerTasksAtLaunch(.initial)
        registry.beginShortcutRecording { binding in
            recorder.capturedBindings.append(binding)
        }

        await registrar.invoke(binding: .codingAgentPrompt)
        await registrar.invoke(binding: .deterministicReplacement)

        XCTAssertEqual(
            recorder.capturedBindings,
            [.codingAgentPrompt, .deterministicReplacement]
        )
        XCTAssertTrue(recorder.tasks.isEmpty)
        XCTAssertEqual(recorder.deterministicInvocationCount, 0)

        registry.endShortcutRecording()
        await registrar.invoke(binding: .codingAgentPrompt)
        await registrar.invoke(binding: .deterministicReplacement)

        XCTAssertEqual(recorder.tasks.count, 1)
        XCTAssertEqual(recorder.deterministicInvocationCount, 1)
    }

    @MainActor
    func testRuntimeIdentifiersAreUniqueProcessLocalDetails() throws {
        let registrar = FakeGlobalHotKeyRegistrar()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        try registry.registerDeterministic {}
        _ = registry.registerTasksAtLaunch(.initial)

        let identifiers = registrar.attempts.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)

        let encodedCatalog = try JSONEncoder().encode(RewriteTaskCatalog.initial)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedCatalog) as? [String: Any]
        )
        let tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        XCTAssertTrue(tasks.allSatisfy { $0["identifier"] == nil })
    }
}

@MainActor
private final class MemoryRewriteTaskCatalogStore: RewriteTaskCatalogDataStoring {
    var value: RewriteTaskCatalogStoredValue
    var replaceCount = 0
    var shouldFailReads = false
    var shouldFailWrites = false

    init(value: RewriteTaskCatalogStoredValue = .missing) {
        self.value = value
    }

    func storedValue() throws -> RewriteTaskCatalogStoredValue {
        if shouldFailReads { throw TestFailure.expected }
        return value
    }

    func replaceData(_ data: Data) throws {
        if shouldFailWrites { throw TestFailure.expected }
        replaceCount += 1
        value = .data(data)
    }

}

@MainActor
private final class FakeGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    struct Attempt {
        let binding: HotKeyBinding
        let identifier: UInt32
    }

    var registrationShouldFail: (HotKeyBinding, Int) -> Bool = { _, _ in false }
    var unregistrationShouldFail: (HotKeyBinding, Int) -> Bool = { _, _ in false }
    var unregistrationRemovesBindingThenFails: (HotKeyBinding, Int) -> Bool = {
        _, _ in false
    }
    private(set) var attempts: [Attempt] = []
    private var registrationAttemptCount: [HotKeyBinding: Int] = [:]
    private(set) var unregistrationAttemptCount: [HotKeyBinding: Int] = [:]
    private var activeByIdentifier: [UInt32: FakeGlobalHotKeyRegistration] = [:]

    var activeBindings: [HotKeyBinding] {
        activeByIdentifier.values.map(\.binding)
    }

    func register(
        binding: HotKeyBinding,
        identifier: UInt32,
        action: @escaping GlobalHotKeyAction
    ) throws -> any GlobalHotKeyRegistration {
        let attempt = registrationAttemptCount[binding, default: 0] + 1
        registrationAttemptCount[binding] = attempt
        attempts.append(Attempt(binding: binding, identifier: identifier))
        if registrationShouldFail(binding, attempt) {
            throw TestFailure.expected
        }

        let registration = FakeGlobalHotKeyRegistration(
            binding: binding,
            identifier: identifier,
            action: action,
            registrar: self
        )
        activeByIdentifier[identifier] = registration
        return registration
    }

    func unregister(_ registration: FakeGlobalHotKeyRegistration) throws {
        let binding = registration.binding
        let attempt = unregistrationAttemptCount[binding, default: 0] + 1
        unregistrationAttemptCount[binding] = attempt
        if unregistrationRemovesBindingThenFails(binding, attempt) {
            activeByIdentifier.removeValue(forKey: registration.identifier)
            throw TestFailure.expected
        }
        if unregistrationShouldFail(binding, attempt) {
            throw TestFailure.expected
        }
        activeByIdentifier.removeValue(forKey: registration.identifier)
    }

    func invoke(binding: HotKeyBinding) async {
        guard let registration = activeByIdentifier.values.first(where: {
            $0.binding == binding
        }) else {
            return
        }
        await registration.invoke()
    }
}

@MainActor
private final class FakeGlobalHotKeyRegistration: GlobalHotKeyRegistration {
    let binding: HotKeyBinding
    let identifier: UInt32
    private let action: GlobalHotKeyAction
    private weak var registrar: FakeGlobalHotKeyRegistrar?

    init(
        binding: HotKeyBinding,
        identifier: UInt32,
        action: @escaping GlobalHotKeyAction,
        registrar: FakeGlobalHotKeyRegistrar
    ) {
        self.binding = binding
        self.identifier = identifier
        self.action = action
        self.registrar = registrar
    }

    func unregister() throws {
        try registrar?.unregister(self)
    }

    func invoke() async {
        await action()
    }
}

@MainActor
private final class TaskInvocationRecorder {
    var tasks: [RewriteTask] = []
    var capturedBindings: [HotKeyBinding] = []
    var deterministicInvocationCount = 0
}

@MainActor
private final class SuspendedTaskInvocationRecorder {
    private(set) var tasks: [RewriteTask] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func recordAndSuspend(_ task: RewriteTask) async {
        tasks.append(task)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private enum TestFailure: Error {
    case expected
}

private func makeTask(
    name: String,
    key: Int,
    id: UUID = UUID()
) -> RewriteTask {
    RewriteTask(
        id: id,
        name: name,
        prompt: "Prompt for \(name)",
        shortcut: HotKeyBinding(
            virtualKey: UInt32(key),
            modifiers: HotKeyBinding.controlModifier
                | HotKeyBinding.optionModifier
                | HotKeyBinding.commandModifier
        )
    )
}
