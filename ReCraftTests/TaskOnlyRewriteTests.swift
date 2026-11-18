import Foundation
import XCTest
@testable import ReCraft

final class TaskOnlyRewriteTests: XCTestCase {
    func testNormalRewriterPreservesPromptAndSourceUTF8WithoutInterpolation() async throws {
        let prompt = "\t  Rewrite cafe\u{0301}.\r\nKeep literal {taskPrompt}.\n  "
        let source = " \r\nSOURCE-ONLY cafe\u{0301} 🙂\rline two {taskPrompt}\t "
        let output = "\r\n  Rewritten cafe\u{0301} 🙂\n "
        let store = TaskOnlyInMemoryAPIKeyStore()
        let recorder = TaskOnlyRequestRecorder()
        let rewriter = CodingPromptRewriter(
            apiKeyStore: store,
            client: try successClient(recording: recorder, output: output)
        )

        let result = try await rewriter.rewrite(source, taskPrompt: prompt)

        let requestBodies = await recorder.bodies
        XCTAssertEqual(requestBodies.count, 1)
        let body = try jsonBody(try XCTUnwrap(requestBodies.first))
        try assertExactRequest(body, prompt: prompt, source: source)
        XCTAssertEqual(Data(result.text.utf8), Data(output.utf8))
        let loadCount = await store.loadCount
        let containsCount = await store.containsCount
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(containsCount, 0)
    }

    func testTaskNamesAndIDsDoNotSelectHiddenRequestBehavior() async throws {
        let store = TaskOnlyInMemoryAPIKeyStore()
        let recorder = TaskOnlyRequestRecorder()
        let rewriter = CodingPromptRewriter(
            apiKeyStore: store,
            client: try successClient(recording: recorder, output: "Synthetic result")
        )

        var renamed = RewriteTaskCatalog.initial.tasks[0]
        renamed.name = "Formal French"
        var editedBuiltIn = RewriteTaskCatalog.initial.tasks[1]
        editedBuiltIn.prompt = "\t Convert this text to second person.\r\nNo additional instruction. "
        let arbitrary = RewriteTask(
            id: UUID(uuidString: "D8ED06D2-CA1D-487A-A069-331D19A8B664")!,
            name: "Coding Agent Prompt",
            prompt: "Convert this text to third person; retain literal {taskPrompt}.",
            shortcut: .formalEnglish
        )
        let snapshots = [renamed, editedBuiltIn, arbitrary]
        let sources = ["Synthetic source one", "Synthetic source two", "Synthetic source three"]

        for (snapshot, source) in zip(snapshots, sources) {
            _ = try await rewriter.rewrite(source, taskPrompt: snapshot.prompt)
        }

        let requestBodies = await recorder.bodies
        XCTAssertEqual(requestBodies.count, snapshots.count)
        for index in snapshots.indices {
            let body = try jsonBody(requestBodies[index])
            try assertExactRequest(body, prompt: snapshots[index].prompt, source: sources[index])
        }
        let loadCount = await store.loadCount
        XCTAssertEqual(loadCount, snapshots.count)
    }

    @MainActor
    func testSettingsSavesPromptEditThatOnlyChangesUnicodeBytes() throws {
        let composed = "Rewrite caf\u{00e9}."
        let decomposed = "Rewrite cafe\u{0301}."
        var catalog = RewriteTaskCatalog.initial
        catalog.tasks[0].prompt = composed
        let fixture = try makeSettings(catalog: catalog)
        let taskID = catalog.tasks[0].id

        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        XCTAssertFalse(fixture.model.isDirty)
        XCTAssertFalse(fixture.model.canSave)
        fixture.model.updateSelectedTaskPrompt(decomposed)

        XCTAssertTrue(fixture.model.isDirty)
        XCTAssertTrue(fixture.model.canSave)
        XCTAssertTrue(fixture.model.isTaskModified(taskID))
        fixture.model.save()

        XCTAssertFalse(fixture.model.isDirty)
        XCTAssertEqual(fixture.store.replaceCount, 1)
        let activeTask = try XCTUnwrap(fixture.registry.activeTasks.first)
        XCTAssertEqual(Data(activeTask.prompt.utf8), Data(decomposed.utf8))
        fixture.model.load()
        let reloadedTask = try XCTUnwrap(fixture.model.selectedTask)
        XCTAssertEqual(reloadedTask.id, taskID)
        XCTAssertEqual(Data(reloadedTask.prompt.utf8), Data(decomposed.utf8))
    }

