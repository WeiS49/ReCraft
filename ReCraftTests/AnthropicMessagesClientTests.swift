import Foundation
import XCTest
@testable import ReCraft

final class AnthropicMessagesClientTests: XCTestCase {
    func testBuildsExactMessagesRequest() throws {
        let prompt = "  \tRewrite 这段文字 🙂.\r\nKeep literal {taskPrompt}.\n  "
        let source = "\n  SOURCE 中文 🙂 cafe\u{0301}\r\nline two\t "
        let request = try AnthropicMessagesClient.makeRequest(
            selectedText: source,
            instructions: prompt,
            apiKey: "synthetic-claude-key"
        )

        XCTAssertEqual(
            request.url,
            URL(string: "https://api.anthropic.com/v1/messages")
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-api-key"),
            "synthetic-claude-key"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-version"),
            "2026-10-21"
        )
        XCTAssertEqual(
            Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
            ["content-type", "x-api-key", "anthropic-version"]
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(body.keys),
            ["model", "max_tokens", "system", "thinking", "messages"]
        )
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)

        let system = try XCTUnwrap(body["system"] as? String)
        XCTAssertEqual(Data(system.utf8), Data(prompt.utf8))

        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(Set(thinking.keys), ["type"])
        XCTAssertEqual(thinking["type"] as? String, "disabled")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(Set(message.keys), ["role", "content"])
        XCTAssertEqual(message["role"] as? String, "user")
        let content = try XCTUnwrap(message["content"] as? String)
        XCTAssertEqual(Data(content.utf8), Data(source.utf8))

        let bodyString = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
        XCTAssertFalse(bodyString.contains("synthetic-claude-key"))
    }

    func testConcatenatesTextBlocksAndIgnoresOtherBlocks() async throws {
        let recorder = AnthropicRequestRecorder()
        let client = AnthropicMessagesClient(
            load: try respond(
                recording: recorder,
                json: [
                    "type": "message",
                    "role": "assistant",
                    "stop_reason": "end_turn",
                    "content": [
                        ["type": "text", "text": "  First 第一"],
                        ["type": "thinking", "thinking": "IGNORED-THINKING"],
                        ["type": "tool_use", "id": "IGNORED-ID", "name": "IGNORED-TOOL"],
                        ["type": "text", "text": " 🙂\nsecond  "],
                    ],
                ]
            )
        )

        let result = try await client.rewrite(
            selectedText: "selected",
            instructions: "task prompt",
            apiKey: "synthetic-claude-key"
        )

        XCTAssertEqual(
            Data(result.text.utf8),
            Data("  First 第一 🙂\nsecond  ".utf8)
        )
        XCTAssertNil(result.usage)
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testRefusalStopReasonThrowsRefusal() async throws {
        let client = AnthropicMessagesClient(
            load: try respond(json: [
                "stop_reason": "refusal",
                "content": [["type": "text", "text": "partial text"]],
            ])
        )

        await assertRewriteThrows(client, .refusal)
    }

    func testMaxTokensStopReasonThrowsAPIFailure() async throws {
        let client = AnthropicMessagesClient(
            load: try respond(json: [
                "stop_reason": "max_tokens",
                "content": [["type": "text", "text": "truncated text"]],
            ])
        )
        await assertRewriteThrows(client, .apiFailure)

        for stopReason in ["stop_sequence", "tool_use", "pause_turn", "unknown"] {
            let other = AnthropicMessagesClient(
                load: try respond(json: [
                    "stop_reason": stopReason,
                    "content": [["type": "text", "text": "text"]],
                ])
            )
            await assertRewriteThrows(other, .apiFailure)
        }
    }

    func testWhitespaceOnlyTextThrowsEmptyResponse() async throws {
        let whitespace = AnthropicMessagesClient(
            load: try respond(json: [
                "stop_reason": "end_turn",
                "content": [
                    ["type": "text", "text": "  \n"],
                    ["type": "text", "text": "\t "],
                ],
            ])
        )
        await assertRewriteThrows(whitespace, .emptyResponse)

        let noText = AnthropicMessagesClient(
            load: try respond(json: [
                "stop_reason": "end_turn",
                "content": [[String: String]](),
            ])
        )
        await assertRewriteThrows(noText, .emptyResponse)
    }

    func testNonSuccessStatusThrowsAPIFailure() async throws {
        for statusCode in [400, 401, 429, 500, 529] {
            let client = AnthropicMessagesClient(
                load: try respond(
                    statusCode: statusCode,
                    json: [
                        "stop_reason": "end_turn",
                        "content": [["type": "text", "text": "text"]],
                    ]
                )
            )
            await assertRewriteThrows(client, .apiFailure)
        }

        let unparseable = AnthropicMessagesClient { _ in
            (Data("not json".utf8), Self.httpResponse(statusCode: 200))
        }
        await assertRewriteThrows(unparseable, .apiFailure)
    }

    func testTransportErrorThrowsNetworkFailure() async throws {
        let recorder = AnthropicRequestRecorder()
        let client = AnthropicMessagesClient { request in
            await recorder.record(request)
            throw URLError(.notConnectedToInternet)
        }

        await assertRewriteThrows(client, .networkFailure)
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testEmptyKeyStopsBeforeRequest() async throws {
        let recorder = AnthropicRequestRecorder()
        let client = AnthropicMessagesClient { request in
            await recorder.record(request)
            throw URLError(.unknown)
        }

        do {
            _ = try await client.rewrite(
                selectedText: "selected",
                instructions: "task prompt",
                apiKey: " \n "
            )
            XCTFail("Expected an empty key to stop the request")
        } catch {
            XCTAssertEqual(error as? CodingPromptRewriteError, .apiKeyMissing)
        }
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    private func assertRewriteThrows(
        _ client: AnthropicMessagesClient,
        _ expected: CodingPromptRewriteError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.rewrite(
                selectedText: "selected",
                instructions: "task prompt",
                apiKey: "synthetic-claude-key"
            )
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? CodingPromptRewriteError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func respond(
        recording recorder: AnthropicRequestRecorder? = nil,
        statusCode: Int = 200,
        json: [String: Any]
    ) throws -> AnthropicMessagesClient.DataLoader {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = Self.httpResponse(statusCode: statusCode)
        return { request in
            await recorder?.record(request)
            return (data, response)
        }
    }

    private static func httpResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: AnthropicMessagesClient.endpoint,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

private actor AnthropicRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}
