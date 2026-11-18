import Foundation
import XCTest
@testable import ReCraft

final class RewriteProviderTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.recraft.rewrite-provider.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsToClaudeWhenNothingIsStored() {
        let setting = RewriteProviderSetting(defaults: defaults)

        XCTAssertEqual(RewriteProviderSetting.defaultsKey, "rewriteProvider.v1")
        XCTAssertNil(defaults.object(forKey: "rewriteProvider.v1"))
        XCTAssertEqual(setting.current, .claude)
        XCTAssertNil(defaults.object(forKey: "rewriteProvider.v1"))
    }

    func testUnknownStoredValueFallsBackToClaudeWithoutRewritingIt() {
        for stored in ["gemini", "OpenAI", "", "Claude"] {
            defaults.set(stored, forKey: "rewriteProvider.v1")
            let setting = RewriteProviderSetting(defaults: defaults)

            XCTAssertEqual(setting.current, .claude)
            XCTAssertEqual(defaults.string(forKey: "rewriteProvider.v1"), stored)
        }

        defaults.set(42, forKey: "rewriteProvider.v1")
        XCTAssertEqual(RewriteProviderSetting(defaults: defaults).current, .claude)
        XCTAssertEqual(defaults.integer(forKey: "rewriteProvider.v1"), 42)
    }

    func testSelectionPersistsAcrossInstances() {
        let first = RewriteProviderSetting(defaults: defaults)
        first.select(.openai)

        XCTAssertEqual(defaults.string(forKey: "rewriteProvider.v1"), "openai")
        let reopened = RewriteProviderSetting(
            defaults: UserDefaults(suiteName: suiteName)!
        )
        XCTAssertEqual(reopened.current, .openai)

        reopened.select(.claude)
        XCTAssertEqual(defaults.string(forKey: "rewriteProvider.v1"), "claude")
        XCTAssertEqual(first.current, .claude)
    }

    func testKeychainServiceNamesAreDistinctAndOpenAIServiceIsUnchanged() {
        XCTAssertEqual(
            KeychainAPIKeyStore.service(for: .claude),
            "com.weis49.ReCraft.anthropic-api-key"
        )
        XCTAssertEqual(
            KeychainAPIKeyStore.service(for: .openai),
            "com.weis49.ReCraft.openai-api-key"
        )
        XCTAssertNotEqual(
            KeychainAPIKeyStore.service(for: .claude),
            KeychainAPIKeyStore.service(for: .openai)
        )
        XCTAssertEqual(KeychainAPIKeyStore.account, "default")

        // Constructing a store does not touch Keychain.
        let claudeService = KeychainAPIKeyStore(provider: .claude).service
        let openAIService = KeychainAPIKeyStore(provider: .openai).service
        XCTAssertEqual(claudeService, "com.weis49.ReCraft.anthropic-api-key")
        XCTAssertEqual(openAIService, "com.weis49.ReCraft.openai-api-key")
    }

    @MainActor
    func testProviderMessagesNameTheProviderWithoutChangingRefusalIdentity() {
        typealias Refusal = ClipboardTextReplacementService.SafeRefusal

        XCTAssertEqual(Refusal.apiKeyMissing.rawValue, "apiKeyMissing")
        XCTAssertEqual(Refusal.apiFailure.rawValue, "apiFailure")
        XCTAssertEqual(Refusal.emptyModelResponse.rawValue, "emptyModelResponse")
        XCTAssertEqual(
            Refusal.apiKeyMissing.message(for: .claude),
            "Claude API key is not configured"
        )
        XCTAssertEqual(
            Refusal.apiKeyMissing.message(for: .openai),
            "OpenAI API key is not configured"
        )
        XCTAssertEqual(
            Refusal.apiFailure.message(for: .claude),
            "Claude request failed; original text preserved"
        )
        XCTAssertEqual(
            Refusal.emptyModelResponse.message(for: .openai),
            "OpenAI returned no text; original text preserved"
        )
        XCTAssertEqual(
            Refusal.keychainUnavailable.message(for: .claude),
            "The Claude API key could not be read from Keychain"
        )
        XCTAssertEqual(
            Refusal.selectionChanged.message(for: .claude),
            Refusal.selectionChanged.message
        )
        for refusal in [Refusal.apiKeyMissing, .apiFailure, .emptyModelResponse] {
            XCTAssertFalse(refusal.message.contains("OpenAI"))
            XCTAssertFalse(refusal.message.contains("Claude"))
        }

        XCTAssertTrue(RewriteProvider.claude.taskPromptDisclosure.contains("Claude"))
        XCTAssertFalse(RewriteProvider.claude.taskPromptDisclosure.contains("OpenAI"))
        XCTAssertTrue(RewriteProvider.openai.taskPromptDisclosure.contains("OpenAI"))
        XCTAssertFalse(RewriteProvider.openai.taskPromptDisclosure.contains("Claude"))
    }

    @MainActor
    func testSettingsModelSelectsProviderAndKeepsKeysSeparate() async {
        let setting = RewriteProviderSetting(defaults: defaults)
        let claudeStore = RoutingKeyStore(key: nil)
        let openAIStore = RoutingKeyStore(key: "synthetic-openai-key")
        let model = ProviderAPIKeySettingsModel(
            setting: setting,
            claudeKeyStore: claudeStore,
            openAIKeyStore: openAIStore
        )

        await model.refresh()
        XCTAssertEqual(model.selectedProvider, .claude)
        XCTAssertFalse(model.isConfigured)
        XCTAssertTrue(model.openAIKey.isConfigured)

        model.claudeKey.draftKey = "  synthetic-claude-key "
        await model.claudeKey.save()
        XCTAssertTrue(model.isConfigured)
        let savedClaudeKey = await claudeStore.loadKey()
        let untouchedOpenAIKey = await openAIStore.loadKey()
        XCTAssertEqual(savedClaudeKey, "synthetic-claude-key")
        XCTAssertEqual(untouchedOpenAIKey, "synthetic-openai-key")

        model.select(.openai)
        XCTAssertEqual(setting.current, .openai)
        XCTAssertEqual(defaults.string(forKey: "rewriteProvider.v1"), "openai")
        await model.openAIKey.delete()
        XCTAssertFalse(model.isConfigured)
        XCTAssertTrue(model.claudeKey.isConfigured)
        let deletedOpenAIKey = await openAIStore.loadKey()
        let keptClaudeKey = await claudeStore.loadKey()
        XCTAssertNil(deletedOpenAIKey)
        XCTAssertEqual(keptClaudeKey, "synthetic-claude-key")

        model.claudeKey.draftKey = "unsaved"
        model.openAIKey.draftKey = "unsaved"
        model.clearDrafts()
        XCTAssertEqual(model.claudeKey.draftKey, "")
        XCTAssertEqual(model.openAIKey.draftKey, "")
    }
}

