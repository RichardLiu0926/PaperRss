import Foundation
import XCTest
@testable import PaperRssCore

final class AgentDigestCacheTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var cache: AgentDigestCache!
    private let configuration = LLMConfiguration(
        baseURL: "https://agent.test/v1",
        model: "test-model",
        temperature: 0.2,
        targetLanguage: "简体中文",
        allowInsecureLocalEndpoint: false
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        cache = AgentDigestCache(database: database)
    }

    override func tearDownWithError() throws {
        cache = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func digest() -> AgentDigest {
        AgentDigest(
            scope: AgentScope(source: .folders([AgentFolderRef(id: "fo1", accountID: "local-default", name: "AI")])),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            unreadCount: 2,
            analyzedCount: 1,
            deepReadCount: 1,
            model: "test-model",
            items: [
                AgentDigestItem(
                    id: "i1",
                    title: "Title",
                    feedTitle: "Feed",
                    url: URL(string: "https://a.test"),
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    verdict: .worthReading,
                    reason: "relevant",
                    bullets: ["one", "two", "three"],
                    isRead: false,
                    isStarred: false,
                    duplicateIDs: ["i2"],
                    clusterReason: "同一链接"
                )
            ]
        )
    }

    func testCacheRoundTripAndKeyIsolation() throws {
        let value = digest()
        try cache.save(value, accountID: "local-default", configuration: configuration, maximumArticles: 30, deepReadLimit: 5)

        let loaded = try cache.load(
            scope: value.scope,
            accountID: "local-default",
            configuration: configuration,
            maximumArticles: 30,
            deepReadLimit: 5
        )
        XCTAssertEqual(loaded, value)

        XCTAssertNil(try cache.load(
            scope: value.scope,
            accountID: "local-default",
            configuration: configuration,
            maximumArticles: 10,
            deepReadLimit: 5
        ))
        XCTAssertNil(try cache.load(
            scope: AgentScope(),
            accountID: "local-default",
            configuration: configuration,
            maximumArticles: 30,
            deepReadLimit: 5
        ))
    }

    func testCacheExpiresAfterOneHour() throws {
        let value = digest()
        try cache.save(value, accountID: "local-default", configuration: configuration, maximumArticles: 30, deepReadLimit: 5)
        XCTAssertNil(try cache.load(
            scope: value.scope,
            accountID: "local-default",
            configuration: configuration,
            maximumArticles: 30,
            deepReadLimit: 5,
            now: Date().addingTimeInterval(AgentDigestCache.maximumAge + 60)
        ))
    }
}
