//
//  AccountArticleFetchTests.swift
//  AccountTests
//

import XCTest
import Articles
@testable import Account

@MainActor final class AccountArticleFetchTests: XCTestCase {

	private var account: Account!

	override func setUp() async throws {
		try await super.setUp()
		account = TestAccountManager.shared.createAccount(type: .feedbin, transport: TestTransport())
	}

	override func tearDown() async throws {
		TestAccountManager.shared.deleteAccount(account)
		account = nil
		try await super.tearDown()
	}

	func testAsyncBatchFetchSplitsLargeFeedIDSets() async throws {
		let feedIDs = Set((0...1_800).map { "feed/\($0)" })

		let articles = try await account.fetchArticlesAsync(feedIDs: feedIDs)

		XCTAssertTrue(articles.isEmpty)
	}

	func testAsyncBatchFetchMatchesIndividualFeedFetches() async throws {
		let itemsByFeed = FeedlyTestSupport().makeParsedItemTestDataFor(numberOfFeeds: 2, numberOfItemsInFeeds: 3)
		let feeds = itemsByFeed.keys.sorted().map { feedID in
			let feed = account.createFeed(with: feedID, url: "https://example.com/\(feedID)", feedID: feedID, homePageURL: nil)
			account.addFeedToTreeAtTopLevel(feed)
			return feed
		}
		_ = try await account.database.updateAsync(feedIDsAndItems: itemsByFeed, defaultRead: false)

		var individuallyFetched = Set<Article>()
		for feed in feeds {
			individuallyFetched.formUnion(try await feed.fetchArticlesAsync())
		}
		let batchFetched = try await account.fetchArticlesAsync(feedIDs: Set(itemsByFeed.keys))

		XCTAssertEqual(batchFetched.articleIDs(), individuallyFetched.articleIDs())
	}

	func testAsyncUnreadBatchFetchReturnsOnlyUnreadArticles() async throws {
		let itemsByFeed = FeedlyTestSupport().makeParsedItemTestDataFor(numberOfFeeds: 2, numberOfItemsInFeeds: 3)
		let feeds = itemsByFeed.keys.sorted().map { feedID in
			let feed = account.createFeed(with: feedID, url: "https://example.com/\(feedID)", feedID: feedID, homePageURL: nil)
			account.addFeedToTreeAtTopLevel(feed)
			return feed
		}
		_ = try await account.database.updateAsync(feedIDsAndItems: itemsByFeed, defaultRead: false)

		let allArticles = try await account.fetchArticlesAsync(feedIDs: Set(feeds.map(\.feedID)))
		guard let articleToMarkRead = allArticles.first else {
			return XCTFail("Expected fetched articles")
		}
		_ = try await account.updateAsync(articles: Set([articleToMarkRead]), statusKey: .read, flag: true)

		let unreadArticles = try await account.fetchUnreadArticlesAsync(feedIDs: Set(feeds.map(\.feedID)))

		XCTAssertEqual(unreadArticles.count, allArticles.count - 1)
		XCTAssertTrue(unreadArticles.allSatisfy { !$0.status.read })
	}

	func testLargeReadHistoryDoesNotAppearInUnreadBatch() async throws {
		let itemsByFeed = FeedlyTestSupport().makeParsedItemTestDataFor(numberOfFeeds: 1, numberOfItemsInFeeds: 11_300)
		let feedID = "feed/0"
		let feed = account.createFeed(with: feedID, url: "https://example.com/feed", feedID: feedID, homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		_ = try await account.database.updateAsync(feedIDsAndItems: itemsByFeed, defaultRead: true)
		let expectedIDs = Set((0..<300).map { "feed/0/articles/\($0)" })
		let selected = try await account.fetchArticlesAsync(.articleIDs(expectedIDs))
		XCTAssertEqual(selected.count, 300)
		_ = try await account.updateAsync(articles: selected, statusKey: .read, flag: false)
		let feedIDs = Set([feedID] + (1...1_800).map { "missing/\($0)" })
		let unread = try await account.fetchUnreadArticlesAsync(feedIDs: feedIDs)
		XCTAssertEqual(unread.articleIDs(), expectedIDs)
		XCTAssertEqual(feed.unreadCount, 300)
	}
}
