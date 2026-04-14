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

@MainActor
final class VideoPlayerManager: NSObject {

	static let shared = VideoPlayerManager()

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoPlayerManager")

	weak var coordinator: SceneCoordinator?

	private var player: AVPlayer?
	private var playerViewController: AVPlayerViewController?
	private var currentArticleID: String?
	private(set) var isPiPActive = false

	private var endObserver: NSObjectProtocol?

	override init() {
		super.init()
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
	}

	// MARK: - Public API

	func play(url: URL, articleID: String, from presenter: UIViewController) {
		let item = AVPlayerItem(url: url)

		if let player {
			player.replaceCurrentItem(with: item)
		} else {
			player = AVPlayer(playerItem: item)
		}

		currentArticleID = articleID
		observePlayerItemEnd()

		if let playerViewController, playerViewController.presentingViewController != nil {
			// Already presenting — just swap the item (handles PiP continuation too)
			player?.play()
			return
		}

		let vc = AVPlayerViewController()
		vc.player = player
		if #available(iOS 14.2, *) {
			vc.canStartPictureInPictureAutomaticallyFromInline = true
		}
		vc.delegate = self
		playerViewController = vc

		presenter.present(vc, animated: true) {
			self.player?.play()
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
		guard let coordinator else { return }

		// PiP active: try seamless continuation if enabled
		if isPiPActive && AppDefaults.shared.pipAutoPlayNextVideo {
			if let nextArticle = coordinator.nextArticle,
			   let nextVideoURL = Self.extractFirstVideoURL(from: nextArticle.body) {
				Self.logger.info("Swapping to next article video in PiP")

				let nextItem = AVPlayerItem(url: nextVideoURL)
				player?.replaceCurrentItem(with: nextItem)
				player?.play()

				currentArticleID = nextArticle.articleID
				observePlayerItemEnd()

				coordinator.selectNextArticle()
				return
			}
		}

		// Not in PiP or PiP auto-next disabled: use regular auto-next
		if AppDefaults.shared.autoGotoNextAfterVideo {
			coordinator.selectNextArticle()
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

	nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
		Task { @MainActor in
			Self.logger.info("PiP restore requested")
			completionHandler(true)
		}
	}

	nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
		Task { @MainActor in
			if !isPiPActive {
				player?.pause()
				removeEndObserver()
			}
		}
	}
}
