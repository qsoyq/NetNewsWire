import AVFoundation
import AVKit
import Articles
import RSParser
import Testing
import UIKit
import WebKit
import XCTest
@testable import Account
@testable import NetNewsWire

@MainActor @Suite struct VideoPlayerManagerTests {
	@Test func backgroundPlaybackHistorySurvivesArticleChanges() {
		let articles = ["a", "b", "c"].map { autoplayArticle($0) }
		var session = VideoAutoplaySession()
		session.begin(articles[0])
		for article in articles {
			session.prepare(article)
			session.recordProgress()
		}
		for article in articles {
			#expect(session.contains(article))
		}
		#expect(!session.contains(autoplayArticle("unplayed")))
	}

	@Test func preparingAnUnavailableVideoDoesNotAddItToHistory() {
		let first = autoplayArticle("first")
		let unavailable = autoplayArticle("unavailable")
		let next = autoplayArticle("next")
		var session = VideoAutoplaySession()
		session.begin(first)
		session.recordProgress()
		session.prepare(unavailable)
		#expect(session.contains(unavailable), "A loading item must not be replaced by page autoplay")
		session.prepare(next)
		#expect(!session.contains(unavailable), "A failed or skipped item has no playback history")
		#expect(session.contains(first))
		#expect(session.contains(next))
	}

	@Test func playbackHistoryIsScopedToAccountAndSession() {
		let article = autoplayArticle("shared-id")
		var session = VideoAutoplaySession()
		session.begin(article)
		session.recordProgress()
		#expect(!session.contains(autoplayArticle("shared-id", accountID: "another-account")))
		session.begin(autoplayArticle("new-session"))
		#expect(!session.contains(article))
		session.finish()
		#expect(!session.contains(autoplayArticle("new-session")))
	}