final class RewriteProviderRoutingTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.recraft.rewrite-routing.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testClaudeSelectionSendsOnlyToAnthropicWithClaudeKey() async throws {
        // Nothing stored: the default provider is Claude.
        let fixture = try makeFixture(
            claudeKey: "synthetic-claude-key",
            openAIKey: "synthetic-openai-key"
        )

        let result = try await fixture.rewriter.rewrite(
            "Selected 中文 🙂\n",
            taskPrompt: "Task prompt\n"
        )

        XCTAssertEqual(result.text, "claude result")
        let claudeRequests = await fixture.claudeRecorder.requests
        let openAIRequests = await fixture.openAIRecorder.requests
        XCTAssertEqual(openAIRequests.count, 0)
        XCTAssertEqual(claudeRequests.count, 1)
        let request = try XCTUnwrap(claudeRequests.first)
        XCTAssertEqual(request.url, URL(string: "https://api.anthropic.com/v1/messages"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-api-key"),
            "synthetic-claude-key"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try jsonBody(request)
        XCTAssertEqual(body["system"] as? String, "Task prompt\n")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "Selected 中文 🙂\n")

        let claudeLoads = await fixture.claudeStore.loadCount
        let openAILoads = await fixture.openAIStore.loadCount
        XCTAssertEqual(claudeLoads, 1)
        XCTAssertEqual(openAILoads, 0)
    }

    func testOpenAISelectionSendsOnlyToOpenAIWithOpenAIKey() async throws {
        RewriteProviderSetting(defaults: defaults).select(.openai)
        let fixture = try makeFixture(
            claudeKey: "synthetic-claude-key",
            openAIKey: "synthetic-openai-key"
        )

        let result = try await fixture.rewriter.rewrite(
            "Selected source",
            taskPrompt: "Task prompt"
        )

        XCTAssertEqual(result.text, "openai result")
        let claudeRequests = await fixture.claudeRecorder.requests
        let openAIRequests = await fixture.openAIRecorder.requests
        XCTAssertEqual(claudeRequests.count, 0)
        XCTAssertEqual(openAIRequests.count, 1)
        let request = try XCTUnwrap(openAIRequests.first)
        XCTAssertEqual(request.url, URL(string: "https://api.openai.com/v1/responses"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer synthetic-openai-key"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

        let body = try jsonBody(request)
        XCTAssertEqual(
            Set(body.keys),
            [
                "model", "store", "instructions", "input", "reasoning", "text",
                "tools", "max_output_tokens", "service_tier", "truncation",
            ]
        )
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, "Task prompt")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2_400)
        XCTAssertEqual(body["service_tier"] as? String, "default")
        XCTAssertEqual(body["truncation"] as? String, "disabled")
        XCTAssertEqual((body["tools"] as? [Any])?.count, 0)
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Selected source")

        let claudeLoads = await fixture.claudeStore.loadCount
        let openAILoads = await fixture.openAIStore.loadCount
        XCTAssertEqual(claudeLoads, 0)
        XCTAssertEqual(openAILoads, 1)
    }

