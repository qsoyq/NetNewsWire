import XCTest
import Articles
@testable import NetNewsWire

final class TimelineArticlePreparationTests: XCTestCase {
	func testBackgroundDateSortMatchesAscendingAndDescendingOrder() throws {
		let earlier = article("earlier", date: 10)
		let later = article("later", date: 20)
		let keys = [TimelineArticleSortKey(article: later, feedName: ""), TimelineArticleSortKey(article: earlier, feedName: "")]
		XCTAssertEqual(try TimelinePreparedArticles.sort(keys, direction: .orderedAscending, groupByFeed: false).articles.map(\.articleID), ["earlier", "later"])
		XCTAssertEqual(try TimelinePreparedArticles.sort(keys, direction: .orderedDescending, groupByFeed: false).articles.map(\.articleID), ["later", "earlier"])
	}

	func testFeedGroupingUsesNameThenDateAndStableIdentity() throws {
		let keys = [
			TimelineArticleSortKey(article: article("b", date: 10, feedID: "feed-z"), feedName: "Zoo"),
			TimelineArticleSortKey(article: article("a", date: 10, feedID: "feed-a"), feedName: "Alpha"),
			TimelineArticleSortKey(article: article("c", date: 20, feedID: "feed-a"), feedName: "alpha")
		]
		XCTAssertEqual(try TimelinePreparedArticles.sort(keys, direction: .orderedDescending, groupByFeed: true).articles.map(\.articleID), ["c", "a", "b"])
	}

	func testMappingsKeepSameArticleIDInDifferentAccounts() throws {
		let first = article("shared", accountID: "first")
		let second = article("shared", accountID: "second")
		let model = try TimelinePreparedArticles.map([first, second])
		XCTAssertEqual(model.identifiers.count, 2)
		XCTAssertTrue(model.articlesByID[TimelineArticleID(first)] === first)
		XCTAssertTrue(model.articlesByID[TimelineArticleID(second)] === second)
	}

	func testDuplicateIdentityDoesNotCreateInvalidSnapshot() throws {
		let model = try TimelinePreparedArticles.map([article("same"), article("same")])
		XCTAssertEqual(model.identifiers.count, 1)
		XCTAssertEqual(model.articlesByID.count, 1)
	}

	func testNewSelectionInvalidatesPreparedResults() {
		var state = TimelinePreparationState()
		let original = state.invalidate()
		XCTAssertTrue(state.isCurrent(original))
		let newer = state.invalidate()
		XCTAssertFalse(state.isCurrent(original))
		XCTAssertTrue(state.isCurrent(newer))
	}

	func testLargeModelHasConsistentOrderAndMappings() throws {
		let articles = (0..<11_000).map { article(String($0), date: Double($0)) }
		let keys = articles.reversed().map { TimelineArticleSortKey(article: $0, feedName: "") }
		let model = try TimelinePreparedArticles.sort(keys, direction: .orderedAscending, groupByFeed: false)
		XCTAssertEqual(model.articles.count, 11_000)
		XCTAssertEqual(model.identifiers, articles.map(TimelineArticleID.init))
		XCTAssertEqual(model.articlesByID.count, 11_000)
	}

	func testCancelledPreparationDoesNotReturnModel() async throws {
		let gate = PreparationGate()
		let articles = [article("one")]
		let worker = Task.detached {
			await gate.wait()
			return try TimelinePreparedArticles.map(articles)
		}
		worker.cancel()
		await gate.open()
		do {
			_ = try await worker.value
			XCTFail("Expected cancellation")
		} catch is CancellationError { }
	}

	private func article(_ id: String, accountID: String = "account", date: Double = 10, feedID: String = "feed") -> Article {
		Article(accountID: accountID, articleID: id, feedID: feedID, uniqueID: id, title: id,
			contentHTML: nil, contentText: nil, markdown: nil, url: nil, externalURL: nil, summary: nil,
			imageURL: nil, datePublished: Date(timeIntervalSince1970: date), dateModified: nil, authors: nil,
			status: ArticleStatus(articleID: id, read: false, dateArrived: Date()))
	}
}

private actor PreparationGate {
	private var continuation: CheckedContinuation<Void, Never>?
	private var isOpen = false

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { continuation = $0 }
	}

	func open() {
		isOpen = true
		continuation?.resume()
		continuation = nil
	}
}
