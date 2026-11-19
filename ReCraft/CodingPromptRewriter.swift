import Foundation
import OSLog

final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Builds the ephemeral, cache-free, cookie-free, no-redirect sessions used by
/// both providers. Task rewrites use the 30-second default; only task prompt
/// generation passes its own longer timeout.
enum OpenAISessionFactory {
    static let rewriteTimeout: TimeInterval = 30

    static func makeConfiguration(
        timeout: TimeInterval = rewriteTimeout
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    static func makeSession(
        timeout: TimeInterval = rewriteTimeout
    ) -> URLSession {
        let configuration = makeConfiguration(timeout: timeout)
        return URLSession(
            configuration: configuration,
            delegate: NoRedirectSessionDelegate(),
            delegateQueue: nil
        )
    }
}

enum CodingPromptRewriteError: Error, Equatable {
    case apiKeyMissing
    case keychainUnavailable
    case networkFailure
    case apiFailure
    case refusal
    case emptyResponse
}

struct CodingPromptRewriteResult: Equatable {
    let text: String
    let generationDuration: Duration
    let usage: OpenAIResponseUsage?
}

struct OpenAIResponseUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int?
    let outputTokens: Int
    let reasoningTokens: Int?
    let totalTokens: Int
}

struct OpenAIResponsesClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let model = "gpt-5.6-luna"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let maxOutputTokens = 2_400

    private static let logger = Logger(
        subsystem: "com.weis49.ReCraft",
        category: "OpenAI"
    )
    private let load: DataLoader

    init() {
        let session = OpenAISessionFactory.makeSession()
        load = { request in
            try await session.data(for: request)
        }
    }

    init(load: @escaping DataLoader) {
        self.load = load
    }

    func rewrite(
        selectedText: String,
        instructions: String,
        apiKey: String
    ) async throws -> CodingPromptRewriteResult {
        let request: URLRequest
        do {
            request = try Self.makeRequest(
                selectedText: selectedText,
                instructions: instructions,
                apiKey: apiKey
            )
        } catch let error as CodingPromptRewriteError {
            throw error
        } catch {
            throw CodingPromptRewriteError.apiFailure
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(request)
        } catch {
            let duration = startedAt.duration(to: clock.now)
            Self.logger.error(
                "OpenAI request failed category=network duration_ms=\(Self.milliseconds(duration), privacy: .public)"
            )
            throw CodingPromptRewriteError.networkFailure
        }

        let duration = startedAt.duration(to: clock.now)
        do {
            let parsed = try Self.parseResult(data: data, response: response)
            Self.logger.notice(
                "OpenAI rewrite completed duration_ms=\(Self.milliseconds(duration), privacy: .public)"
            )
            return CodingPromptRewriteResult(
                text: parsed.text,
                generationDuration: duration,
                usage: parsed.usage
            )
        } catch let error as CodingPromptRewriteError {
            Self.logger.error(
                "OpenAI request failed category=api duration_ms=\(Self.milliseconds(duration), privacy: .public)"
            )
            throw error
        } catch {
            Self.logger.error(
                "OpenAI request failed category=api duration_ms=\(Self.milliseconds(duration), privacy: .public)"
            )
            throw CodingPromptRewriteError.apiFailure
        }
    }

    /// The task rewrite request. Task prompt generation reuses the same shape
    /// with its own instructions, input, output limit and timeout.
    static func makeRequest(
        selectedText: String,
        instructions: String,
        apiKey: String,
        maxOutputTokens: Int = OpenAIResponsesClient.maxOutputTokens,
        timeoutInterval: TimeInterval = OpenAISessionFactory.rewriteTimeout
    ) throws -> URLRequest {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw CodingPromptRewriteError.apiKeyMissing
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(normalizedKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                selectedText: selectedText,
                instructions: instructions,
                maxOutputTokens: maxOutputTokens
            )
        )
        return request
    }

    static func parseResponse(data: Data, response: URLResponse) throws -> String {
        try parseResult(data: data, response: response).text
    }

    static func parseResult(
        data: Data,
        response: URLResponse
    ) throws -> (text: String, usage: OpenAIResponseUsage?) {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw CodingPromptRewriteError.apiFailure
        }

        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw CodingPromptRewriteError.apiFailure
        }

        guard envelope.status == "completed" else {
            throw CodingPromptRewriteError.apiFailure
        }

        let messageContent = envelope.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }

        guard !messageContent.contains(where: { $0.type == "refusal" }) else {
            throw CodingPromptRewriteError.refusal
        }

        let output = messageContent
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined(separator: "\n")

        guard let accepted = RewritePromptPolicy.acceptedOutput(output) else {
            throw CodingPromptRewriteError.emptyResponse
        }
        return (accepted, envelope.usage?.value)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }

    private struct RequestBody: Encodable {
        let model = OpenAIResponsesClient.model
        let store = false
        let instructions: String
        let input: [InputMessage]
        let reasoning = Reasoning()
        let text = TextConfiguration()
        let tools: [Tool] = []
        let maxOutputTokens: Int
        let serviceTier = "default"
        let truncation = "disabled"

        init(selectedText: String, instructions: String, maxOutputTokens: Int) {
            self.instructions = instructions
            input = [InputMessage(selectedText: selectedText)]
            self.maxOutputTokens = maxOutputTokens
        }

        enum CodingKeys: String, CodingKey {
            case model
            case store
            case instructions
            case input
            case reasoning
            case text
            case tools
            case maxOutputTokens = "max_output_tokens"
            case serviceTier = "service_tier"
            case truncation
        }

        struct InputMessage: Encodable {
            let role = "user"
            let content: [InputContent]

            init(selectedText: String) {
                content = [InputContent(text: selectedText)]
            }
        }

        struct InputContent: Encodable {
            let type = "input_text"
            let text: String
        }

        struct Reasoning: Encodable {
            let effort = "none"
            let context = "current_turn"
        }

        struct TextConfiguration: Encodable {
            let format = Format()
            let verbosity = "low"

            struct Format: Encodable {
                let type = "text"
            }
        }

        struct Tool: Encodable {}
    }

    private struct ResponseEnvelope: Decodable {
        let status: String
        let output: [OutputItem]
        let usage: Usage?

        struct OutputItem: Decodable {
            let type: String
            let content: [Content]?
        }

        struct Content: Decodable {
            let type: String
            let text: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            let totalTokens: Int
            let inputTokensDetails: InputTokensDetails?
            let outputTokensDetails: OutputTokensDetails?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case totalTokens = "total_tokens"
                case inputTokensDetails = "input_tokens_details"
                case outputTokensDetails = "output_tokens_details"
            }

            struct InputTokensDetails: Decodable {
                let cachedTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case cachedTokens = "cached_tokens"
                }
            }

            struct OutputTokensDetails: Decodable {
                let reasoningTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case reasoningTokens = "reasoning_tokens"
                }
            }

            var value: OpenAIResponseUsage {
                OpenAIResponseUsage(
                    inputTokens: inputTokens,
                    cachedInputTokens: inputTokensDetails?.cachedTokens,
                    outputTokens: outputTokens,
                    reasoningTokens: outputTokensDetails?.reasoningTokens,
                    totalTokens: totalTokens
                )
            }
        }
    }
}

