//
//  TimelineRefreshReasonTests.swift
//  NetNewsWireTests
//

import XCTest

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
}
