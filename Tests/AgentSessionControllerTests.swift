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

@MainActor
final class AgentSessionControllerTests: XCTestCase {
    private var directory: URL!
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
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        repository = AgentSessionRepository(database: database)
    }

    override func tearDownWithError() throws {
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
