import Foundation
import XCTest
@testable import PaperRssCore

private final class AgentChatMockPort: AIModelPort, @unchecked Sendable {
    var dataResponse: AIModelHTTPResponse
    var eventLines: [String]
    private let lock = NSLock()
    private var storedBody: [String: Any] = [:]
    private var storedStreamFlag = false

    init(dataResponse: AIModelHTTPResponse, eventLines: [String] = []) {
        self.dataResponse = dataResponse
        self.eventLines = eventLines
    }

    var lastBody: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return storedBody
    }

    var lastStreamFlag: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedStreamFlag
    }

    private func capture(_ request: URLRequest) {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        lock.lock()
        storedBody = object
        storedStreamFlag = object["stream"] as? Bool ?? false
        lock.unlock()
    }

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        capture(request)
        return dataResponse
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        capture(request)
        let lines = eventLines
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return AIModelEventResponse(statusCode: 200, lines: stream)
    }
}

private final class AgentDeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ value: String) {
        lock.lock(); storage += value; lock.unlock()
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class AgentChatTests: XCTestCase {
    private let configuration = LLMConfiguration(
        baseURL: "https://agent.example.test/v1",
        model: "test-model",
        temperature: 0.2,
        targetLanguage: "简体中文",
        allowInsecureLocalEndpoint: false
    )

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private var tool: AgentToolDefinition {
        AgentToolDefinition(
            name: "list_articles",
            description: "List unread articles",
            parameters: [
                AgentToolParameter(
                    name: "feedIDs",
                    kind: .stringArray,
                    description: "Feed ids",
                    isRequired: true,
                    itemType: "string"
                ),
                AgentToolParameter(name: "limit", kind: .integer, description: "Maximum items")
            ]
        )
    }

    func testChatRequestPreservesToolCallsAndToolResults() throws {
        let service = LLMService(port: AgentChatMockPort(dataResponse: AIModelHTTPResponse(statusCode: 200, data: Data("{}".utf8))))
        let messages: [AgentChatMessage] = [
            .system("system"),
            .user("question"),
            .assistant("", toolCalls: [AgentToolCall(id: "call_1", name: "list_articles", arguments: #"{"limit":5}"#)]),
            .tool(callID: "call_1", content: #"[{"id":"a1"}]"#)
        ]
        let request = try service.makeChatRequest(
            messages: messages,
            tools: [tool],
            configuration: configuration,
            apiKey: "sk-test",
            stream: false
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        let encoded = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(encoded.count, 4)
        XCTAssertEqual(encoded[2]["role"] as? String, "assistant")
        let calls = try XCTUnwrap(encoded[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual((calls[0]["function"] as? [String: Any])?["name"] as? String, "list_articles")
        XCTAssertEqual(encoded[3]["tool_call_id"] as? String, "call_1")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["feedIDs"])
        let headers = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(headers, "Bearer sk-test")
    }

    func testNonStreamingChatParsesToolCalls() async throws {
        let response = try data([
            "choices": [[
                "message": [
                    "content": "reading list",
                    "tool_calls": [[
                        "id": "call_2",
                        "type": "function",
                        "function": ["name": "get_article", "arguments": #"{"id":"a1"}"#]
                    ]]
                ],
                "finish_reason": "tool_calls"
            ]]
        ])
        let port = AgentChatMockPort(dataResponse: AIModelHTTPResponse(statusCode: 200, data: response))
        let result = try await LLMService(port: port).chat(
            messages: [.user("hi")],
            tools: [tool],
            configuration: configuration,
            apiKey: ""
        )
        XCTAssertEqual(result.content, "reading list")
        XCTAssertEqual(result.toolCalls.map(\.name), ["get_article"])
        XCTAssertEqual(result.toolCalls.first?.arguments, #"{"id":"a1"}"#)
        XCTAssertFalse(port.lastStreamFlag)
    }

    func testStreamingChatAccumulatesSplitToolArguments() async throws {
        let port = AgentChatMockPort(
            dataResponse: AIModelHTTPResponse(statusCode: 200, data: Data("{}".utf8)),
            eventLines: [
                #"data: {"choices":[{"delta":{"content":"Hello "}}]}"#,
                #"data: {"choices":[{"delta":{"content":"world"}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"get_article","arguments":"{\"id\":"}}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a1\"}"}}]},"finish_reason":"tool_calls"}]}"#,
                "data: [DONE]"
            ]
        )
        let collector = AgentDeltaCollector()
        let result = try await LLMService(port: port).chat(
            messages: [.user("hi")],
            tools: [tool],
            configuration: configuration,
            apiKey: ""
        ) { delta in
            collector.append(delta)
        }
        XCTAssertEqual(result.content, "Hello world")
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments, #"{"id":"a1"}"#)
        XCTAssertEqual(collector.value, "Hello world")
        XCTAssertTrue(port.lastStreamFlag)
    }

    func testStreamingJSONFallbackUsesNonStreamingResponse() async throws {
        let fallback = try data([
            "choices": [["message": ["content": "fallback text"], "finish_reason": "stop"]]
        ])
        let port = AgentChatMockPort(
            dataResponse: AIModelHTTPResponse(statusCode: 200, data: fallback),
            eventLines: [#"{"choices":[{"delta":{"content":"ignored"}}]}"#]
        )
        let result = try await LLMService(port: port).chat(
            messages: [.user("hi")],
            configuration: configuration,
            apiKey: ""
        ) { _ in }
        XCTAssertEqual(result.content, "fallback text")
        XCTAssertTrue(result.toolCalls.isEmpty)
    }
}
