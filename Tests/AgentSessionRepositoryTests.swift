import Foundation
import XCTest
@testable import PaperRssCore

final class AgentSessionRepositoryTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var sessions: AgentSessionRepository!
    private var actions: AgentActionRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        sessions = AgentSessionRepository(database: database)
        actions = AgentActionRepository(database: database)
    }

    override func tearDownWithError() throws {
        database = nil
        sessions = nil
        actions = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSessionRoundTripDerivesTitleAndPersistsToolMessages() throws {
        let session = try sessions.createSession(scopeJSON: #"{"kind":"unread"}"#)
        XCTAssertTrue(session.title.isEmpty)

        _ = try sessions.appendMessage(
            sessionID: session.id,
            role: .user,
            content: "总结一下今天的未读文章，按值得读排序。"
        )
        let call = AgentToolCall(id: "call_1", name: "list_articles", arguments: #"{"limit":5}"#)
        _ = try sessions.appendMessage(sessionID: session.id, role: .assistant, content: "", toolCalls: [call])
        _ = try sessions.appendMessage(sessionID: session.id, role: .tool, content: #"[{"id":"a1"}]"#, toolCallID: "call_1")

        let messages = try sessions.fetchMessages(sessionID: session.id)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1].toolCalls.first?.name, "list_articles")
        XCTAssertEqual(messages[2].toolCallID, "call_1")

        let listed = try sessions.fetchSessions()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].title, "总结一下今天的未读文章，按值得读排序。")
    }

    func testDeletingSessionCascadesMessages() throws {
        let session = try sessions.createSession()
        _ = try sessions.appendMessage(sessionID: session.id, role: .user, content: "hello")
        try sessions.deleteSession(id: session.id)
        XCTAssertTrue(try sessions.fetchMessages(sessionID: session.id).isEmpty)
        XCTAssertNil(try sessions.fetchSession(id: session.id))
    }

    func testActionLogCanBeUndone() throws {
        let session = try sessions.createSession()
        let action = try actions.record(
            sessionID: session.id,
            messageID: nil,
            tool: "propose_mark_read",
            argumentsJSON: #"{"ids":["a1"]}"#,
            affectedIDs: ["a1"],
            priorStatesJSON: #"[{"id":"a1","isRead":false}]"#
        )
        XCTAssertEqual(action.affectedIDs, ["a1"])
        XCTAssertEqual(try actions.fetchRecent().count, 1)

        try actions.markUndone(id: action.id)
        XCTAssertEqual(try actions.fetchAction(id: action.id)?.status, .undone)
    }

    func testAppendingToMissingSessionThrows() throws {
        XCTAssertThrowsError(
            try sessions.appendMessage(sessionID: "missing", role: .user, content: "hello")
        ) { error in
            XCTAssertEqual(error as? AgentSessionRepositoryError, .sessionNotFound)
        }
    }
}
