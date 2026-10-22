import Foundation
import XCTest
@testable import PaperRssCore

private final class ControllerMockPort: AIModelPort, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: 200, data: Data("{}".utf8))
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"今天"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"值得读的有 3 篇。"}}]}"#,
            "data: [DONE]"
        ]
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return AIModelEventResponse(statusCode: 200, lines: stream)
    }
}

private actor ToolLoopPort: AIModelPort {
    private var calls = 0

    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: 200, data: Data("{}".utf8))
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        let index = calls
        calls += 1
        let lines: [String]
        if index == 0 {
            lines = [
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"list_articles","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
                "data: [DONE]"
            ]
        } else {
            lines = [
                #"data: {"choices":[{"delta":{"content":"有 2 篇未读。"}}]}"#,
                "data: [DONE]"
            ]
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return AIModelEventResponse(statusCode: 200, lines: stream)
    }
}

@MainActor
final class AgentSessionControllerTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var repository: AgentSessionRepository!
    private let configuration = LLMConfiguration(
        baseURL: "https://agent.test/v1",
        model: "test",
        temperature: 0.2,
        targetLanguage: "简体中文",
        allowInsecureLocalEndpoint: false
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        repository = AgentSessionRepository(database: database)
    }

    override func tearDownWithError() throws {
        database = nil
        repository = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func waitForIdle(_ controller: AgentSessionController) async throws {
        for _ in 0..<100 {
            if !controller.isStreaming { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("controller did not become idle")
    }

    func testSendStreamsPersistsAndDerivesTitle() async throws {
        let controller = AgentSessionController(
            repository: repository,
            llm: LLMService(port: ControllerMockPort())
        )
        _ = try controller.startNewSession()
        controller.send("今天有什么值得读的？", configuration: configuration, apiKey: "")
        try await waitForIdle(controller)

        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.messages.count, 2)
        XCTAssertEqual(controller.messages[1].role, .assistant)
        XCTAssertEqual(controller.messages[1].content, "今天值得读的有 3 篇。")
        XCTAssertEqual(controller.session?.title, "今天有什么值得读的？")

        let stored = try repository.fetchMessages(sessionID: controller.session!.id)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored[0].content, "今天有什么值得读的？")
    }

    func testToolLoopPersistsAssistantToolAndFinalMessages() async throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(sql: "INSERT INTO accounts (id,type,display_name,is_enabled,created_at,updated_at) VALUES ('local-default','local','本地',1,?,?)", arguments: [now, now])
            try db.execute(sql: "INSERT INTO feeds (id,account_id,title,feed_url,is_deleted,updated_at,sort_order) VALUES ('f1','local-default','测试源','https://f1.test/rss',0,?,0)", arguments: [now])
            try db.execute(sql: "INSERT INTO items (id,account_id,external_id,feed_id,created_at,updated_at) VALUES ('i1','local-default','e1','f1',?,?),('i2','local-default','e2','f1',?,?)", arguments: [now, now, now, now])
            try db.execute(sql: "INSERT INTO articles (item_id,title,url,published_at,summary,content_updated_at) VALUES ('i1','A1','https://a1.test',?, 's1', ?),('i2','A2','https://a2.test',?, 's2', ?)", arguments: [now, now, now, now])
            try db.execute(sql: "INSERT INTO article_states (item_id,is_read,is_starred,date_arrived,updated_at) VALUES ('i1',0,0,?,?),('i2',0,1,?,?)", arguments: [now, now, now, now])
        }

        let controller = AgentSessionController(
            repository: repository,
            llm: LLMService(port: ToolLoopPort()),
            toolRegistry: AgentToolRegistry(database: database)
        )
        _ = try controller.startNewSession()
        controller.send(
            "列一下未读",
            configuration: configuration,
            apiKey: "",
            toolContext: AgentToolContext(
                accountID: "local-default",
                scope: AgentScope(),
                sessionID: controller.session?.id
            )
        )
        try await waitForIdle(controller)

        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.messages.count, 4)
        XCTAssertEqual(controller.messages[1].toolCalls.first?.name, "list_articles")
        XCTAssertEqual(controller.messages[2].role, .tool)
        XCTAssertTrue(controller.messages[2].content.contains("\"articles\""))
        XCTAssertEqual(controller.messages[3].content, "有 2 篇未读。")
        XCTAssertEqual(try repository.fetchMessages(sessionID: controller.session!.id).count, 4)
    }

    func testLoadSessionRestoresMessages() async throws {
        let controller = AgentSessionController(
            repository: repository,
            llm: LLMService(port: ControllerMockPort())
        )
        let session = try controller.startNewSession()
        controller.send("第一轮", configuration: configuration, apiKey: "")
        try await waitForIdle(controller)

        let reloaded = AgentSessionController(
            repository: repository,
            llm: LLMService(port: ControllerMockPort())
        )
        try reloaded.loadSession(id: session.id)
        XCTAssertEqual(reloaded.messages.count, 2)
        XCTAssertEqual(reloaded.session?.id, session.id)
    }
}
