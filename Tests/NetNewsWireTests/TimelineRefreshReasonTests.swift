//
//  TimelineRefreshReasonTests.swift
//  NetNewsWireTests
//

import XCTest
import Articles

@testable import NetNewsWire

final class TimelineRefreshReasonTests: XCTestCase {

	func testForegroundRefreshMergesExistingTimeline() {
		XCTAssertEqual(TimelineRefreshReason.foreground.fetchMode, .merge)
		XCTAssertFalse(TimelineRefreshReason.foreground.emptiesTimelineBeforeFetch)
	}

	func testFeedSelectionRefreshReplacesTimeline() {
		XCTAssertEqual(TimelineRefreshReason.feedSelection.fetchMode, .replace)
		XCTAssertTrue(TimelineRefreshReason.feedSelection.emptiesTimelineBeforeFetch)
	}

	func testTimelineArticleIDIncludesAccountIdentity() {
		let first = makeArticle(accountID: "account-1", articleID: "shared-id")
		let second = makeArticle(accountID: "account-2", articleID: "shared-id")
		let equivalent = makeArticle(accountID: "account-1", articleID: "shared-id")

		XCTAssertNotEqual(TimelineArticleID(first), TimelineArticleID(second))
		XCTAssertEqual(TimelineArticleID(first), TimelineArticleID(equivalent))
	}

	func testUnchangedLargeTimelineSkipsSnapshotAndStatusDoesNotChangeIdentity() {
		let identifiers = (0..<11_000).map { TimelineArticleID(accountID: "account", articleID: String($0)) }
		var state = TimelineSnapshotState()
		XCTAssertTrue(state.requiresSnapshot(identifiers))
		state.beginApply(identifiers)
		state.finishApply()
		XCTAssertFalse(state.requiresSnapshot(identifiers))
		XCTAssertTrue(state.requiresSnapshot(Array(identifiers.dropLast(2))))
		XCTAssertTrue(state.requiresSnapshot(Array(identifiers.reversed())))

		let article = makeArticle(accountID: "account", articleID: "0")
		let originalID = TimelineArticleID(article)
		article.status.read = true
		XCTAssertEqual(TimelineArticleID(article), originalID)
	}

	func testUpdatesAreDeferredDuringScrollingAndInFlightApply() {
		var state = TimelineSnapshotState()
		let original = [TimelineArticleID(accountID: "account", articleID: "1")]
		state.beginApply(original)
		XCTAssertFalse(state.requestUpdate(isInteracting: false))
		XCTAssertTrue(state.needsUpdate)
		state.finishApply()
		XCTAssertFalse(state.requestUpdate(isInteracting: true))
		XCTAssertFalse(state.requestUpdate(isInteracting: true))
		XCTAssertEqual(state.identifiers, original)
		XCTAssertTrue(state.requestUpdate(isInteracting: false))
		XCTAssertFalse(state.needsUpdate)
		let latest = [TimelineArticleID(accountID: "account", articleID: "3")]
		state.beginApply(latest)
		state.finishApply()
		XCTAssertEqual(state.identifiers, latest)
		XCTAssertFalse(state.requiresSnapshot(latest))
	}

	private func makeArticle(accountID: String, articleID: String) -> Article {
		Article(
			accountID: accountID,
			articleID: articleID,
			feedID: "feed",
			uniqueID: articleID,
			title: nil,
			contentHTML: nil,
			contentText: nil,
			markdown: nil,
			url: nil,
			externalURL: nil,
			summary: nil,
			imageURL: nil,
			datePublished: nil,
			dateModified: nil,
			authors: nil,
			status: ArticleStatus(articleID: articleID, read: false, dateArrived: Date())
		)
	}
}
