//
//  VideoPlayerManager.swift
//  NetNewsWire-iOS
//
//  Created by NetNewsWire on 2026/04/14.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import UIKit
import AVKit
import os
import Articles
import Account

@MainActor
final class VideoPlayerManager: NSObject {

	static let shared = VideoPlayerManager()

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoPlayerManager")

	weak var coordinator: SceneCoordinator?

	private var player: AVPlayer?
	private var playerViewController: AVPlayerViewController?
	private var currentArticleID: String?
	private var playbackArticles = [Article]()
	nonisolated private let pictureInPictureState = OSAllocatedUnfairLock(initialState: false)
	private var isRestoringUserInterface = false

	nonisolated var isPiPActive: Bool {
		pictureInPictureState.withLock { $0 }
	}

	nonisolated private func setPictureInPictureActive(_ active: Bool) {
		pictureInPictureState.withLock { $0 = active }
	}

	private var endObserver: NSObjectProtocol?

	override init() {
		super.init()
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
	}

	// MARK: - Public API

	func play(url: URL, articleID: String, from presenter: UIViewController) {
		let item = AVPlayerItem(url: url)
		let player = player ?? AVPlayer()
		self.player = player
		player.replaceCurrentItem(with: item)

		currentArticleID = articleID
		if let coordinator {
			playbackArticles = coordinator.articles
			if let article = coordinator.articleFor(articleID) {
				coordinator.retainArticleForVideoPlayback(article)
			}
		}
		observePlayerItemEnd()

		let playerViewController = configuredPlayerViewController()
		guard playerViewController.presentingViewController == nil, !isPiPActive else {
			player.play()
			return
		}

		presenter.present(playerViewController, animated: true) {
			player.play()
		}
	}

	func stop() {
		player?.pause()
		player?.replaceCurrentItem(with: nil)
		playerViewController?.dismiss(animated: true)
		playerViewController = nil
		removeEndObserver()
		currentArticleID = nil
		playbackArticles.removeAll()
		setPictureInPictureActive(false)
		isRestoringUserInterface = false
	}

	// MARK: - Video URL Extraction

	/// Extracts the first non-GIF <video> or <source> src HTTP URL from HTML.
	static func extractFirstVideoURL(from html: String?) -> URL? {
		guard let html else { return nil }

		// Extract src from <video> and <source> tags
		let srcPattern = "<(?:video|source)\\b[^>]*?\\bsrc\\s*=\\s*\"([^\"]+)\""
		guard let srcRegex = try? NSRegularExpression(pattern: srcPattern, options: .caseInsensitive) else {
			return nil
		}

		let nsHTML = html as NSString
		let matches = srcRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

		for match in matches {
			guard match.numberOfRanges >= 2 else { continue }
			let urlRange = match.range(at: 1)
			guard let swiftRange = Range(urlRange, in: html) else { continue }

			let rawURL = String(html[swiftRange])
				.replacingOccurrences(of: "&amp;", with: "&")

			// Check if this video tag has nnwAnimatedGIF class
			// Look backwards from the match to find the containing <video> tag
			let matchStart = match.range(at: 0).location
			let precedingRange = NSRange(location: max(0, matchStart - 500), length: min(500, matchStart))
			let precedingText = nsHTML.substring(with: precedingRange)
			if precedingText.contains("nnwAnimatedGIF") {
				continue
			}

			// Skip non-HTTP URLs
			guard rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://") else {
				continue
			}

			guard let url = URL(string: rawURL) else { continue }
			return url
		}

