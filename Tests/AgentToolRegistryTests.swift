import Foundation
import XCTest
@testable import PaperRssCore

final class AgentToolRegistryTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var registry: AgentToolRegistry!
    private var context: AgentToolContext!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        registry = AgentToolRegistry(database: database)
        context = AgentToolContext(accountID: "local-default", scope: AgentScope(), sessionID: "s1")
        try insertFixture()
    }

    override func tearDownWithError() throws {
        registry = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func insertFixture() throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(sql: "INSERT INTO accounts (id,type,display_name,is_enabled,created_at,updated_at) VALUES ('local-default','local','本地',1,?,?)", arguments: [now, now])
            try db.execute(sql: "INSERT INTO feeds (id,account_id,title,feed_url,is_deleted,updated_at,sort_order) VALUES ('f1','local-default','测试源','https://f1.test/rss',0,?,0)", arguments: [now])
            try db.execute(sql: "INSERT INTO items (id,account_id,external_id,feed_id,created_at,updated_at) VALUES ('i1','local-default','e1','f1',?,?),('i2','local-default','e2','f1',?,?)", arguments: [now, now, now, now])
            try db.execute(sql: "INSERT INTO articles (item_id,title,url,published_at,summary,content_updated_at) VALUES ('i1','A1','https://a1.test',?, 's1', ?),('i2','A2','https://a2.test',?, 's2', ?)", arguments: [now, now, now, now])
            try db.execute(sql: "INSERT INTO article_states (item_id,is_read,is_starred,date_arrived,updated_at) VALUES ('i1',0,0,?,?),('i2',0,1,?,?)", arguments: [now, now, now, now])
            try db.execute(sql: "INSERT INTO article_caches (item_id,text,fetched_at,is_sanitized) VALUES ('i1','full cached text',?,1)", arguments: [now])
        }
    }

    private func invoke(_ name: String, _ arguments: String) async throws -> AgentToolOutcome {
        try await registry.execute(AgentToolCall(id: "call", name: name, arguments: arguments), context: context)
    }

    private func object(_ outcome: AgentToolOutcome) throws -> [String: Any] {
        guard case .result(let json) = outcome,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected a JSON result")
            return [:]
        }
        return object
    }

    func testListArticlesUsesScopeAndPagination() async throws {
        let payload = try object(try await invoke("list_articles", #"{"limit":2}"#))
        XCTAssertEqual(payload["total"] as? Int, 2)
        XCTAssertEqual((payload["articles"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(payload["hasMore"] as? Bool, false)
    }

    func testGetArticleUsesCachedTextAndNeverMarksRead() async throws {
        let payload = try object(try await invoke("get_article", #"{"id":"i1","maxChars":1000}"#))
        XCTAssertEqual(payload["content"] as? String, "full cached text")
        XCTAssertEqual(payload["contentSource"] as? String, "cache")
        XCTAssertEqual(payload["isRead"] as? Bool, false)
    }

    func testSearchStatsAndFeeds() async throws {
        let search = try object(try await invoke("search_articles", #"{"query":"A1"}"#))
        XCTAssertEqual((search["articles"] as? [[String: Any]])?.count, 1)

        let stats = try object(try await invoke("get_unread_stats", "{}"))
        XCTAssertEqual(stats["totalUnread"] as? Int, 2)

        let feeds = try object(try await invoke("get_feeds", "{}"))
        XCTAssertEqual((feeds["feeds"] as? [[String: Any]])?.count, 1)
    }

    func testOpenArticleReturnsUIAction() async throws {
        let outcome = try await invoke("open_article", #"{"id":"i2"}"#)
        XCTAssertEqual(outcome, .action(AgentUIAction(kind: .openArticle, entryID: "i2")))
    }

    func testUnknownToolAndInvalidArgumentsThrow() async throws {
        do {
            _ = try await invoke("drop_database", "{}")
            XCTFail("Unknown tool should throw")
        } catch let error as AgentToolError {
            guard case .unknownTool = error else { return XCTFail("Unexpected error: \(error)") }
        }

        do {
            _ = try await invoke("get_article", #"{"id":"missing"}"#)
            XCTFail("Missing article should throw")
        } catch let error as AgentToolError {
            guard case .articleNotFound = error else { return XCTFail("Unexpected error: \(error)") }
        }

        do {
            _ = try await invoke("list_articles", #"{"limit":"many"}"#)
            XCTFail("Invalid arguments should throw")
        } catch let error as AgentToolError {
            guard case .invalidArguments = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
