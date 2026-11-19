import Foundation
import XCTest
@testable import ReCraft

private typealias Notice = RewriteTaskSettingsModel.PromptGenerationNotice

final class TaskPromptGenerationSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.recraft.prompt-generation-settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // 12
    @MainActor
    func testSuccessfulGenerationFillsOnlyTheDraft() async throws {
        let harness = try makeGenerationHarness(defaults: defaults)
        let fixture = makeGenerationSettingsModel(generator: harness.generator)
        let model = fixture.model
        let writesBefore = fixture.store.writeCount
        let storedBefore = fixture.store.value

        model.addTask()
        let taskID = try XCTUnwrap(model.selectedTaskID)
        XCTAssertEqual(model.selectedTask?.name, "New Task")
        XCTAssertFalse(model.promptGenerationRequiresConfirmation)
        model.generationDescription = "把选中的中文改写成礼貌的英文邮件语气，保留所有事实"
        XCTAssertTrue(model.canGeneratePrompt)

        await model.generatePrompt()

        let task = try XCTUnwrap(model.selectedTask)
        XCTAssertEqual(task.id, taskID)
        XCTAssertEqual(task.name, GenerationFixtures.generatedName)
        XCTAssertEqual(task.prompt, GenerationFixtures.generatedPrompt)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.isTaskModified(taskID))
        XCTAssertNil(model.fieldErrors[taskID]?.name)
        XCTAssertNil(model.fieldErrors[taskID]?.prompt)
        // The shortcut is never chosen automatically.
        XCTAssertEqual(
            model.fieldErrors[taskID]?.shortcut,
            "Record a shortcut using an A–Z key."
        )
        XCTAssertEqual(model.persistedCatalog, .initial)
        XCTAssertEqual(fixture.store.writeCount, writesBefore)
        XCTAssertEqual(fixture.store.value, storedBefore)
        XCTAssertEqual(fixture.runtime.activationCount, 0)
        XCTAssertFalse(model.isGeneratingPrompt)
        XCTAssertEqual(
            model.promptGenerationNotice,
            Notice(message: "Prompt generated — review it, record a shortcut, then save", tone: .success)
        )
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(
            model.generationDescription,
            "把选中的中文改写成礼貌的英文邮件语气，保留所有事实"
        )
        let requests = await harness.claudeRecorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    // 13
    @MainActor
    func testFailureLeavesDraftUnchangedAndReportsError() async throws {
        let failures: [(GenerationHarness, TaskPromptGenerationError)] = [
            (try makeGenerationHarness(defaults: defaults, claudeStatusCode: 500), .apiFailure),
            (try makeGenerationHarness(defaults: defaults, claudeFailsWithNetworkError: true), .networkFailure),
            (try makeGenerationHarness(defaults: defaults, claudeKey: nil), .apiKeyMissing(.claude)),
            (
                try makeGenerationHarness(
                    defaults: defaults,
                    claudeData: GenerationFixtures.claudeData(text: GenerationFixtures.validOutput, stopReason: "refusal")
                ),
                .refusal
            ),
            (
                try makeGenerationHarness(
                    defaults: defaults,
                    claudeData: GenerationFixtures.claudeData(text: "<task_name>Name</task_name>")
                ),
                .unusableOutput
            ),
        ]

        for (harness, expected) in failures {
            let fixture = makeGenerationSettingsModel(generator: harness.generator)
            let model = fixture.model
            model.addTask()
            let draftBefore = model.draftCatalog
            model.generationDescription = "Make it formal."

            await model.generatePrompt()

            XCTAssertEqual(model.draftCatalog, draftBefore)
            XCTAssertFalse(model.isGeneratingPrompt)
            XCTAssertEqual(
                model.promptGenerationNotice,
                Notice(message: expected.message, tone: .failure)
            )
        }

        XCTAssertTrue(TaskPromptGenerationError.apiKeyMissing(.claude).message.contains("Claude"))
        XCTAssertNotEqual(
            TaskPromptGenerationError.networkFailure.message,
            TaskPromptGenerationError.unusableOutput.message
        )
        XCTAssertNotEqual(
            TaskPromptGenerationError.networkFailure.message,
            TaskPromptGenerationError.refusal.message
        )
    }

    // 14
    @MainActor
    func testBlankDescriptionDoesNotSendARequest() async throws {
        let harness = try makeGenerationHarness(defaults: defaults)
        let model = makeGenerationSettingsModel(generator: harness.generator).model
        model.addTask()
        let draftBefore = model.draftCatalog

        for description in ["", " ", " \n\t\r\n "] {
            model.generationDescription = description
            XCTAssertFalse(model.canGeneratePrompt)
            await model.generatePrompt()
            await model.generatePrompt(confirmedReplacement: true)
        }

        let claudeRequests = await harness.claudeRecorder.requests
        let openAIRequests = await harness.openAIRecorder.requests
        let keyLoads = await harness.claudeStore.loadCount
        XCTAssertEqual(claudeRequests.count, 0)
        XCTAssertEqual(openAIRequests.count, 0)
        XCTAssertEqual(keyLoads, 0)
        XCTAssertEqual(model.draftCatalog, draftBefore)
        XCTAssertNil(model.promptGenerationNotice)
    }

    // 15
    @MainActor
    func testResultIsDiscardedWhenSelectionChangedDuringGeneration() async throws {
        // Switching away (and even back) discards the result.
        do {
            let gate = GenerationGate()
            let harness = try makeGenerationHarness(defaults: defaults, gate: gate)
            let model = makeGenerationSettingsModel(generator: harness.generator).model
            model.addTask()
            let taskID = try XCTUnwrap(model.selectedTaskID)
            let draftBefore = model.draftCatalog
            model.generationDescription = "Make it formal."

            let generation = Task { await model.generatePrompt() }
            await gate.waitForArrival()
            XCTAssertTrue(model.isGeneratingPrompt)
            model.selectTask(RewriteTaskCatalog.initial.tasks[0].id)
            model.selectTask(taskID)
            await gate.open()
            await generation.value

            XCTAssertEqual(model.draftCatalog, draftBefore)
            XCTAssertNil(model.promptGenerationNotice)
            XCTAssertFalse(model.isGeneratingPrompt)
            XCTAssertEqual(model.generationDescription, "Make it formal.")
        }

        // Deleting the task discards the result.
        do {
            let gate = GenerationGate()
            let harness = try makeGenerationHarness(defaults: defaults, gate: gate)
            let model = makeGenerationSettingsModel(generator: harness.generator).model
            model.addTask()
            let taskID = try XCTUnwrap(model.selectedTaskID)
            model.generationDescription = "Make it formal."

            let generation = Task { await model.generatePrompt() }
            await gate.waitForArrival()
            model.deleteTaskAfterConfirmation(taskID)
            let draftAfterDeletion = model.draftCatalog
            await gate.open()
            await generation.value

            XCTAssertEqual(model.draftCatalog, draftAfterDeletion)
            XCTAssertNil(model.promptGenerationNotice)
        }

        // Closing the Settings window discards the result and the description.
        do {
            let gate = GenerationGate()
            let harness = try makeGenerationHarness(defaults: defaults, gate: gate)
            let model = makeGenerationSettingsModel(generator: harness.generator).model
            model.generationDescription = "Make it formal."
            model.updateSelectedTaskPrompt("")
            model.updateSelectedTaskName("")

            let generation = Task { await model.generatePrompt() }
            await gate.waitForArrival()
            model.settingsWindowDidClose()
            await gate.open()
            await generation.value

            XCTAssertEqual(model.draftCatalog, .initial)
            XCTAssertNil(model.promptGenerationNotice)
            XCTAssertEqual(model.generationDescription, "")
        }

        // Edits made while waiting are never overwritten.
        do {
            let gate = GenerationGate()
            let harness = try makeGenerationHarness(defaults: defaults, gate: gate)
            let model = makeGenerationSettingsModel(generator: harness.generator).model
            model.addTask()
            model.generationDescription = "Make it formal."

            let generation = Task { await model.generatePrompt() }
            await gate.waitForArrival()
            model.updateSelectedTaskPrompt("Typed while waiting")
            await gate.open()
            await generation.value

            XCTAssertEqual(model.selectedTask?.name, "New Task")
            XCTAssertEqual(model.selectedTask?.prompt, "Typed while waiting")
            XCTAssertEqual(
                model.promptGenerationNotice,
                Notice(
                    message: RewriteTaskSettingsModel.promptGenerationDraftChangedMessage,
                    tone: .failure
                )
            )
        }
    }

    // 16
    @MainActor
    func testSecondGenerationIsIgnoredWhileOneIsRunning() async throws {
        let gate = GenerationGate()
        let harness = try makeGenerationHarness(defaults: defaults, gate: gate)
        let model = makeGenerationSettingsModel(generator: harness.generator).model
        model.addTask()
        model.generationDescription = "Make it formal."

        let generation = Task { await model.generatePrompt() }
        await gate.waitForArrival()
        XCTAssertTrue(model.isGeneratingPrompt)
        XCTAssertFalse(model.canGeneratePrompt)

        await model.generatePrompt()
        await model.generatePrompt(confirmedReplacement: true)

        let requestsWhileRunning = await harness.claudeRecorder.requests
        XCTAssertEqual(requestsWhileRunning.count, 1)

        await gate.open()
        await generation.value

        let requests = await harness.claudeRecorder.requests
        let arrivals = await gate.arrivals
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(arrivals, 1)
        XCTAssertFalse(model.isGeneratingPrompt)
        XCTAssertEqual(model.selectedTask?.prompt, GenerationFixtures.generatedPrompt)
    }

    // 17
    func testGenerationSessionUsesItsOwnLongerTimeout() throws {
        let generationConfiguration = TaskPromptGenerator.makeSessionConfiguration()
        XCTAssertEqual(generationConfiguration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(generationConfiguration.timeoutIntervalForResource, 120)
        XCTAssertNil(generationConfiguration.urlCache)
        XCTAssertNil(generationConfiguration.httpCookieStorage)
        XCTAssertFalse(generationConfiguration.httpShouldSetCookies)
        XCTAssertEqual(generationConfiguration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        let generationSession = TaskPromptGenerator.makeSession()
        XCTAssertEqual(generationSession.configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(generationSession.configuration.timeoutIntervalForResource, 120)
        XCTAssertTrue(generationSession.delegate is NoRedirectSessionDelegate)

        let rewriteSession = OpenAISessionFactory.makeSession()
        XCTAssertEqual(rewriteSession.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(rewriteSession.configuration.timeoutIntervalForResource, 30)
        XCTAssertTrue(rewriteSession.delegate is NoRedirectSessionDelegate)

        let claudeGeneration = try TaskPromptGenerator.makeClaudeRequest(
            description: "d",
            apiKey: "synthetic-claude-key"
        )
        let openAIGeneration = try TaskPromptGenerator.makeOpenAIRequest(
            description: "d",
            apiKey: "synthetic-openai-key"
        )
        XCTAssertEqual(claudeGeneration.timeoutInterval, 120)
        XCTAssertEqual(openAIGeneration.timeoutInterval, 120)

        let claudeRewrite = try AnthropicMessagesClient.makeRequest(
            selectedText: "s",
            instructions: "p",
            apiKey: "synthetic-claude-key"
        )
        let openAIRewrite = try OpenAIResponsesClient.makeRequest(
            selectedText: "s",
            instructions: "p",
            apiKey: "synthetic-openai-key"
        )
        XCTAssertEqual(claudeRewrite.timeoutInterval, 30)
        XCTAssertEqual(openAIRewrite.timeoutInterval, 30)
    }

    // 18
    @MainActor
    func testConfirmationIsRequiredOnlyWhenDraftPromptIsNotBlank() async throws {
        let harness = try makeGenerationHarness(defaults: defaults)
        let model = makeGenerationSettingsModel(generator: harness.generator).model
        model.addTask()
        model.generationDescription = "Make it formal."

        XCTAssertFalse(model.promptGenerationRequiresConfirmation)
        model.updateSelectedTaskPrompt(" \n\t ")
        XCTAssertFalse(model.promptGenerationRequiresConfirmation)
        model.updateSelectedTaskPrompt("Existing prompt")
        XCTAssertTrue(model.promptGenerationRequiresConfirmation)

        // Without confirmation no request is sent.
        await model.generatePrompt()
        var requests = await harness.claudeRecorder.requests
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(model.selectedTask?.prompt, "Existing prompt")

        // A confirmed generation replaces both the name and the prompt.
        model.updateSelectedTaskName("My own name")
        await model.generatePrompt(confirmedReplacement: true)
        requests = await harness.claudeRecorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.selectedTask?.name, GenerationFixtures.generatedName)
        XCTAssertEqual(model.selectedTask?.prompt, GenerationFixtures.generatedPrompt)

        // An unconfirmed generation (blank prompt) keeps a name the user typed.
        model.updateSelectedTaskName("My own name")
        model.updateSelectedTaskPrompt("")
        XCTAssertFalse(model.promptGenerationRequiresConfirmation)
        await model.generatePrompt()
        XCTAssertEqual(model.selectedTask?.name, "My own name")
        XCTAssertEqual(model.selectedTask?.prompt, GenerationFixtures.generatedPrompt)

        // ...but replaces a blank name.
        model.updateSelectedTaskName("  ")
        model.updateSelectedTaskPrompt("")
        await model.generatePrompt()
        XCTAssertEqual(model.selectedTask?.name, GenerationFixtures.generatedName)
    }
}
