import Foundation
import XCTest
@testable import PaperRssCore

final class AgentTopicClustererTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        _ id: String,
        _ title: String,
        _ summary: String,
        url: String?,
        minutes: Double = 0,
        characters: Int = 1_000,
        hash: String? = nil
    ) -> AgentClusterCandidate {
        AgentClusterCandidate(
            id: id,
            title: title,
            summary: summary,
            url: url,
            feedID: "f",
            publishedAt: base.addingTimeInterval(minutes * 60),
            contentHash: hash,
            contentCharacters: characters
        )
    }

    func testCanonicalURLRemovesTrackingAMPAndTrailingSlash() {
        let left = AgentTopicClusterer.canonicalURL("https://example.com/a/?utm_source=x&fbclid=y")
        let right = AgentTopicClusterer.canonicalURL("https://www.example.com/a?utm_medium=z")
        XCTAssertEqual(left, right)
        XCTAssertEqual(AgentTopicClusterer.canonicalURL("https://example.com/a/amp"), "https://example.com/a")
    }

    func testExactURLMergesAndChoosesBestRepresentative() {
        let clusterer = AgentTopicClusterer()
        let clusters = clusterer.cluster([
            candidate("short", "OpenAI 发布新模型", "摘要", url: "https://example.com/a?utm_source=x", characters: 100),
            candidate("long", "OpenAI 发布新模型", "摘要", url: "https://www.example.com/a/", characters: 5_000)
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberIDs.count, 2)
        XCTAssertEqual(clusters[0].representativeID, "long")
        XCTAssertEqual(clusters[0].similarityReason, "同一链接")
    }

    func testContentHashMergesEvenWithoutTitleSimilarity() {
        let clusters = AgentTopicClusterer().cluster([
            candidate("a", "标题甲", "摘要甲", url: "https://a.test/1", hash: "same"),
            candidate("b", "标题乙", "摘要乙", url: "https://b.test/2", hash: "same")
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].similarityReason, "正文完全一致")
    }

    func testNearTitlesAndSummariesMerge() {
        let titleA = "OpenAI 发布新一代推理模型：三个关键变化"
        let titleB = "OpenAI 发布新一代推理模型，三个关键变化"
        let summary = "推理能力提升，成本下降，API 即刻可用"
        let clusters = AgentTopicClusterer().cluster([
            candidate("a", titleA, summary, url: "https://a.test/1"),
            candidate("b", titleB, summary, url: "https://b.test/2", minutes: 30),
            candidate("c", "本地优先软件的同步难题", "CRDT 与版本向量", url: "https://c.test/3")
        ])
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.first(where: { $0.memberIDs.count == 2 })?.memberIDs.count, 2)
    }

    func testRoundupsAndCrossLanguageStaySingletons() {
        let clusters = AgentTopicClusterer().cluster([
            candidate("r1", "AI 周报 #218：本周 12 条动态", "同一篇周报", url: "https://r.test/1"),
            candidate("r2", "AI 周报 #218：本周 12 条动态", "同一篇周报", url: "https://r.test/2"),
            candidate("cn", "OpenAI 发布新一代推理模型", "推理能力提升", url: "https://cn.test/1"),
            candidate("en", "OpenAI releases a new reasoning model", "reasoning improved", url: "https://en.test/2")
        ])
        XCTAssertEqual(clusters.count, 4)
    }

    func testClusterSizeIsCapped() {
        let clusterer = AgentTopicClusterer(thresholds: AgentClusterThresholds(maximumClusterSize: 2))
        let clusters = clusterer.cluster([
            candidate("a", "OpenAI 发布新一代推理模型：三个关键变化", "推理能力提升，成本下降", url: "https://a.test/1"),
            candidate("b", "OpenAI 发布新一代推理模型，三个关键变化", "推理能力提升，成本下降", url: "https://b.test/2"),
            candidate("c", "OpenAI 发布新一代推理模型：三个关键变化！", "推理能力提升，成本下降", url: "https://c.test/3")
        ])
        XCTAssertTrue(clusters.allSatisfy { $0.memberIDs.count <= 2 })
    }

    func testRoundupKeywordAndLanguageHelpers() {
        XCTAssertTrue(AgentTopicClusterer.isRoundup("本周 AI 速览"))
        XCTAssertFalse(AgentTopicClusterer.isRoundup("推理模型的成本账"))
        XCTAssertTrue(AgentTopicClusterer.containsCJK("中文标题"))
        XCTAssertFalse(AgentTopicClusterer.containsCJK("English title"))
    }
}
