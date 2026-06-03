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

@MainActor
final class VideoPlayerManager: NSObject {

	static let shared = VideoPlayerManager()

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoPlayerManager")

	weak var coordinator: SceneCoordinator?

	private var player: AVPlayer?
	private var playerViewController: AVPlayerViewController?
	private var currentArticleID: String?
	private(set) var isPiPActive = false
	private var isRestoringUserInterface = false

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
		isPiPActive = false
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
		endObserver = NotificationCenter.default.addObserver(
			forName: .AVPlayerItemDidPlayToEndTime,
			object: player?.currentItem,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.handleVideoEnded()
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

		// PiP active: try seamless continuation if enabled
		if isPiPActive && AppDefaults.shared.pipAutoPlayNextVideo {
			if let nextArticle = nextArticleForPlayback(coordinator),
			   let nextVideoURL = Self.extractFirstVideoURL(from: nextArticle.body) {
				Self.logger.info("Swapping to next article video in PiP")

				let nextItem = AVPlayerItem(url: nextVideoURL)
				player?.replaceCurrentItem(with: nextItem)
				player?.play()

				currentArticleID = nextArticle.articleID
				observePlayerItemEnd()

				coordinator.selectArticle(nextArticle, animations: [.navigation, .scroll])
				return
			}
		}

		// Not in PiP or PiP auto-next disabled: use regular auto-next
		if AppDefaults.shared.autoGotoNextAfterVideo {
			coordinator.selectNextArticle()
		}

		finishPlaybackSession()
	}

	private func nextArticleForPlayback(_ coordinator: SceneCoordinator) -> Article? {
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
}

// MARK: - AVPlayerViewControllerDelegate

extension VideoPlayerManager: AVPlayerViewControllerDelegate {

	nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
		Task { @MainActor in
			isPiPActive = true
			Self.logger.info("PiP started")
		}
	}

	nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
		Task { @MainActor in
			isPiPActive = false
			Self.logger.info("PiP stopped")
		}
	}

	nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: any Error) {
		Task { @MainActor in
			isPiPActive = false
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
