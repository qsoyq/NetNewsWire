import AVFoundation
import Testing
@testable import NetNewsWire

@MainActor @Suite struct VideoPlayerManagerTests {

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

	@Test func endNotificationMustBelongToTheCurrentPlayerItem() {
		let endedItem = AVPlayerItem(asset: AVMutableComposition())
		let replacementItem = AVPlayerItem(asset: AVMutableComposition())

		#expect(VideoPlayerManager.isCurrentPlaybackItem(endedItem, currentItem: endedItem))
		#expect(!VideoPlayerManager.isCurrentPlaybackItem(endedItem, currentItem: replacementItem))
		#expect(!VideoPlayerManager.isCurrentPlaybackItem(endedItem, currentItem: nil))
		#expect(!VideoPlayerManager.isCurrentPlaybackItem(nil, currentItem: nil))
	}
}
