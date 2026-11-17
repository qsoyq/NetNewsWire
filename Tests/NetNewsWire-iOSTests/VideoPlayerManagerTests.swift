import AVFoundation
import Testing
@testable import NetNewsWire

@MainActor @Suite struct VideoPlayerManagerTests {

	@Test func lateNotFoundReplacesPendingRetry() {
		#expect(VideoPlayerManager.playbackFailureAction(notFound: true, attemptResolved: true,
			retryPending: true, isErrorLog: true) == .skipNotFound)
	}

	@Test func duplicateNotFoundDoesNotAdvanceTwice() {
		#expect(VideoPlayerManager.playbackFailureAction(notFound: true, attemptResolved: true,
			retryPending: false, isErrorLog: true) == .ignore)
	}

	@Test func nonFatalLogDoesNotStartRecovery() {
		#expect(VideoPlayerManager.playbackFailureAction(notFound: false, attemptResolved: false,
			retryPending: false, isErrorLog: true) == .ignore)
		#expect(VideoPlayerManager.playbackFailureAction(notFound: false, attemptResolved: false,
			retryPending: false, isErrorLog: false) == .recover)
	}

	@Test func consecutiveNotFoundAttemptsAlwaysSkipWithoutRetry() {
		for _ in 0..<5 {
			#expect(VideoPlayerManager.playbackFailureAction(notFound: true, attemptResolved: false,
				retryPending: false, isErrorLog: false) == .skipNotFound)
		}
	}

	@Test func wrappedAVFoundationNotFoundIsRecognized() {
		let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12938)
		let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist,
			userInfo: [NSUnderlyingErrorKey: underlying])
		#expect(VideoPlayerManager.isNotFound(error: error, logErrors: []))
	}

	@Test func notFoundCanBeReportedOnlyInTheErrorLog() {
		#expect(VideoPlayerManager.isNotFound(error: nil, logErrors: [("HTTP", 404)]))
		#expect(VideoPlayerManager.isNotFound(error: nil, logErrors: [("HTTP", 404), ("HTTP", 500)]))
	}

	@Test(arguments: ["CoreMediaErrorDomain", NSOSStatusErrorDomain])
	func mediaResourceNotFoundIsRecognized(domain: String) {
		#expect(VideoPlayerManager.isNotFound(error: NSError(domain: domain, code: -12938), logErrors: []))
	}

	@Test(arguments: [403, 500, -1001, -1009, -1100, 404, -12938])
	func arbitraryErrorCodesAreNotEnoughToMarkRead(code: Int) {
		#expect(!VideoPlayerManager.isNotFound(error: NSError(domain: NSURLErrorDomain, code: code), logErrors: []))
	}

	@Test(arguments: [403, 500, -1001, -1009])
	func otherStreamErrorsDoNotMarkRead(code: Int) {
		#expect(!VideoPlayerManager.isNotFound(error: nil, logErrors: [("HTTP", code)]))
	}

	@Test func absentErrorEvidenceDoesNotMarkRead() {
		#expect(!VideoPlayerManager.isNotFound(error: nil, logErrors: []))
	}

	@Test(arguments: [false, true])
	func pipQueueExhaustionFinishesWithoutArticleNavigation(autoGotoNext: Bool) {
		#expect(VideoPlayerManager.playbackEndAction(
			isPiPActive: true, pipAutoPlayNextVideo: true,
			autoGotoNextAfterVideo: autoGotoNext, hasNextVideo: false
		) == .finish)
	}

	@Test func threeVideoQueueNeverFallsBackToTheStaleArticleSelection() {
		let actions = [true, true, false].map { hasNextVideo in
			VideoPlayerManager.playbackEndAction(
				isPiPActive: true, pipAutoPlayNextVideo: true,
				autoGotoNextAfterVideo: true, hasNextVideo: hasNextVideo
			)
		}
		#expect(actions == [.playNextVideo, .playNextVideo, .finish])
	}

	@Test(arguments: [nil, "<p>An article without video.</p>"] as [String?])
	func missingOrNonVideoArticleEndsPipQueue(body: String?) {
		let nextVideoURL = VideoPlayerManager.extractFirstVideoURL(from: body)
		#expect(nextVideoURL == nil)
		#expect(VideoPlayerManager.playbackEndAction(
			isPiPActive: true, pipAutoPlayNextVideo: true,
			autoGotoNextAfterVideo: true, hasNextVideo: nextVideoURL != nil
		) == .finish)
	}

	@Test(arguments: [false, true])
	func pipContinuesWhenTheNextArticleHasVideo(autoGotoNext: Bool) {
		#expect(VideoPlayerManager.playbackEndAction(
			isPiPActive: true, pipAutoPlayNextVideo: true,
			autoGotoNextAfterVideo: autoGotoNext, hasNextVideo: true
		) == .playNextVideo)
	}

	@Test(arguments: [false, true], [false, true])
	func ordinaryPlaybackPreservesAutomaticNavigation(pipAutoPlayNext: Bool, autoGotoNext: Bool) {
		for hasNextVideo in [false, true] {
			#expect(VideoPlayerManager.playbackEndAction(
				isPiPActive: false, pipAutoPlayNextVideo: pipAutoPlayNext,
				autoGotoNextAfterVideo: autoGotoNext, hasNextVideo: hasNextVideo
			) == (autoGotoNext ? .selectNextArticle : .finish))
		}
	}

	@Test(arguments: [false, true], [false, true])
	func disabledPipContinuationPreservesAutomaticNavigation(autoGotoNext: Bool, hasNextVideo: Bool) {
		#expect(VideoPlayerManager.playbackEndAction(
			isPiPActive: true, pipAutoPlayNextVideo: false,
			autoGotoNextAfterVideo: autoGotoNext, hasNextVideo: hasNextVideo
		) == (autoGotoNext ? .selectNextArticle : .finish))
	}

	@Test func recoveryRetriesAreBoundedAcrossAttempts() {
		var state = VideoPlaybackRecovery()
		state.startAttempt(now: 0)
		#expect(state.retryDelay() == 1)
		state.startAttempt(now: 1)
		#expect(state.retryDelay() == 3)
		state.startAttempt(now: 4)
		#expect(state.retryDelay() == nil)
		#expect(state.retries == 2)
	}

	@Test func loadingAndStallingHaveDifferentDeadlines() {
		var state = VideoPlaybackRecovery()
		state.startAttempt(now: 0)
		for second in 1..<15 {
			#expect(state.sample(now: Double(second), mediaTime: 0, playing: false, waiting: true) == .none)
		}
		#expect(state.sample(now: 15, mediaTime: 0, playing: false, waiting: true) == .timeout)
		state.startAttempt(now: 20)
		#expect(state.sample(now: 21, mediaTime: 1, playing: true, waiting: false) == .progress)
		for second in 22..<41 {
			#expect(state.sample(now: Double(second), mediaTime: 1, playing: false, waiting: true) == .none)
		}
		#expect(state.sample(now: 41, mediaTime: 1, playing: false, waiting: true) == .timeout)
	}

	@Test func pauseSeekAndSuspensionCannotConsumeTheQueue() {
		var state = VideoPlaybackRecovery()
		state.startAttempt(now: 0)
		for second in 1...100 {
			#expect(state.sample(now: Double(second), mediaTime: 0, playing: false, waiting: false) == .none)
		}
		#expect(state.recoveryWait == 0)
		#expect(state.sample(now: 101, mediaTime: 200, playing: true, waiting: false) == .none)
		state.suspend()
		#expect(state.retryDelay() == nil)
		#expect(state.sample(now: 500, mediaTime: 200, playing: false, waiting: true) == .none)
		#expect(state.recoveryWait == 0)
	}

	@Test func systemSuspensionDoesNotCountAsRecoveryWait() {
		var state = VideoPlaybackRecovery()
		state.startAttempt(now: 0)
		#expect(state.sample(now: 600, mediaTime: 0, playing: false, waiting: true) == .none)
		#expect(state.recoveryWait == 1)
	}

	@Test func onlySustainedProgressIsHealthy() {
		var state = VideoPlaybackRecovery()
		state.startAttempt(now: 0)
		for second in 1..<5 {
			#expect(state.sample(now: Double(second), mediaTime: Double(second), playing: true, waiting: false) == .progress)
		}
		#expect(state.sample(now: 5, mediaTime: 5, playing: true, waiting: false) == .healthy)
		state.pause()
		#expect(state.sample(now: 6, mediaTime: 6, playing: true, waiting: false) == .progress)
	}

	@Test func totalRecoveryBudgetSurvivesIntermittentProgress() {
		var state = VideoPlaybackRecovery()
		state.startAttempt(now: 0)
		var now: Double = 0
		var position: Double = 0
		for _ in 0..<6 {
			for _ in 0..<10 {
				now += 1
				_ = state.sample(now: now, mediaTime: position, playing: false, waiting: true)
			}
			now += 1
			position += 1
			_ = state.sample(now: now, mediaTime: position, playing: true, waiting: false)
		}
		#expect(state.recoveryWait == 60)
		#expect(state.retryDelay() == nil)
	}

	@Test func endNotificationMustBelongToTheCurrentPlayerItem() {
		let endedItem = AVPlayerItem(asset: AVMutableComposition())
		let replacementItem = AVPlayerItem(asset: AVMutableComposition())

		#expect(VideoPlayerManager.isCurrentPlaybackItem(endedItem, currentItem: endedItem))
		#expect(!VideoPlayerManager.isCurrentPlaybackItem(endedItem, currentItem: replacementItem))
		#expect(!VideoPlayerManager.isCurrentPlaybackItem(endedItem, currentItem: nil))
		#expect(!VideoPlayerManager.isCurrentPlaybackItem(nil, currentItem: nil))
	}
}