/// The task rewrite entry point. It reads the global provider once at the
/// start of each call, loads only that provider's key and sends only to that
/// provider. There is no fallback to the other provider.
struct CodingPromptRewriter: Sendable {
    private let currentProvider: @Sendable () -> RewriteProvider
    private let openAIKeyStore: any APIKeyStoring
    private let claudeKeyStore: any APIKeyStoring
    private let openAIClient: OpenAIResponsesClient
    private let claudeClient: AnthropicMessagesClient

    init(
        providerSetting: RewriteProviderSetting,
        openAIKeyStore: any APIKeyStoring,
        claudeKeyStore: any APIKeyStoring,
        openAIClient: OpenAIResponsesClient = OpenAIResponsesClient(),
        claudeClient: AnthropicMessagesClient = AnthropicMessagesClient()
    ) {
        currentProvider = { providerSetting.current }
        self.openAIKeyStore = openAIKeyStore
        self.claudeKeyStore = claudeKeyStore
        self.openAIClient = openAIClient
        self.claudeClient = claudeClient
    }

    /// An OpenAI-only rewriter with one key store, independent of the global
    /// provider setting.
    init(
        apiKeyStore: any APIKeyStoring,
        client: OpenAIResponsesClient = OpenAIResponsesClient()
    ) {
        currentProvider = { .openai }
        openAIKeyStore = apiKeyStore
        claudeKeyStore = apiKeyStore
        openAIClient = client
        claudeClient = AnthropicMessagesClient { _ in
            throw CodingPromptRewriteError.networkFailure
        }
    }

    func provider() -> RewriteProvider {
        currentProvider()
    }

    func rewrite(
        _ selectedText: String,
        taskPrompt: String
    ) async throws -> CodingPromptRewriteResult {
        try await rewrite(
            selectedText,
            taskPrompt: taskPrompt,
            provider: currentProvider()
        )
    }

    func rewrite(
        _ selectedText: String,
        taskPrompt: String,
        provider: RewriteProvider
    ) async throws -> CodingPromptRewriteResult {
        let apiKeyStore: any APIKeyStoring = switch provider {
        case .claude:
            claudeKeyStore
        case .openai:
            openAIKeyStore
        }

        let apiKey: String
        do {
            guard let storedKey = try await apiKeyStore.loadKey(),
                  !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodingPromptRewriteError.apiKeyMissing
            }
            apiKey = storedKey
        } catch let error as CodingPromptRewriteError {
            throw error
        } catch {
            throw CodingPromptRewriteError.keychainUnavailable
        }

        switch provider {
        case .claude:
            return try await claudeClient.rewrite(
                selectedText: selectedText,
                instructions: taskPrompt,
                apiKey: apiKey
            )
        case .openai:
            return try await openAIClient.rewrite(
                selectedText: selectedText,
                instructions: taskPrompt,
                apiKey: apiKey
            )
        }
    }
}
