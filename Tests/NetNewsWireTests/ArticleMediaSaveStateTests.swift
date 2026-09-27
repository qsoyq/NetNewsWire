import XCTest
@testable import NetNewsWire

final class ArticleMediaSaveStateTests: XCTestCase {
	func testCancellationBeforeStartCountsEveryRequestedItemAsCancelled() {
		var state = ArticleMediaSaveState(requestedCount: 3, skippedCount: 2)
		XCTAssertNil(state.startNextItem(isCancelled: true))
		XCTAssertEqual(state.result.cancelledCount, 3)
		XCTAssertEqual(state.result.skippedCount, 2)
		XCTAssertEqual(state.result.failedCount, 0)
		XCTAssertTrue(state.result.wasCancelled)
		XCTAssertNil(state.startNextItem(isCancelled: false))
	}

	func testCancellationDuringPreparationPreservesSavedItems() {
		var state = ArticleMediaSaveState(requestedCount: 3, skippedCount: 0)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 1)
		state.startPhotoLibrarySave()
		state.finishCurrentItem(.saved)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 2)
		state.cancelRemainingItems()
		XCTAssertEqual(state.result.savedCount, 1)
		XCTAssertEqual(state.result.cancelledCount, 2)
		XCTAssertEqual(state.result.failedCount, 0)
		XCTAssertNil(state.startNextItem(isCancelled: false))
	}

	func testPhotoLibrarySuccessAfterCancellationIsStillSaved() {
		var state = ArticleMediaSaveState(requestedCount: 3, skippedCount: 0)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 1)
		state.startPhotoLibrarySave()
		XCTAssertTrue(state.isSavingToPhotoLibrary)
		state.finishCurrentItem(.saved)
		XCTAssertNil(state.startNextItem(isCancelled: true))
		XCTAssertEqual(state.result.savedCount, 1)
		XCTAssertEqual(state.result.cancelledCount, 2)
	}

	func testPhotoLibraryFailureAfterCancellationIsStillFailed() {
		var state = ArticleMediaSaveState(requestedCount: 2, skippedCount: 0)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 1)
		state.startPhotoLibrarySave()
		state.finishCurrentItem(.failed)
		XCTAssertNil(state.startNextItem(isCancelled: true))
		XCTAssertEqual(state.result.failedCount, 1)
		XCTAssertEqual(state.result.cancelledCount, 1)
	}

	func testCancellationDuringLastPhotoLibrarySavePreservesItsOutcome() {
		var state = ArticleMediaSaveState(requestedCount: 1, skippedCount: 0)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 1)
		state.startPhotoLibrarySave()
		state.finishCurrentItem(.saved)
		XCTAssertNil(state.startNextItem(isCancelled: true))
		XCTAssertTrue(state.result.wasCancelled)
		XCTAssertEqual(state.result.savedCount, 1)
		XCTAssertEqual(state.result.cancelledCount, 0)
	}

	func testResultsKeepPreparationFailuresAndSkippedItemsSeparate() {
		var state = ArticleMediaSaveState(requestedCount: 3, skippedCount: 2)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 1)
		state.finishCurrentItem(.skipped)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 2)
		state.finishCurrentItem(.failed)
		XCTAssertEqual(state.startNextItem(isCancelled: false), 3)
		state.startPhotoLibrarySave()
		state.finishCurrentItem(.saved)
		XCTAssertNil(state.startNextItem(isCancelled: false))
		XCTAssertEqual(state.result.savedCount, 1)
		XCTAssertEqual(state.result.failedCount, 1)
		XCTAssertEqual(state.result.skippedCount, 3)
		XCTAssertEqual(state.result.cancelledCount, 0)
		XCTAssertFalse(state.result.wasCancelled)
	}

	func testCancellationRecognizesURLSessionCancellation() {
		XCTAssertTrue(ArticleMediaSaveState.isCancellation(CancellationError()))
		XCTAssertTrue(ArticleMediaSaveState.isCancellation(URLError(.cancelled)))
		XCTAssertFalse(ArticleMediaSaveState.isCancellation(URLError(.timedOut)))
		XCTAssertFalse(ArticleMediaSaveState.isCancellation(URLError(.notConnectedToInternet)))
	}
}
