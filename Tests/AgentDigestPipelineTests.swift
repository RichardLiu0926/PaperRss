import Foundation
import XCTest
@testable import PaperRssCore

private final class DigestMockPort: AIModelPort, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> AIModelHTTPResponse {
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let system = messages.first?["content"] as? String ?? ""
        let content: String
        if system.contains("You triage unread articles") {
            content = """
            [{"id":"i1","verdict":"worth_reading","reason":"相关"},
             {"id":"i2","verdict":"worth_reading","reason":"信息密度高"},
             {"id":"i3","verdict":"skippable","reason":"发布日志"},
             {"id":"i4","verdict":"later","reason":"长文"},
             {"id":"i5","verdict":"skippable","reason":"重复"}]
            """
        } else if system.contains("exactly three concise bullet points") {
            content = "- 一\n- 二\n- 三"
        } else {
            content = "OK"
        }
        let envelope: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        return AIModelHTTPResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: envelope))
    }

    func events(for request: URLRequest) async throws -> AIModelEventResponse {
        throw AgentDigestError.invalidResponse
    }
}

final class AgentDigestPipelineTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
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
        try insertFixture()
    }

    override func tearDownWithError() throws {
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func insertFixture() throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(sql: "INSERT INTO accounts (id,type,display_name,is_enabled,created_at,updated_at) VALUES ('local-default','local','本地',1,?,?)", arguments: [now, now])
            try db.execute(sql: "INSERT INTO feeds (id,account_id,title,feed_url,is_deleted,updated_at,sort_order) VALUES ('f1','local-default','测试源','https://f1.test/rss',0,?,0)", arguments: [now])
            for index in 1...5 {
                try db.execute(sql: "INSERT INTO items (id,account_id,external_id,feed_id,created_at,updated_at) VALUES ('i\(index)','local-default','e\(index)','f1',?,?)", arguments: [now, now])
                try db.execute(sql: "INSERT INTO articles (item_id,title,url,published_at,summary,content_updated_at) VALUES ('i\(index)','A\(index)','https://a\(index).test',?,'summary \(index)',?)", arguments: [now, now])
                try db.execute(sql: "INSERT INTO article_states (item_id,is_read,is_starred,date_arrived,updated_at) VALUES ('i\(index)',0,0,?,?)", arguments: [now, now])
                try db.execute(sql: "INSERT INTO article_caches (item_id,text,fetched_at,is_sanitized) VALUES ('i\(index)',?,?,1)", arguments: ["full text \(index)", now])
            }
        }
    }

    func testPipelineGroupsAndDeepReads() async throws {
        let pipeline = AgentDigestPipeline(database: database, llm: LLMService(port: DigestMockPort()))
        let digest = try await pipeline.run(
            scope: AgentScope(),
            accountID: "local-default",
            configuration: configuration,
            apiKey: "",
            maximumArticles: 5,
            deepReadLimit: 2,
            batchSize: 3
        )
        XCTAssertEqual(digest.unreadCount, 5)
        XCTAssertEqual(digest.analyzedCount, 5)
        XCTAssertEqual(digest.worthReadingCount, 2)
        XCTAssertEqual(digest.skippableCount, 2)
        XCTAssertEqual(digest.laterCount, 1)
        XCTAssertEqual(digest.deepReadCount, 2)
        XCTAssertEqual(digest.items.first?.verdict, .worthReading)
        XCTAssertEqual(digest.items.first(where: { $0.id == "i1" })?.bullets.count, 3)
        XCTAssertEqual(digest.items.reduce(0) { $0 + $1.bullets.count }, 6)
    }

    func testEmptyScopeThrows() async throws {
        let pipeline = AgentDigestPipeline(database: database, llm: LLMService(port: DigestMockPort()))
        do {
            _ = try await pipeline.run(
                scope: AgentScope(source: .feeds([])),
                accountID: "local-default",
                configuration: configuration,
                apiKey: ""
            )
            XCTFail("Expected empty scope error")
        } catch let error as AgentDigestError {
            XCTAssertEqual(error, .emptyScope)
        }
    }

    func testParserAcceptsFencesAliasesAndProse() throws {
        let parsed = try AgentDigestPipeline.parseVerdicts(
            #"Here you go: [{"id":"i1","verdict":"值得读","reason":"ok"}]"#,
            allowedIDs: ["i1"],
            language: "简体中文"
        )
        XCTAssertEqual(parsed["i1"]?.verdict, .worthReading)

        let bullets = AgentDigestPipeline.parseBullets("1. one\n2) two\n* three")
        XCTAssertEqual(bullets, ["one", "two", "three"])
    }
}