    @MainActor
    func testSettingsSavesNameEditThatOnlyChangesUnicodeBytes() throws {
        let composed = "Caf\u{00e9} task"
        let decomposed = "Cafe\u{0301} task"
        var catalog = RewriteTaskCatalog.initial
        catalog.tasks[0].name = composed
        let fixture = try makeSettings(catalog: catalog)
        fixture.model.updateSelectedTaskName(decomposed)

        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        XCTAssertTrue(fixture.model.isDirty)
        XCTAssertTrue(fixture.model.canSave)
        fixture.model.save()

        XCTAssertFalse(fixture.model.isDirty)
        XCTAssertEqual(fixture.store.replaceCount, 1)
        fixture.model.load()
        let reloadedTask = try XCTUnwrap(fixture.model.selectedTask)
        XCTAssertEqual(Data(reloadedTask.name.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(reloadedTask.prompt.utf8), Data(catalog.tasks[0].prompt.utf8))
    }

    @MainActor
    func testInFlightSnapshotKeepsOriginalBytesAfterUnicodeOnlyPromptSave() async throws {
        let composed = "Rewrite caf\u{00e9}."
        let decomposed = "Rewrite cafe\u{0301}."
        var catalog = RewriteTaskCatalog.initial
        catalog.tasks[0].prompt = composed
        let fixture = try makeSettings(catalog: catalog)
        let recorder = TaskOnlySuspendedSnapshotRecorder()
        fixture.registry.setTaskAction { snapshot in
            await recorder.record(snapshot)
        }

        let invocation = Task { @MainActor in
            await fixture.registrar.invoke(.codingAgentPrompt)
        }
        while recorder.snapshots.isEmpty {
            await Task.yield()
        }
        fixture.model.updateSelectedTaskPrompt(decomposed)
        XCTAssertTrue(fixture.model.canSave)
        fixture.model.save()
        XCTAssertEqual(fixture.store.replaceCount, 1)
        let firstSnapshot = try XCTUnwrap(recorder.snapshots.first)
        XCTAssertEqual(Data(firstSnapshot.prompt.utf8), Data(composed.utf8))

        recorder.resume()
        await invocation.value
        await fixture.registrar.invoke(.codingAgentPrompt)

        XCTAssertEqual(recorder.snapshots.count, 2)
        let nextSnapshot = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(Data(nextSnapshot.prompt.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(firstSnapshot.prompt.utf8), Data(composed.utf8))
    }

    @MainActor
    private func makeSettings(catalog: RewriteTaskCatalog) throws -> (
        model: RewriteTaskSettingsModel,
        store: TaskOnlyMemoryCatalogStore,
        registry: RewriteTaskHotKeyRegistry,
        registrar: TaskOnlyFakeHotKeyRegistrar
    ) {
        let store = try TaskOnlyMemoryCatalogStore(catalog: catalog)
        let registrar = TaskOnlyFakeHotKeyRegistrar()
        let registry = RewriteTaskHotKeyRegistry(registrar: registrar)
        registry.setTaskAction { _ in }
        _ = registry.registerTasksAtLaunch(catalog)
        let model = RewriteTaskSettingsModel(
            persistence: RewriteTaskCatalogPersistence(store: store),
            activator: registry,
            shortcutRecorder: registry
        )
        return (model, store, registry, registrar)
    }

    private func successClient(
        recording recorder: TaskOnlyRequestRecorder,
        output: String
    ) throws -> OpenAIResponsesClient {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": output]],
            ]],
        ])
        let response = HTTPURLResponse(
            url: OpenAIResponsesClient.endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return OpenAIResponsesClient { request in
            await recorder.record(request.httpBody)
            return (data, response)
        }
    }

    private func jsonBody(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any]
        )
    }

    private func assertExactRequest(
        _ body: [String: Any],
        prompt: String,
        source: String
    ) throws {
        XCTAssertEqual(
            Set(body.keys),
            [
                "model", "store", "instructions", "input", "reasoning", "text",
                "tools", "max_output_tokens", "service_tier", "truncation",
            ]
        )
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertEqual(Data(instructions.utf8), Data(prompt.utf8))
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        let message = try XCTUnwrap(input.first)
        XCTAssertEqual(Set(message.keys), ["role", "content"])
        XCTAssertEqual(message["role"] as? String, "user")
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        let item = try XCTUnwrap(content.first)
        XCTAssertEqual(Set(item.keys), ["type", "text"])
        XCTAssertEqual(item["type"] as? String, "input_text")
        let selectedText = try XCTUnwrap(item["text"] as? String)
        XCTAssertEqual(Data(selectedText.utf8), Data(source.utf8))
    }
}

private actor TaskOnlyRequestRecorder {
    private(set) var bodies: [Data?] = []

    func record(_ body: Data?) {
        bodies.append(body)
    }
}

private actor TaskOnlyInMemoryAPIKeyStore: APIKeyStoring {
    private(set) var loadCount = 0
    private(set) var containsCount = 0

    func loadKey() -> String? {
        loadCount += 1
        return "synthetic-task-only-test-key"
    }

    func containsKey() -> Bool {
        containsCount += 1
        return true
    }

    func saveKey(_ key: String) {}

    func deleteKey() {}
}

@MainActor
private final class TaskOnlyMemoryCatalogStore: RewriteTaskCatalogDataStoring {
    private var data: Data
    private(set) var replaceCount = 0

    init(catalog: RewriteTaskCatalog) throws {
        data = try JSONEncoder().encode(catalog)
    }

    func storedValue() -> RewriteTaskCatalogStoredValue { .data(data) }

    func replaceData(_ data: Data) {
        replaceCount += 1
        self.data = data
    }
}

@MainActor
private final class TaskOnlyFakeHotKeyRegistrar: GlobalHotKeyRegistering {
    private var registrations: [TaskOnlyFakeHotKeyRegistration] = []

    func register(
        binding: HotKeyBinding,
        identifier: UInt32,
        action: @escaping GlobalHotKeyAction
    ) -> any GlobalHotKeyRegistration {
        let registration = TaskOnlyFakeHotKeyRegistration(binding: binding, action: action)
        registrations.append(registration)
        return registration
    }

    func invoke(_ binding: HotKeyBinding) async {
        guard let registration = registrations.last(where: {
            $0.isRegistered && $0.binding == binding
        }) else { return }
        await registration.action()
    }
}

@MainActor
private final class TaskOnlyFakeHotKeyRegistration: GlobalHotKeyRegistration {
    let binding: HotKeyBinding
    let action: GlobalHotKeyAction
    var isRegistered = true

    init(binding: HotKeyBinding, action: @escaping GlobalHotKeyAction) {
        self.binding = binding
        self.action = action
    }

    func unregister() { isRegistered = false }
}

@MainActor
private final class TaskOnlySuspendedSnapshotRecorder {
    private(set) var snapshots: [RewriteTask] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func record(_ snapshot: RewriteTask) async {
        snapshots.append(snapshot)
        guard snapshots.count == 1 else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
