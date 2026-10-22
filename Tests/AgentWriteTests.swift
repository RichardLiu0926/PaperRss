import Foundation
import XCTest
@testable import PaperRssCore

@MainActor
private final class RecordingWriter: AgentStateWriting {
    var readCalls: [([String], Bool)] = []
    var starCalls: [([String], Bool)] = []

    func applyReadState(entryIDs: [String], read: Bool) {
        readCalls.append((entryIDs, read))
    }

    func applyStarredState(entryIDs: [String], starred: Bool) {
        starCalls.append((entryIDs, starred))
    }
}

private final class ProposalMockPort: AIModelPort, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        AIModelHTTPResponse(statusCode: 200, data: Data("{}".utf8))
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"propose_mark_read","arguments":"{\"ids\":[\"i1\",\"i2\"],\"value\":true,\"reason\":\"low relevance\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]"
        ]
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return AIModelEventResponse(statusCode: 200, lines: stream)
    }
}

final class AgentWriteTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var actions: AgentActionRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        actions = AgentActionRepository(database: database)
        try insertFixture()
    }

    override func tearDownWithError() throws {
        database = nil
        actions = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func insertFixture() throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(sql: "INSERT INTO accounts (id,type,display_name,is_enabled,created_at,updated_at) VALUES ('local-default','local','Local',1,?,?)", arguments: [now, now])
            try db.execute(sql: "INSERT INTO feeds (id,account_id,title,feed_url,is_deleted,updated_at,sort_order) VALUES ('f1','local-default','Feed','https://f1.test/rss',0,?,0)", arguments: [now])
            for id in ["i1", "i2"] {
                try db.execute(sql: "INSERT INTO items (id,account_id,external_id,feed_id,created_at,updated_at) VALUES (?,'local-default',?,'f1',?,?)", arguments: [id, id, now, now])
                try db.execute(sql: "INSERT INTO articles (item_id,title,url,published_at,summary,content_updated_at) VALUES (?,'Title \(id)','https://\(id).test',?,'Summary',?)", arguments: [id, now, now])
                try db.execute(sql: "INSERT INTO article_states (item_id,is_read,is_starred,date_arrived,updated_at) VALUES (?,0,0,?,?)", arguments: [id, now, now])
            }
        }
    }

    @MainActor
    func testProposalExecutionAndUndo() throws {
        let writer = RecordingWriter()
        let executor = AgentWriteExecutor(writer: writer, actions: actions)
        let planner = AgentWritePlanner(database: database)
        let proposal = try planner.propose(
            kind: .markRead,
            ids: ["i1", "i2"],
            desiredValue: true,
            reason: "test",
            accountID: "local-default"
        )
        XCTAssertEqual(proposal.count, 2)
        XCTAssertEqual(proposal.items.map(\.isRead), [false, false])

        let action = try executor.execute(proposal: proposal, sessionID: nil, messageID: nil)
        XCTAssertEqual(action.affectedIDs.count, 2)
        XCTAssertEqual(writer.readCalls.count, 1)
        XCTAssertEqual(writer.readCalls.first?.0.count, 2)
        XCTAssertEqual(try actions.fetchRecent().count, 1)

        try executor.undo(action: action)
        XCTAssertEqual(writer.readCalls.count, 3)
        XCTAssertEqual(try actions.fetchAction(id: action.id)?.status, .undone)
    }

    func testProposalSkipsAlreadyAppliedItems() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE article_states SET is_read = 1 WHERE item_id = 'i1'")
        }
        let planner = AgentWritePlanner(database: database)
        let proposal = try planner.propose(
            kind: .markRead,
            ids: ["i1", "i2"],
            desiredValue: true,
            reason: "",
            accountID: "local-default"
        )
        XCTAssertEqual(proposal.items.map(\.id), ["i2"])

        XCTAssertThrowsError(try planner.propose(
            kind: .markRead,
            ids: ["i1"],
            desiredValue: true,
            reason: "",
            accountID: "local-default"
        )) { error in
            XCTAssertEqual(error as? AgentWriteError, .nothingToDo)
        }
    }

    @MainActor
    func testWritePermissionGatesProposalTools() async throws {
        let off = AgentToolRegistry(database: database, writePermission: .off)
        let context = AgentToolContext(accountID: "local-default", scope: AgentScope(), sessionID: nil)
        do {
            _ = try await off.execute(
                AgentToolCall(id: "c", name: "propose_mark_read", arguments: #"{"ids":["i1"]}"#),
                context: context
            )
            XCTFail("write should be blocked")
        } catch let error as AgentWriteError {
            XCTAssertEqual(error, .writerUnavailable)
        }

        let readOnly = AgentToolRegistry(database: database, writePermission: .markRead)
        let outcome = try await readOnly.execute(
            AgentToolCall(id: "c", name: "propose_mark_read", arguments: #"{"ids":["i1"]}"#),
            context: context
        )
        guard case .proposal = outcome else { return XCTFail("expected proposal") }
    }

    @MainActor
    func testControllerStopsAtProposalAndConfirms() async throws {
        let writer = RecordingWriter()
        let executor = AgentWriteExecutor(writer: writer, actions: actions)
        let registry = AgentToolRegistry(database: database, writePermission: .markRead)
        let controller = AgentSessionController(
            repository: AgentSessionRepository(database: database),
            llm: LLMService(port: ProposalMockPort()),
            toolRegistry: registry,
            writeExecutor: executor
        )
        _ = try controller.startNewSession()
        controller.send(
            "mark low relevance as read",
            configuration: LLMConfiguration(
                baseURL: "https://agent.test/v1",
                model: "test",
                temperature: 0.2,
                targetLanguage: "简体中文",
                allowInsecureLocalEndpoint: false
            ),
            apiKey: "",
            tools: AgentToolRegistry.writeDefinitions(allowsStar: false),
            toolContext: AgentToolContext(accountID: "local-default", scope: AgentScope(), sessionID: controller.session?.id)
        )
        for _ in 0..<100 where controller.isStreaming {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(controller.isStreaming)
        let pending = try XCTUnwrap(controller.pendingProposal)
        XCTAssertEqual(pending.count, 2)

        try controller.confirmPendingProposal()
        XCTAssertNil(controller.pendingProposal)
        XCTAssertNotNil(controller.lastExecutedAction)
        XCTAssertEqual(writer.readCalls.count, 1)

        try controller.undoLastAction()
        XCTAssertNil(controller.lastExecutedAction)
        XCTAssertEqual(writer.readCalls.count, 3)
    }
}
