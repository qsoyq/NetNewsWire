//
//  TimelineRefreshReasonTests.swift
//  NetNewsWireTests
//

import XCTest

@testable import NetNewsWire

final class TimelineRefreshReasonTests: XCTestCase {

	func testForegroundRefreshMergesExistingTimeline() {
		XCTAssertEqual(TimelineRefreshReason.foreground.fetchMode, .merge)
	}

	func testFeedSelectionRefreshReplacesTimeline() {
		XCTAssertEqual(TimelineRefreshReason.feedSelection.fetchMode, .replace)
	}
}
