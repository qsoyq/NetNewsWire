import Foundation

struct ArticleMediaSaveState: Sendable {
	struct Result: Sendable {
		let requestedCount: Int
		var savedCount = 0
		var failedCount = 0
		var skippedCount: Int
		var cancelledCount = 0
		var wasCancelled = false
	}

	enum Outcome {
		case saved
		case failed
		case skipped
	}

	private enum Phase {
		case ready
		case preparing
		case saving
		case finished
	}

	private(set) var result: Result
	private var completedCount = 0
	private var phase = Phase.ready

	var isSavingToPhotoLibrary: Bool {
		phase == .saving
	}

	init(requestedCount: Int, skippedCount: Int) {
		result = Result(requestedCount: requestedCount, skippedCount: skippedCount)
	}

	mutating func startNextItem(isCancelled: Bool) -> Int? {
		guard phase == .ready else {
			return nil
		}
		if isCancelled {
			cancelRemainingItems()
			return nil
		}
		guard completedCount < result.requestedCount else {
			phase = .finished
			return nil
		}
		phase = .preparing
		return completedCount + 1
	}

	mutating func startPhotoLibrarySave() {
		precondition(phase == .preparing)
		phase = .saving
	}

	mutating func finishCurrentItem(_ outcome: Outcome) {
		precondition(phase == .preparing || phase == .saving)
		switch outcome {
		case .saved: result.savedCount += 1
		case .failed: result.failedCount += 1
		case .skipped: result.skippedCount += 1
		}
		completedCount += 1
		phase = .ready
	}

	mutating func cancelRemainingItems() {
		// PhotoKit cannot be cancelled. Record its actual outcome before cancelling the rest.
		precondition(phase != .saving)
		result.wasCancelled = true
		result.cancelledCount = result.requestedCount - completedCount
		phase = .finished
	}

	static func isCancellation(_ error: Error) -> Bool {
		error is CancellationError || (error as? URLError)?.code == .cancelled
	}
}
