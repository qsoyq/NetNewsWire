import XCTest
import Articles
@testable import Account

@MainActor final class ReaderAPIContentRebuildTests: XCTestCase {
	private var account: Account!
	private var delegate: ReaderAPIAccountDelegate!

	override func setUp() async throws {
		try await super.setUp()
		account = TestAccountManager.shared.createAccount(type: .freshRSS)
		delegate = try XCTUnwrap(account.delegate as? ReaderAPIAccountDelegate)
		let feed = account.createFeed(with: "feed/1", url: "https://example.com/feed", feedID: "feed/1", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
	}

	override func tearDown() async throws {
		TestAccountManager.shared.deleteAccount(account)
		delegate = nil
		account = nil
		try await super.tearDown()
	}

	func testRebuiltContentPreservesUnreadAndStarredStatus() async throws {
		_ = try await delegate.updateRebuiltEntries(account: account, entries: [entry("1", content: "original")], requestedIDs: ["1"])
		let originalArticles = await account.fetchArticlesAsync(.articleIDs(["1"]))
		_ = try await account.updateAsync(articles: originalArticles, statusKey: .read, flag: false)
		_ = try await account.updateAsync(articles: originalArticles, statusKey: .starred, flag: true)

		let count = try await delegate.updateRebuiltEntries(account: account, entries: [entry("1", content: "refreshed")], requestedIDs: ["1"])
		let refreshedArticles = await account.fetchArticlesAsync(.articleIDs(["1"]))
		let refreshed = try XCTUnwrap(refreshedArticles.first)
		XCTAssertEqual(count, 1)
		XCTAssertEqual(refreshed.contentHTML, "refreshed")
		XCTAssertFalse(refreshed.status.read)
		XCTAssertTrue(refreshed.status.starred)
	}

	func testPartialResponseUpdatesAvailableContentAndPreservesMissingArticle() async throws {
		_ = try await delegate.updateRebuiltEntries(account: account, entries: [entry("1", content: "first"), entry("2", content: "second")], requestedIDs: ["1", "2"])
		do {
			_ = try await delegate.updateRebuiltEntries(account: account, entries: [entry("1", content: "refreshed")], requestedIDs: ["1", "2"])
			XCTFail("Expected an incomplete response error")
		} catch ReaderAPIAccountDelegateError.invalidResponse { }
		let articles = await account.fetchArticlesAsync(.articleIDs(["1", "2"]))
		XCTAssertEqual(articles.count, 2)
		XCTAssertEqual(articles.first { $0.articleID == "1" }?.contentHTML, "refreshed")
		XCTAssertEqual(articles.first { $0.articleID == "2" }?.contentHTML, "second")
	}

	func testMissingContentDoesNotEraseExistingHTML() async throws {
		_ = try await delegate.updateRebuiltEntries(account: account, entries: [entry("1", content: "original")], requestedIDs: ["1"])
		do {
			_ = try await delegate.updateRebuiltEntries(account: account, entries: [entry("1", content: nil)], requestedIDs: ["1"])
			XCTFail("Expected an invalid response error")
		} catch ReaderAPIAccountDelegateError.invalidResponse { }
		let articles = await account.fetchArticlesAsync(.articleIDs(["1"]))
		XCTAssertEqual(articles.first?.contentHTML, "original")
	}

	func testUnrequestedServerEntriesAreIgnored() async throws {
		let count = try await delegate.updateRebuiltEntries(account: account, entries: [entry("1", content: "requested"), entry("2", content: "unrequested")], requestedIDs: ["1"])
		let articles = await account.fetchArticlesAsync(.articleIDs(["1", "2"]))
		XCTAssertEqual(count, 1)
		XCTAssertEqual(articles.articleIDs(), ["1"])
	}

	private func entry(_ id: String, content: String?) -> ReaderAPIEntry {
		ReaderAPIEntry(articleID: "tag:google.com,2005:reader/item/\(id)", title: "Article \(id)", author: nil,
			publishedTimestamp: Date().timeIntervalSince1970, crawledTimestamp: nil, timestampUsec: nil,
			summary: ReaderAPIArticleSummary(content: content), alternates: nil, categories: [],
			origin: ReaderAPIEntryOrigin(streamId: "feed/1", title: "Feed"))
	}
}
