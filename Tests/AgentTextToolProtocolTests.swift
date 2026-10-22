import Foundation
import XCTest
@testable import PaperRssCore

private actor TextProtocolPort: AIModelPort {
    private var calls = 0

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: 200, data: Data("{}".utf8))
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        let index = calls
        calls += 1
        let content: String
        if index == 0 {
            content = """
            ```json
            {"tool":"get_unread_stats","arguments":{}}
            ```
            """
        } else {
            content = "当前范围没有未读文章。"
        }
        let line = "data: " + String(data: try! JSONSerialization.data(withJSONObject: [
            "choices": [["delta": ["content": content]]]
        ]), encoding: .utf8)! + "\n\n"
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(line.trimmingCharacters(in: .newlines))
            continuation.yield("data: [DONE]")
            continuation.finish()
        }
        return AIModelEventResponse(statusCode: 200, lines: stream)
    }
}

final class AgentTextToolProtocolTests: XCTestCase {
    func testParserAcceptsFencedDirectiveAndRejectsUnknownTools() {
        let call = AgentTextToolCallParser.parse(
            """
            preface
            ```json
            {"tool":"get_unread_stats","arguments":{"limit":5}}
            ```
            """,
            allowedToolNames: ["get_unread_stats"]
        )
        XCTAssertEqual(call?.name, "get_unread_stats")
        XCTAssertEqual(call?.arguments, #"{"limit":5}"#)

        XCTAssertNil(AgentTextToolCallParser.parse(
            #"{"tool":"delete_everything","arguments":{}}"#,
            allowedToolNames: ["get_unread_stats"]
        ))
    }

    @MainActor
    func testControllerRunsTextJSONToolLoop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let controller = AgentSessionController(
            repository: AgentSessionRepository(database: database),
            llm: LLMService(port: TextProtocolPort()),
            toolRegistry: AgentToolRegistry(database: database)
        )
        _ = try controller.startNewSession()
        controller.send(
            "有多少未读？",
            configuration: LLMConfiguration(
                baseURL: "https://agent.test/v1",
                model: "test",
                temperature: 0.2,
                targetLanguage: "简体中文",
                allowInsecureLocalEndpoint: false
            ),
            apiKey: "",
            tools: AgentToolRegistry.readOnlyDefinitions,
            toolContext: AgentToolContext(accountID: "local-default", scope: AgentScope(), sessionID: controller.session?.id),
            toolProtocol: .textJSON
        )
        for _ in 0..<100 where controller.isStreaming {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(controller.isStreaming)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.messages.count, 4)
        XCTAssertEqual(controller.messages[1].toolCalls.first?.name, "get_unread_stats")
        XCTAssertEqual(controller.messages[2].role, .tool)
        XCTAssertTrue(controller.messages[2].content.contains("totalUnread"))
        XCTAssertEqual(controller.messages[3].content, "当前范围没有未读文章。")
    }
}