	@Test func readStatusDoesNotCountAsPlayback() {
		let article = autoplayArticle("read-article")
		article.status.read = true
		#expect(!VideoAutoplaySession().contains(article))
	}

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

@MainActor final class VideoAutoplayRestorationTests: XCTestCase {
	func testClosingPiPEndsAutoplaySession() async throws {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		let presenter = UIViewController()
		window.rootViewController = presenter
		window.makeKeyAndVisible()
		let manager = VideoPlayerManager()
		defer {
			manager.stop()
			window.isHidden = true
			previous?.makeKeyAndVisible()
		}
		let article = autoplayArticle("pip-close")
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "video-preview", withExtension: "mp4"))
		manager.play(url: fixture, article: article, from: presenter)
		let controller = try XCTUnwrap(presenter.presentedViewController as? AVPlayerViewController)
		try await waitUntil { !controller.isBeingPresented }
		manager.playerViewControllerWillStartPictureInPicture(controller)
		await withCheckedContinuation { continuation in
			presenter.dismiss(animated: false) { continuation.resume() }
		}
		await Task.yield()
		XCTAssertTrue(manager.hasPlayback(in: article))
		manager.playerViewControllerDidStopPictureInPicture(controller)
		try await waitUntil { !manager.hasPlayback(in: article) }
		XCTAssertNil(controller.player?.currentItem)
		let next = autoplayArticle("new-playback")
		manager.play(url: fixture, article: next, from: presenter)
		let nextController = try XCTUnwrap(presenter.presentedViewController as? AVPlayerViewController)
		try await waitUntil { !nextController.isBeingPresented }
		manager.playerViewControllerDidStopPictureInPicture(controller)
		await Task.yield()
		XCTAssertTrue(manager.hasPlayback(in: next), "An old PiP callback must not end a new session")
		XCTAssertNotNil(nextController.player?.currentItem)
	}

	func testPiPReturnPreservesPausedItemAndConsumesArticleAutoplay() async throws {
		let settings: [MediaSetting] = [.autoplayVideo, .pipAutoPlayNextVideo, .useNativeVideoPlayer,
			.hideArticleBodyMedia, .prefetchNextArticleContent, .loadVideoFirstFramePreview]
		let originals = settings.map { AppDefaults.shared[keyPath: $0.keyPath] }
		let manager = VideoPlayerManager.shared
		defer {
			manager.stop()
			for (setting, value) in zip(settings, originals) {
				AppDefaults.shared[keyPath: setting.keyPath] = value
			}
		}
		AppDefaults.shared.autoplayVideo = false
		AppDefaults.shared.pipAutoPlayNextVideo = true
		AppDefaults.shared.useNativeVideoPlayer = true
		AppDefaults.shared.hideArticleBodyMedia = false
		AppDefaults.shared.prefetchNextArticleContent = false
		AppDefaults.shared.loadVideoFirstFramePreview = false
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let coordinator = try XCTUnwrap(scene.coordinator)
		let window = try XCTUnwrap(scene.window)
		let root = try XCTUnwrap(window.rootViewController as? RootSplitViewController)
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		let token = UUID().uuidString
		let feed = account.createFeed(with: "Autoplay restoration test", url: "https://example.invalid/\(token)",
			feedID: "https://example.invalid/\(token)", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		defer {
			manager.stop()
			coordinator.selectArticle(nil)
			coordinator.navigateToTimeline()
			coordinator.selectFeed(nil)
			AccountManager.shared.deleteAccount(account)
		}
		let items = Set((0..<2).map { index in
			ParsedItem(syncServiceID: nil, uniqueID: "\(token)-\(index)", feedURL: feed.url,
				url: nil, externalURL: nil, title: "Playback article \(index)", language: nil,
				contentHTML: "<video src=\"https://example.invalid/\(token)-\(index).mp4\" controls preload=\"none\"></video>",
				contentText: nil, markdown: nil, summary: nil, imageURL: nil, bannerImageURL: nil,
				datePublished: Date().addingTimeInterval(Double(-index)), dateModified: nil, authors: nil, tags: nil, attachments: nil)
		})
		_ = await account.updateAsync(feedID: feed.feedID, parsedItems: items, deleteOlder: false)
		let timeline = try XCTUnwrap(root.viewController(for: .supplementary) as? MainTimelineModernViewController)
		timeline.loadViewIfNeeded()
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			coordinator.discloseFeed(feed, initialLoad: true, animations: []) { continuation.resume() }
		}
		try await waitUntil { coordinator.articles.count == 2 }
		let articles = coordinator.articles
		coordinator.selectArticle(articles[0], animations: [.navigation])
		let articleController = try XCTUnwrap(root.viewController(for: .secondary) as? ArticleViewController)
		try await waitUntil { articleController.viewIfLoaded?.window != nil && !coordinator.isArticleViewControllerPending }
		let pager = try XCTUnwrap(articleController.children.first { $0 is UIPageViewController } as? UIPageViewController)
		let reader = try XCTUnwrap(pager.viewControllers?.first as? WebViewController)
		try await waitUntil { reader.isArticleDocumentReady }
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "video-preview", withExtension: "mp4"))
		manager.play(url: fixture, article: articles[1], from: reader)
		let playerController = try XCTUnwrap(reader.presentedViewController as? AVPlayerViewController)
		let player = try XCTUnwrap(playerController.player)
		let item = try XCTUnwrap(player.currentItem)
		try await waitUntil { !playerController.isBeingPresented && item.status == .readyToPlay }
		player.pause()
		await player.seek(to: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
		let position = player.currentTime().seconds
		XCTAssertGreaterThan(position, 0)

		let preloadedReader = try XCTUnwrap(articleController.pageViewController(pager, viewControllerAfter: reader) as? WebViewController)
		preloadedReader.loadViewIfNeeded()
		try await waitUntil { preloadedReader.isArticleDocumentReady }
		preloadedReader.startNativeVideoDirectly()
		XCTAssertFalse(preloadedReader.nativeAutoplayStarted, "A hidden neighbor must not consume a future opening")
		AppDefaults.shared.autoplayVideo = true
		AppDefaults.shared.pipAutoPlayNextVideo = true
		// Drive the AVKit callbacks to reproduce restoration ordering without OS PiP support.
		manager.playerViewControllerWillStartPictureInPicture(playerController)
		await withCheckedContinuation { continuation in
			reader.dismiss(animated: false) { continuation.resume() }
		}
		manager.synchronizeArticleAfterForeground()
		try await waitUntil { reader.article == articles[1] && reader.isArticleDocumentReady }
		XCTAssertTrue(reader.nativeAutoplayStarted)
		for autoplay in [false, true] {
			for pipNext in [false, true] {
				AppDefaults.shared.autoplayVideo = autoplay
				AppDefaults.shared.pipAutoPlayNextVideo = pipNext
				reader.resetNativeVideoAutoplay()
				reader.startNativeVideoDirectly()
				XCTAssertTrue(reader.nativeAutoplayStarted, "Restoration consumes autoplay with either switch setting")
				XCTAssertTrue(player.currentItem === item)
				XCTAssertEqual(player.rate, 0)
			}
		}
		manager.playerViewControllerDidStopPictureInPicture(playerController)
		let restored = await withCheckedContinuation { continuation in
			manager.playerViewController(playerController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { success in
				continuation.resume(returning: success)
			})
		}
		XCTAssertTrue(restored)
		XCTAssertTrue(player.currentItem === item)
		XCTAssertEqual(player.rate, 0, "Returning from PiP must respect an explicit pause")
		XCTAssertEqual(player.currentTime().seconds, position, accuracy: 0.05)
		XCTAssertFalse(try XCTUnwrap(reader.view.subviews.first as? WKWebView).isHidden)
		manager.stop()
		try await waitUntil { playerController.presentingViewController == nil && reader.viewIfLoaded?.window != nil }
		reader.resumeNativeVideoAfterPageTransition()
		XCTAssertTrue(reader.nativeAutoplayStarted, "Closing the restored player must not create another autoplay opportunity")
		XCTAssertNil(reader.presentedViewController)
		XCTAssertNil(root.presentedViewController)
		let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
			window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
		})
		attachment.name = "Restored Article After Closing Paused Player"
		attachment.lifetime = .keepAlways
		add(attachment)

		AppDefaults.shared.autoplayVideo = false
		await withCheckedContinuation { continuation in
			pager.setViewControllers([preloadedReader], direction: .forward, animated: false) { _ in continuation.resume() }
		}
		XCTAssertTrue(articleController.isCurrentWebViewController(preloadedReader))
		preloadedReader.startNativeVideoDirectly()
		XCTAssertFalse(preloadedReader.nativeAutoplayStarted, "A cached neighbor first opened after playback ends remains eligible")
		coordinator.selectArticle(articles[0])
		try await waitUntil { preloadedReader.article == articles[0] && preloadedReader.isArticleDocumentReady }
		coordinator.selectArticle(articles[1])
		try await waitUntil { preloadedReader.article == articles[1] && preloadedReader.isArticleDocumentReady }
		XCTAssertFalse(preloadedReader.nativeAutoplayStarted, "A fresh opening after playback ends retains normal autoplay eligibility")

		manager.play(url: fixture, article: articles[1], from: preloadedReader)
		let closingController = try XCTUnwrap(preloadedReader.presentedViewController as? AVPlayerViewController)
		try await waitUntil { !closingController.isBeingPresented }
		manager.playerViewControllerWillStartPictureInPicture(closingController)
		await withCheckedContinuation { continuation in
			preloadedReader.dismiss(animated: false) { continuation.resume() }
		}
		preloadedReader.startNativeVideoDirectly()
		XCTAssertTrue(preloadedReader.nativeAutoplayStarted)
		coordinator.navigateToTimeline()
		try await waitUntil { coordinator.currentArticle == nil && !coordinator.isArticleViewControllerShowing }
		XCTAssertFalse(preloadedReader.nativeAutoplayStarted, "Returning to the timeline ends this opening even during PiP")
		manager.playerViewControllerDidStopPictureInPicture(closingController)
		try await waitUntil { !manager.hasPlayback(in: articles[1]) }
		coordinator.selectArticle(articles[1], animations: [.navigation])
		try await waitUntil { coordinator.isArticleViewControllerShowing && !coordinator.isArticleViewControllerPending }
		XCTAssertFalse(preloadedReader.nativeAutoplayStarted, "Reopening the same retained page after PiP closes is a fresh opening")

		coordinator.selectArticle(articles[0])
		try await waitUntil { preloadedReader.article == articles[0] && preloadedReader.isArticleDocumentReady }
		let swipeReader = try XCTUnwrap(articleController.pageViewController(pager, viewControllerAfter: preloadedReader) as? WebViewController)
		swipeReader.loadViewIfNeeded()
		try await waitUntil { swipeReader.isArticleDocumentReady }
		manager.play(url: fixture, article: articles[1], from: preloadedReader)
		let swipePlayerController = try XCTUnwrap(preloadedReader.presentedViewController as? AVPlayerViewController)
		let swipePlayer = try XCTUnwrap(swipePlayerController.player)
		let swipeItem = try XCTUnwrap(swipePlayer.currentItem)
		try await waitUntil { !swipePlayerController.isBeingPresented && swipeItem.status == .readyToPlay }
		swipePlayer.pause()
		manager.playerViewControllerWillStartPictureInPicture(swipePlayerController)
		await withCheckedContinuation { continuation in
			preloadedReader.dismiss(animated: false) { continuation.resume() }
		}
		articleController.pageViewController(pager, willTransitionTo: [swipeReader])
		await withCheckedContinuation { continuation in
			pager.setViewControllers([swipeReader], direction: .forward, animated: false) { _ in continuation.resume() }
		}
		XCTAssertEqual(coordinator.currentArticle, articles[0])
		XCTAssertFalse(swipeReader.nativeAutoplayStarted)
		articleController.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [preloadedReader], transitionCompleted: true)
		XCTAssertEqual(coordinator.currentArticle, articles[1])
		XCTAssertTrue(swipeReader.nativeAutoplayStarted, "A completed swipe must consume existing PiP playback after selection synchronizes")
		let swipeRestored = await withCheckedContinuation { continuation in
			manager.playerViewController(swipePlayerController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { success in
				continuation.resume(returning: success)
			})
		}
		XCTAssertTrue(swipeRestored)
		manager.playerViewControllerDidStopPictureInPicture(swipePlayerController)
		await Task.yield()
		XCTAssertTrue(swipePlayer.currentItem === swipeItem)
		XCTAssertEqual(swipePlayer.rate, 0)
		manager.stop()
		try await waitUntil { swipePlayerController.presentingViewController == nil && swipeReader.viewIfLoaded?.window != nil }
		swipeReader.resumeNativeVideoAfterPageTransition()
		XCTAssertTrue(swipeReader.nativeAutoplayStarted, "Restore-before-stop ordering must not create a second autoplay opportunity")
		XCTAssertNil(swipeReader.presentedViewController)
		XCTAssertNil(root.presentedViewController)
	}

	private func waitUntil(_ predicate: () -> Bool) async throws {
		for _ in 0..<400 {
			if predicate() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		XCTFail("Timed out waiting for playback restoration")
		throw CocoaError(.coderInvalidValue)
	}
}

private func autoplayArticle(_ id: String, accountID: String = "autoplay-test") -> Article {
	Article(accountID: accountID, articleID: id, feedID: "feed", uniqueID: id,
		title: id, contentHTML: nil, contentText: nil, markdown: nil, url: nil, externalURL: nil,
		summary: nil, imageURL: nil, datePublished: nil, dateModified: nil, authors: nil,
		status: ArticleStatus(articleID: id, read: false, dateArrived: Date()))
}
