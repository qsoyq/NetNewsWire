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
}