		return nil
	}

	// MARK: - Private

	private func configuredPlayerViewController() -> AVPlayerViewController {
		if let playerViewController {
			playerViewController.player = player
			return playerViewController
		}

		let playerViewController = AVPlayerViewController()
		playerViewController.player = player
		playerViewController.allowsPictureInPicturePlayback = true
		playerViewController.delegate = self
		if #available(iOS 14.2, *) {
			playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
		}
		self.playerViewController = playerViewController
		return playerViewController
	}

	private func observePlayerItemEnd() {
		removeEndObserver()
		guard let item = player?.currentItem else {
			return
		}
		endObserver = NotificationCenter.default.addObserver(
			forName: .AVPlayerItemDidPlayToEndTime,
			object: item,
			queue: .main
		) { [weak self, weak item] _ in
			Task { @MainActor in
				guard let self, Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
					return
				}
				self.handleVideoEnded()
			}
		}
	}

	private func removeEndObserver() {
		if let endObserver {
			NotificationCenter.default.removeObserver(endObserver)
		}
		endObserver = nil
	}

	private func handleVideoEnded() {
		guard let coordinator else {
			finishPlaybackSession()
			return
		}

		let pipActive = isPiPActive
		let pipAutoPlayNextVideo = AppDefaults.shared.pipAutoPlayNextVideo
		let continuesInPiP = pipActive && pipAutoPlayNextVideo
		let nextArticle = continuesInPiP ? nextArticleForPlayback(coordinator) : nil
		let nextVideoURL = nextArticle.flatMap { Self.extractFirstVideoURL(from: $0.body) }
		let action = Self.playbackEndAction(
			isPiPActive: pipActive,
			pipAutoPlayNextVideo: pipAutoPlayNextVideo,
			autoGotoNextAfterVideo: AppDefaults.shared.autoGotoNextAfterVideo,
			hasNextVideo: nextVideoURL != nil
		)

		switch action {
		case .playNextVideo:
			if let nextArticle, let nextVideoURL {
				Self.logger.info("Swapping to next article video in PiP")
				appDelegate.resumeDatabaseProcessingIfNecessary()
				NotificationActionLog.log(.info, operation: "PiP auto-next", message: "Selecting next article \(nextArticle.articleID); isSuspended=\(AccountManager.shared.isSuspended); appState=\(UIApplication.shared.applicationState.rawValue)")

				let nextItem = AVPlayerItem(url: nextVideoURL)
				player?.replaceCurrentItem(with: nextItem)
				player?.play()

				currentArticleID = nextArticle.articleID
				observePlayerItemEnd()

				coordinator.retainArticleForVideoPlayback(nextArticle)
				if UIApplication.shared.applicationState == .active {
					coordinator.selectArticle(nextArticle, animations: [.navigation, .scroll])
				} else {
					markArticles(Set([nextArticle]), statusKey: .read, flag: true)
				}
				return
			}
		case .selectNextArticle:
			appDelegate.resumeDatabaseProcessingIfNecessary()
			coordinator.selectNextArticle()
		case .finish:
			break
		}

		finishPlaybackSession()
	}

	enum PlaybackEndAction: Equatable {
		case playNextVideo
		case selectNextArticle
		case finish
	}

	static func playbackEndAction(isPiPActive: Bool, pipAutoPlayNextVideo: Bool, autoGotoNextAfterVideo: Bool, hasNextVideo: Bool) -> PlaybackEndAction {
		if isPiPActive && pipAutoPlayNextVideo {
			// The displayed article can lag behind background playback. Never navigate
			// from that stale selection when the playback queue has ended.
			return hasNextVideo ? .playNextVideo : .finish
		}
		return autoGotoNextAfterVideo ? .selectNextArticle : .finish
	}

	static func isCurrentPlaybackItem(_ item: AVPlayerItem?, currentItem: AVPlayerItem?) -> Bool {
		guard let item else {
			return false
		}
		return item === currentItem
	}

	private func nextArticleForPlayback(_ coordinator: SceneCoordinator) -> Article? {
		if let currentArticleID,
		   let index = playbackArticles.firstIndex(where: { $0.articleID == currentArticleID }) {
			return index + 1 < playbackArticles.count ? playbackArticles[index + 1] : nil
		}
		if let currentArticleID, coordinator.currentArticle?.articleID != currentArticleID, let article = coordinator.articleFor(currentArticleID) {
			return coordinator.findNextArticle(article)
		}
		return coordinator.nextArticle
	}

	private func finishPlaybackSession() {
		player?.pause()
		player?.replaceCurrentItem(with: nil)
		removeEndObserver()
		currentArticleID = nil
		playbackArticles.removeAll()

		if !isPiPActive {
			playerViewController?.dismiss(animated: true)
			playerViewController = nil
		}
	}

	private func restoreUserInterface(completionHandler: @escaping @Sendable (Bool) -> Void) {
		guard !isRestoringUserInterface else {
			completionHandler(false)
			return
		}

		guard let playerViewController, playerViewController.presentingViewController == nil else {
			completionHandler(true)
			return
		}

		isRestoringUserInterface = true

		let finish: (Bool) -> Void = { restored in
			self.isRestoringUserInterface = false
			completionHandler(restored)
		}

		guard let coordinator else {
			finish(false)
			return
		}

		if let currentArticleID, let article = coordinator.articleFor(currentArticleID) {
			coordinator.selectArticle(article, animations: [.navigation, .scroll])
		}

		guard let presenter = coordinator.videoPlayerPresenter else {
			finish(false)
			return
		}

		presenter.present(playerViewController, animated: true) {
			finish(true)
		}
	}

	func synchronizeArticleAfterForeground() {
		guard isPiPActive, let currentArticleID, let coordinator,
		      let article = coordinator.articleFor(currentArticleID) else {
			return
		}
		coordinator.selectArticle(article, animations: [.navigation, .scroll])
	}
}

// MARK: - AVPlayerViewControllerDelegate

extension VideoPlayerManager: AVPlayerViewControllerDelegate {

	nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
		setPictureInPictureActive(true)
		Task { @MainActor in
			Self.logger.info("PiP started")
		}
	}

	nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
		setPictureInPictureActive(false)
		Task { @MainActor in
			Self.logger.info("PiP stopped")
			appDelegate.suspendApplicationIfNeededAfterPlayback()
		}
	}

	nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: any Error) {
		setPictureInPictureActive(false)
		Task { @MainActor in
			Self.logger.error("PiP failed to start: \(error.localizedDescription)")
		}
	}

	nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
		return true
	}

	nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
		Task { @MainActor in
			Self.logger.info("PiP restore requested")
			restoreUserInterface(completionHandler: completionHandler)
		}
	}

	nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
		Task { @MainActor in
			if !isPiPActive, !isRestoringUserInterface {
				finishPlaybackSession()
			}
		}
	}
}
