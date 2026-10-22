import Foundation
import XCTest
@testable import PaperRssCore

final class AgentArticleQueryTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var query: AgentArticleQuery!
    private var now: Double!
    private var startOfDay: Double!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        query = AgentArticleQuery(database: database)
        now = Date().timeIntervalSince1970
        startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        try insertFixture()
    }

    override func tearDownWithError() throws {
        query = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func insertFixture() throws {
        let twoDaysAgo = now - 2 * 24 * 3600
        try database.write { db in
            try db.execute(sql: """
            INSERT INTO accounts (id, type, display_name, is_enabled, created_at, updated_at) VALUES
              ('local-default', 'local', '本地订阅', 1, ?, ?),
              ('acc-cloud', 'freshRSS', '云端', 1, ?, ?);
            """, arguments: [now, now, now, now])
            try db.execute(sql: """
            INSERT INTO feeds (id, account_id, title, feed_url, is_deleted, updated_at, sort_order) VALUES
              ('f1', 'local-default', '少数派', 'https://f1.test/rss', 0, ?, 0),
              ('f2', 'local-default', '机器之心', 'https://f2.test/rss', 0, ?, 0),
              ('f3', 'local-default', '设计周刊', 'https://f3.test/rss', 0, ?, 0),
              ('f4', 'acc-cloud', 'Cloud Feed', 'https://f4.test/rss', 0, ?, 0);
            """, arguments: [now, now, now, now])
            try db.execute(sql: """
            INSERT INTO folders (id, account_id, name, is_deleted, updated_at, sort_order) VALUES
              ('fo1', 'local-default', 'AI 基建', 0, ?, 0),
              ('fo2', 'local-default', '设计', 0, ?, 0),
              ('fo3', 'acc-cloud', '云端组', 0, ?, 0);
            """, arguments: [now, now, now])
            try db.execute(sql: """
            INSERT INTO feed_folders (feed_id, folder_id) VALUES
              ('f1', 'fo1'), ('f2', 'fo1'), ('f3', 'fo2'), ('f1', 'fo2'), ('f4', 'fo3');
            """)
            try db.execute(sql: """
            INSERT INTO items (id, account_id, external_id, feed_id, created_at, updated_at) VALUES
              ('i1', 'local-default', 'e1', 'f1', ?, ?),
              ('i2', 'local-default', 'e2', 'f2', ?, ?),
              ('i3', 'local-default', 'e3', 'f3', ?, ?),
              ('i4', 'local-default', 'e4', 'f1', ?, ?),
              ('i5', 'acc-cloud', 'e5', 'f4', ?, ?),
              ('i6', 'local-default', 'e6', 'f3', ?, ?);
            """, arguments: [now, now, now, now, now, now, twoDaysAgo, twoDaysAgo, now, now, now, now])
            try db.execute(sql: """
            INSERT INTO articles (item_id, title, url, published_at, summary, content_updated_at) VALUES
              ('i1', 'A1', 'https://a1.test', ?, 'summary a1', ?),
              ('i2', 'A2', 'https://a2.test', ?, 'summary a2', ?),
              ('i3', 'A3', 'https://a3.test', NULL, 'summary a3', ?),
              ('i4', 'A4', 'https://a4.test', ?, 'summary a4', ?),
              ('i5', 'A5', 'https://a5.test', ?, 'summary a5', ?),
              ('i6', 'A6', 'https://a6.test', ?, 'summary a6', ?);
            """, arguments: [now, now, now, now, now, twoDaysAgo, twoDaysAgo, now, now, now, now])
            try db.execute(sql: """
            INSERT INTO article_states (item_id, is_read, is_starred, date_arrived, updated_at) VALUES
              ('i1', 0, 0, ?, ?), ('i2', 0, 1, ?, ?), ('i3', 0, 0, ?, ?),
              ('i4', 0, 0, ?, ?), ('i5', 0, 0, ?, ?), ('i6', 1, 0, ?, ?);
            """, arguments: [now, now, now, now, now, now, twoDaysAgo, twoDaysAgo, now, now, now, now])
        }
    }

    func testTodayCountRespectsAccountAndUnread() throws {
        let today = AgentScope(from: Date(timeIntervalSince1970: startOfDay))
        XCTAssertEqual(try query.count(scope: today, accountID: "local-default"), 3)
        XCTAssertEqual(try query.count(scope: today, accountID: nil), 4)
    }

    func testFeedAndFolderScopesUnionAndDedupe() throws {
        let feeds = AgentScope(source: .feeds(["f1", "f2"]))
        XCTAssertEqual(try query.count(scope: feeds, accountID: "local-default"), 3)

        let ai = AgentFolderRef(id: "fo1", accountID: "local-default", name: "AI 基建")
        let design = AgentFolderRef(id: "fo2", accountID: "local-default", name: "设计")
        XCTAssertEqual(try query.count(scope: AgentScope(source: .folders([ai])), accountID: "local-default"), 3)
        // f1 belongs to both folders; selecting both must not double count i1/i4.
        XCTAssertEqual(try query.count(scope: AgentScope(source: .folders([ai, design])), accountID: "local-default"), 4)
    }

    func testTimeFallbackAndReadInclusion() throws {
        let allTime = AgentScope(unreadOnly: false)
        XCTAssertEqual(try query.count(scope: allTime, accountID: "local-default"), 5)

        let recent = AgentScope(
            from: Date(timeIntervalSince1970: now - 3600),
            unreadOnly: false
        )
        XCTAssertEqual(try query.count(scope: recent, accountID: "local-default"), 4)
    }

    func testFetchProjectionAndOptions() throws {
        let today = AgentScope(from: Date(timeIntervalSince1970: startOfDay))
        let page = try query.fetch(scope: today, accountID: "local-default", limit: 2)
        XCTAssertEqual(page.count, 2)
        XCTAssertTrue(page.allSatisfy { !$0.isRead })

        let feeds = try query.feedOptions(accountID: "local-default")
        XCTAssertEqual(feeds.first(where: { $0.id == "f1" })?.unreadCount, 2)
        XCTAssertEqual(feeds.first(where: { $0.id == "f3" })?.unreadCount, 1)

        let folders = try query.folderOptions(accountID: "local-default")
        XCTAssertEqual(folders.first(where: { $0.id == "fo1" })?.unreadCount, 3)
        XCTAssertEqual(folders.first(where: { $0.id == "fo2" })?.unreadCount, 3)
    }

    func testScopeJSONRoundTrip() throws {
        let folder = AgentFolderRef(id: "fo1", accountID: "local-default", name: "AI 基建")
        let scope = AgentScope(
            source: .folders([folder]),
            from: Date(timeIntervalSince1970: startOfDay),
            unreadOnly: true
        )
        XCTAssertEqual(AgentScope.decode(jsonString: scope.jsonString), scope)
    }
}
