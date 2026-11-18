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

enum OpenAISessionFactory {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
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

    private static let logger = Logger(
        subsystem: "com.local.ReCraftClipboardSpike",
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

    static func makeRequest(
        selectedText: String,
        instructions: String,
        apiKey: String
    ) throws -> URLRequest {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw CodingPromptRewriteError.apiKeyMissing
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
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
                instructions: instructions
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
        let maxOutputTokens = 2_400
        let serviceTier = "default"
        let truncation = "disabled"

        init(selectedText: String, instructions: String) {
            self.instructions = instructions
            input = [InputMessage(selectedText: selectedText)]
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

struct CodingPromptRewriter: Sendable {
    private let apiKeyStore: any APIKeyStoring
    private let client: OpenAIResponsesClient

    init(
        apiKeyStore: any APIKeyStoring,
        client: OpenAIResponsesClient = OpenAIResponsesClient()
    ) {
        self.apiKeyStore = apiKeyStore
        self.client = client
    }

    func rewrite(
        _ selectedText: String,
        taskPrompt: String
    ) async throws -> CodingPromptRewriteResult {
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

        return try await client.rewrite(
            selectedText: selectedText,
            instructions: taskPrompt,
            apiKey: apiKey
        )
    }
}
