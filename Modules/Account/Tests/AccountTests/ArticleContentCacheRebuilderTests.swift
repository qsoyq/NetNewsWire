//
//  ArticleContentCacheRebuilderTests.swift
//  AccountTests
//
//  Created by qsoyq on 9/19/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import XCTest
@testable import Account

final class ArticleContentCacheRebuilderTests: XCTestCase {

	func testSupportsOnlyFreshRSS() {
		XCTAssertTrue(ArticleContentCacheRebuilder.supports(.freshRSS))
		XCTAssertFalse(ArticleContentCacheRebuilder.supports(.onMyMac))
		XCTAssertFalse(ArticleContentCacheRebuilder.supports(.cloudKit))
		XCTAssertFalse(ArticleContentCacheRebuilder.supports(.feedbin))
		XCTAssertFalse(ArticleContentCacheRebuilder.supports(.inoreader))
		XCTAssertFalse(ArticleContentCacheRebuilder.supports(.newsBlur))
	}

	func testRebuildIDsUnionUnreadAndStarredWithoutDuplicates() {
		let unread: Set<String> = ["a", "b", "starred-unread"]
		let starred: Set<String> = ["starred-unread", "c"]
		let ids = ArticleContentCacheRebuilder.articleIDsToRebuild(unreadIDs: unread, starredIDs: starred)
		XCTAssertEqual(ids, ["a", "b", "c", "starred-unread"])
	}

	func testRebuildIDsIgnoreReadOnlyArticles() {
		let ids = ArticleContentCacheRebuilder.articleIDsToRebuild(unreadIDs: ["unread-1"], starredIDs: [])
		XCTAssertEqual(ids, ["unread-1"])
		XCTAssertFalse(ids.contains("read-old-article"))
	}

	func testContentRequestChunksUseBatchSize() {
		XCTAssertEqual(ArticleContentCacheRebuilder.contentsBatchSize, 400)
		XCTAssertEqual(ArticleContentCacheRebuilder.maxConcurrentContentRequests, 4)

		let ids = (0..<850).map(String.init)
		let chunks = ArticleContentCacheRebuilder.contentRequestChunks(articleIDs: ids)
		XCTAssertEqual(chunks.count, 3)
		XCTAssertEqual(chunks[0].count, 400)
		XCTAssertEqual(chunks[1].count, 400)
		XCTAssertEqual(chunks[2].count, 50)
		XCTAssertEqual(chunks.flatMap { $0 }, ids)
	}

	func testContentRequestChunksEmpty() {
		XCTAssertEqual(ArticleContentCacheRebuilder.contentRequestChunks(articleIDs: []), [])
	}
}