    func testMissingClaudeKeyFailsBeforeAnyRequestEvenWhenOpenAIKeyExists() async throws {
        let fixture = try makeFixture(
            claudeKey: nil,
            openAIKey: "synthetic-openai-key"
        )

        do {
            _ = try await fixture.rewriter.rewrite("selected", taskPrompt: "prompt")
            XCTFail("Expected the missing Claude key to stop the request")
        } catch {
            XCTAssertEqual(error as? CodingPromptRewriteError, .apiKeyMissing)
        }

        let claudeRequests = await fixture.claudeRecorder.requests
        let openAIRequests = await fixture.openAIRecorder.requests
        XCTAssertEqual(claudeRequests.count, 0)
        XCTAssertEqual(openAIRequests.count, 0)
        let openAILoads = await fixture.openAIStore.loadCount
        XCTAssertEqual(openAILoads, 0)
    }

    func testProviderIsReadAtTheStartOfEachCall() async throws {
        let setting = RewriteProviderSetting(defaults: defaults)
        let fixture = try makeFixture(
            claudeKey: "synthetic-claude-key",
            openAIKey: "synthetic-openai-key"
        )

        XCTAssertEqual(fixture.rewriter.provider(), .claude)
        _ = try await fixture.rewriter.rewrite("one", taskPrompt: "prompt")
        setting.select(.openai)
        XCTAssertEqual(fixture.rewriter.provider(), .openai)
        _ = try await fixture.rewriter.rewrite("two", taskPrompt: "prompt")

        // An explicitly captured provider wins over a later setting change.
        _ = try await fixture.rewriter.rewrite(
            "three",
            taskPrompt: "prompt",
            provider: .claude
        )

        let claudeRequests = await fixture.claudeRecorder.requests
        let openAIRequests = await fixture.openAIRecorder.requests
        XCTAssertEqual(claudeRequests.count, 2)
        XCTAssertEqual(openAIRequests.count, 1)
    }

    private func makeFixture(
        claudeKey: String?,
        openAIKey: String?
    ) throws -> (
        rewriter: CodingPromptRewriter,
        claudeStore: RoutingKeyStore,
        openAIStore: RoutingKeyStore,
        claudeRecorder: RoutingRequestRecorder,
        openAIRecorder: RoutingRequestRecorder
    ) {
        let claudeStore = RoutingKeyStore(key: claudeKey)
        let openAIStore = RoutingKeyStore(key: openAIKey)
        let claudeRecorder = RoutingRequestRecorder()
        let openAIRecorder = RoutingRequestRecorder()

        let claudeData = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "claude result"]],
        ])
        let claudeResponse = HTTPURLResponse(
            url: AnthropicMessagesClient.endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let openAIData = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": "openai result"]],
            ]],
        ])
        let openAIResponse = HTTPURLResponse(
            url: OpenAIResponsesClient.endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!

        let rewriter = CodingPromptRewriter(
            providerSetting: RewriteProviderSetting(defaults: defaults),
            openAIKeyStore: openAIStore,
            claudeKeyStore: claudeStore,
            openAIClient: OpenAIResponsesClient { request in
                await openAIRecorder.record(request)
                return (openAIData, openAIResponse)
            },
            claudeClient: AnthropicMessagesClient { request in
                await claudeRecorder.record(request)
                return (claudeData, claudeResponse)
            }
        )
        return (rewriter, claudeStore, openAIStore, claudeRecorder, openAIRecorder)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
    }
}

private actor RoutingRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private actor RoutingKeyStore: APIKeyStoring {
    private var key: String?
    private(set) var loadCount = 0

    init(key: String?) {
        self.key = key
    }

    func containsKey() -> Bool {
        key != nil
    }

    func loadKey() -> String? {
        loadCount += 1
        return key
    }

    func saveKey(_ key: String) {
        self.key = key
    }

    func deleteKey() {
        key = nil
    }
}
