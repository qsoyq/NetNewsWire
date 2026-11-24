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
import ErrorLog
import RSWeb

@MainActor
final class VideoPlayerManager: NSObject {

	static let shared = VideoPlayerManager()

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoPlayerManager")

	weak var coordinator: SceneCoordinator?

	private var player: AVPlayer?
	private var playerViewController: AVPlayerViewController?
	private lazy var swipeDismissGesture = VideoSwipeDismissGesture { [weak self] in
		self?.dismissByUserSwipe()
	}
	private var currentArticleID: String?
	private var playbackArticles = [Article]()
	private var autoplaySession = VideoAutoplaySession()
	private struct PictureInPictureState {
		var isActive = false
		var restorationRequested = false
	}
	nonisolated private let pictureInPictureState = OSAllocatedUnfairLock(initialState: PictureInPictureState())
	private var isRestoringUserInterface = false

	nonisolated var isPiPActive: Bool {
		pictureInPictureState.withLock { $0.isActive }
	}

	nonisolated private func setPictureInPictureActive(_ active: Bool) {
		pictureInPictureState.withLock {
			$0.isActive = active
			if active { $0.restorationRequested = false }
		}
	}

	private var endObserver: NSObjectProtocol?
	private var playerItemStatusObservation: NSKeyValueObservation?
	private var playerTimeControlObservation: NSKeyValueObservation?
	private var playbackDiagnosticObservers = [NSObjectProtocol]()
	private var playbackRequestID = 0
	private var playbackRequestStartUptime: TimeInterval = 0
	private var playbackSessionID = UUID()
	private var playbackURL: URL?
	private var playbackIndex: Int?
	private var pendingPlaybackArticle: Article?
	private var recovery = VideoPlaybackRecovery()
	private var consecutiveFailures = 0
	private var attemptResolved = false
	private var playbackRequested = false
	private var resumePosition: Double = 0
	private var pendingSeekPosition: Double?
	private var seekingForRecovery = false
	private var audioInterrupted = false
	private var pendingVideoEnd = false
	private var recoveryTask: Task<Void, Never>?
	private var retryTask: Task<Void, Never>?
	private var interruptionObserver: NSObjectProtocol?
	private var settingsObserver: NSObjectProtocol?
	private var ignoredPauseRequestID: Int?

	override init() {
		super.init()
		settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				guard let self, !AppDefaults.shared.pipAutoPlayNextVideo else {
					return
				}
				self.pendingVideoEnd = false
				if self.retryTask != nil { self.suspendRecovery(reason: "setting-disabled") }
			}
		}
		interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
			let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
			let options = AVAudioSession.InterruptionOptions(rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
			let shouldResume = options.contains(.shouldResume)
			Task { @MainActor in
				self?.handleAudioInterruption(began: began, shouldResume: shouldResume)
			}
		}
		do {
			try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
		} catch {
			let error = error as NSError
			ArticleMediaLog.log(.error, operation: "Native video audio session", message: "domain=\(error.domain) code=\(error.code)")
		}
	}

	isolated deinit {
		recoveryTask?.cancel()
		retryTask?.cancel()
		if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
		if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
	}

	// MARK: - Public API

	func hasPlayback(in article: Article) -> Bool {
		autoplaySession.contains(article)
	}

	func play(url: URL, article: Article, from presenter: UIViewController) {
		cancelRecovery()
		autoplaySession.begin(article)
		let articleID = article.articleID
		playbackSessionID = UUID()
		playbackURL = url
		recovery = VideoPlaybackRecovery()
		consecutiveFailures = 0
		pendingPlaybackArticle = nil
		resumePosition = 0
		let item = AVPlayerItem(url: url)
		let player = player ?? AVPlayer()
		self.player = player
		let replacesExistingItem = player.currentItem != nil

		currentArticleID = articleID
		playbackIndex = nil
		if let coordinator {
			playbackArticles = coordinator.articles
			coordinator.retainArticleForVideoPlayback(article)
			playbackIndex = playbackArticles.firstIndex {
				$0.articleID == article.articleID && $0.accountID == article.accountID
			}
		}
		installPlaybackItem(item)

		let playerViewController = configuredPlayerViewController()
		let cacheHit = AppDefaults.shared.cacheVideoContent && VideoCacheDatabase.shared.hasCachedData(for: url.absoluteString)
		ArticleMediaLog.log(.info, operation: "Native video request", message: "request=\(playbackRequestID) articleID=\(articleID) source=\(ArticleMediaLog.urlDescription(url.absoluteString, level: .info)) cache_hit=\(cacheHit) replaces_item=\(replacesExistingItem) presenter_visible=\(presenter.viewIfLoaded?.window != nil) player_presented=\(playerViewController.presentingViewController != nil) player_dismissing=\(playerViewController.isBeingDismissed) pip=\(isPiPActive)")
		ArticleMediaLog.log(.debug, operation: "Native video URL", message: "request=\(playbackRequestID) articleID=\(articleID) url=\(url.absoluteString)")
		guard playerViewController.presentingViewController == nil, !isPiPActive else {
			requestPlayback(for: item)
			logPlaybackDiagnostics(for: item, event: "play-existing-presentation")
			return
		}

		let sessionID = playbackSessionID
		presenter.present(playerViewController, animated: true) { [weak self, weak item] in
			guard let self, let item, self.playbackSessionID == sessionID,
				Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
				return
			}
			self.requestPlayback(for: item)
			self.logPlaybackDiagnostics(for: item, event: "presentation-completed")
		}
	}

	func stop() {
		cancelRecovery()
		autoplaySession.finish()
		playbackSessionID = UUID()
		pendingPlaybackArticle = nil
		playbackIndex = nil
		playbackURL = nil
		if let item = player?.currentItem {
			logPlaybackDiagnostics(for: item, event: "stop")
		}
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
		guard let html else {
			return nil
		}

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

	// MARK: - Playback Recovery

	private var canContinuePlayback: Bool {
		isPiPActive && AppDefaults.shared.pipAutoPlayNextVideo
			&& coordinator != nil && coordinator?.isArticleQuickSettingsPresented == false
	}

	private var canRecoverPlayback: Bool {
		canContinuePlayback && !audioInterrupted
	}

	private func handleAudioInterruption(began: Bool, shouldResume: Bool) {
		audioInterrupted = began
		if began {
			suspendRecovery(reason: "audio-interruption")
		} else if shouldResume {
			resumePendingVideoEnd()
		}
	}

	private func resumePendingVideoEnd() {
		guard pendingVideoEnd, !audioInterrupted, playbackRequested else {
			return
		}
		pendingVideoEnd = false
		guard canContinuePlayback else {
			finishPlaybackSession()
			return
		}
		handleVideoEnded()
	}

	private func handleExplicitPlaybackResume() {
		audioInterrupted = false
		playbackRequested = true
		if pendingVideoEnd {
			resumePendingVideoEnd()
		} else if attemptResolved, recovery.isSuspended, canRecoverPlayback, NetworkMonitor.shared.isConnected, let url = playbackURL {
			// An explicit Play after recovery stopped starts a new user-authorized attempt.
			recovery = VideoPlaybackRecovery()
			consecutiveFailures = 0
			let replacement = AVPlayerItem(url: url)
			installPlaybackItem(replacement, restoring: resumePosition)
			requestPlayback(for: replacement)
		} else if !attemptResolved, recovery.isSuspended {
			recovery.resume(now: ProcessInfo.processInfo.systemUptime, mediaTime: player?.currentTime().seconds ?? 0)
		}
	}

	private func cancelRecovery() {
		pendingVideoEnd = false
		recoveryTask?.cancel()
		recoveryTask = nil
		retryTask?.cancel()
		retryTask = nil
		recovery.suspend()
		playbackRequested = false
		pendingSeekPosition = nil
		seekingForRecovery = false
	}

	private func installPlaybackItem(_ item: AVPlayerItem, restoring position: Double = 0) {
		cancelRecovery()
		attemptResolved = false
		ignoredPauseRequestID = nil
		recovery.startAttempt(now: ProcessInfo.processInfo.systemUptime)
		pendingSeekPosition = position > 0 && position.isFinite ? position : nil
		removeEndObserver()
		player?.replaceCurrentItem(with: item)
		observePlayerItemEnd(item)
		let sessionID = playbackSessionID
		let requestID = playbackRequestID
		recoveryTask = Task { @MainActor [weak self, weak item] in
			while !Task.isCancelled {
				do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
				guard !Task.isCancelled, let self, let item, self.playbackSessionID == sessionID,
					self.playbackRequestID == requestID,
					Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
					return
				}
				self.samplePlayback(item)
			}
		}
	}

	private func requestPlayback(for item: AVPlayerItem) {
		guard Self.isCurrentPlaybackItem(item, currentItem: player?.currentItem) else {
			return
		}
		playbackRequested = true
		if pendingSeekPosition != nil {
			if item.status == .readyToPlay { restorePlaybackPosition(for: item) }
		} else {
			player?.play()
		}
	}

	private func restorePlaybackPosition(for item: AVPlayerItem) {
		guard playbackRequested, let position = pendingSeekPosition, !attemptResolved else {
			return
		}
		pendingSeekPosition = nil
		let duration = item.duration.seconds
		guard duration.isFinite, position < duration, !item.seekableTimeRanges.isEmpty else {
			player?.play()
			return
		}
		seekingForRecovery = true
		let sessionID = playbackSessionID
		let requestID = playbackRequestID
		item.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
			Task { @MainActor in
				guard let self, let item, self.playbackSessionID == sessionID, self.playbackRequestID == requestID,
					!self.attemptResolved,
					Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
					return
				}
				self.seekingForRecovery = false
				guard self.canRecoverPlayback else {
					return
				}
				self.recovery.resetSample(now: ProcessInfo.processInfo.systemUptime, mediaTime: item.currentTime().seconds)
				self.player?.play()
			}
		}
	}

	private func samplePlayback(_ item: AVPlayerItem) {
		if !canRecoverPlayback, retryTask != nil { suspendRecovery(reason: "continuation-disabled") }
		guard !attemptResolved, playbackRequested else {
			return
		}
		if item.status == .failed {
			handlePlaybackFailure(item, reason: "item-failed")
			return
		}
		let playing = player?.timeControlStatus == .playing && !seekingForRecovery
		let waiting = player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
			|| pendingSeekPosition != nil || seekingForRecovery
		let sample = recovery.sample(now: ProcessInfo.processInfo.systemUptime, mediaTime: item.currentTime().seconds,
			playing: playing, waiting: waiting && canRecoverPlayback)
		switch sample {
		case .progress, .healthy:
			// Real progress supersedes a delayed or unpaired interruption notification.
			if audioInterrupted || recovery.isSuspended {
				audioInterrupted = false
				recovery.resume(now: ProcessInfo.processInfo.systemUptime, mediaTime: item.currentTime().seconds)
			}
			resumePosition = item.currentTime().seconds
			commitPlaybackProgress()
			if sample == .healthy { consecutiveFailures = 0 }
		case .timeout:
			if canRecoverPlayback { handlePlaybackFailure(item, reason: "no-progress-timeout") }
		case .none:
			break
		}
	}

	private func commitPlaybackProgress() {
		autoplaySession.recordProgress()
		guard let article = pendingPlaybackArticle, let coordinator else {
			return
		}
		pendingPlaybackArticle = nil
		appDelegate.resumeDatabaseProcessingIfNecessary()
		coordinator.retainArticleForVideoPlayback(article)
		if UIApplication.shared.applicationState == .active, !coordinator.isArticleQuickSettingsPresented {
			coordinator.selectArticle(article, animations: [.navigation, .scroll])
		} else {
			markArticles(Set([article]), statusKey: .read, flag: true)
		}
		ArticleMediaLog.log(.info, operation: "Native video recovery", message: "request=\(playbackRequestID) articleID=\(article.articleID) action=commit-progress")
	}

	private func suspendRecovery(reason: String) {
		retryTask?.cancel()
		retryTask = nil
		recovery.suspend()
		ArticleMediaLog.log(.info, operation: "Native video recovery", message: "request=\(playbackRequestID) action=suspend reason=\(reason)")
	}

	private func handlePlaybackFailure(_ item: AVPlayerItem, reason: String, error: NSError? = nil) {
		guard playbackRequested, !recovery.isSuspended, canRecoverPlayback,
			Self.isCurrentPlaybackItem(item, currentItem: player?.currentItem) else {
			return
		}
		let logErrors = (item.errorLog()?.events ?? []).map { ($0.errorDomain, $0.errorStatusCode) }
		let notFound = Self.isNotFound(error: error, logErrors: logErrors)
			|| Self.isNotFound(error: item.error as NSError?, logErrors: [])
		switch Self.playbackFailureAction(notFound: notFound, attemptResolved: attemptResolved,
			retryPending: retryTask != nil, isErrorLog: reason == "error-log") {
		case .skipNotFound:
			skipNotFoundVideo()
			return
		case .ignore:
			return
		case .recover:
			break
		}
		attemptResolved = true
		if player?.rate != 0 { ignoredPauseRequestID = playbackRequestID }
		player?.pause()
		guard NetworkMonitor.shared.isConnected else {
			suspendRecovery(reason: "offline")
			return
		}
		let delay = recovery.retryDelay()
		ArticleMediaLog.log(.warning, operation: "Native video recovery", message: "session=\(playbackSessionID) request=\(playbackRequestID) articleID=\(currentArticleID ?? "(nil)") reason=\(reason) retry=\(recovery.retries) action=\(delay == nil ? "exhausted" : "retry") consecutive_failures=\(consecutiveFailures)")
		guard let delay, let url = playbackURL else {
			consecutiveFailures += 1
			guard consecutiveFailures < 3 else {
				suspendRecovery(reason: "consecutive-failure-limit")
				return
			}
			guard let coordinator, let next = nextArticleForPlayback(coordinator),
				let nextURL = Self.extractFirstVideoURL(from: next.body) else {
				finishPlaybackSession()
				return
			}
			startNextVideo(next, url: nextURL)
			return
		}
		let sessionID = playbackSessionID
		let requestID = playbackRequestID
		retryTask = Task { @MainActor [weak self, weak item] in
			do { try await Task.sleep(for: .seconds(delay)) } catch { return }
			guard !Task.isCancelled, let self, let item, self.playbackSessionID == sessionID,
				self.playbackRequestID == requestID,
				Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
				return
			}
			guard self.canRecoverPlayback, NetworkMonitor.shared.isConnected else {
				self.suspendRecovery(reason: "retry-no-longer-eligible")
				return
			}
			self.retryTask = nil
			let replacement = AVPlayerItem(asset: AVURLAsset(url: url))
			self.installPlaybackItem(replacement, restoring: self.resumePosition)
			self.requestPlayback(for: replacement)
		}
	}

	enum PlaybackFailureAction: Equatable { case ignore, skipNotFound, recover }

	enum ExplicitZeroRateAction: Equatable {
		case ignore
		case failPlayback
		case pausePlayback
		case suspendRecovery
	}

	static func explicitZeroRateAction(
		itemStatus: AVPlayerItem.Status,
		hasItemError: Bool,
		playerRate: Float,
		ignoredPause: Bool,
		retryPending: Bool,
		seekingForRecovery: Bool,
		pendingVideoEnd: Bool,
		audioInterrupted: Bool
	) -> ExplicitZeroRateAction {
		if ignoredPause {
			return .ignore
		}
		if itemStatus == .failed || hasItemError {
			return .failPlayback
		}
		guard playerRate == 0 else {
			return .ignore
		}
		if retryPending || seekingForRecovery {
			return .suspendRecovery
		}
		if itemStatus == .readyToPlay || pendingVideoEnd || audioInterrupted {
			return .pausePlayback
		}
		return .ignore
	}

	static func playbackFailureAction(notFound: Bool, attemptResolved: Bool, retryPending: Bool, isErrorLog: Bool) -> PlaybackFailureAction {
		// A late 404 can replace a pending retry, but a consumed attempt cannot advance twice.
		guard !attemptResolved || retryPending else {
			return .ignore
		}
		if notFound { return .skipNotFound }
		// A non-fatal error-log entry alone must not start ordinary recovery.
		return !attemptResolved && !isErrorLog ? .recover : .ignore
	}

	static func isNotFound(error: NSError?, logErrors: [(domain: String, code: Int)]) -> Bool {
		if logErrors.contains(where: { $0.code == 404 }) { return true }
		var underlying = error
		var visited = Set<ObjectIdentifier>()
		while let current = underlying, visited.insert(ObjectIdentifier(current)).inserted {
			// AVFoundation wraps an HTTP 404 in CoreMedia's resource-not-found error.
			if (current.domain == "CoreMediaErrorDomain" || current.domain == NSOSStatusErrorDomain),
				current.code == -12938 { return true }
			underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
		}
		return false
	}

	private func skipNotFoundVideo() {
		guard let coordinator, let index = playbackIndex, playbackArticles.indices.contains(index) else {
			// Without the queue identity it is unsafe to mark the displayed article read.
			finishPlaybackSession()
			return
		}
		let article = playbackArticles[index]
		attemptResolved = true
		retryTask?.cancel()
		retryTask = nil
		pendingPlaybackArticle = nil
		appDelegate.resumeDatabaseProcessingIfNecessary()
		markArticles(Set([article]), statusKey: .read, flag: true)
		ArticleMediaLog.log(.info, operation: "Native video recovery", message: "session=\(playbackSessionID) request=\(playbackRequestID) articleID=\(article.articleID) action=skip-not-found")
		guard let next = nextArticleForPlayback(coordinator),
			let url = Self.extractFirstVideoURL(from: next.body) else {
			finishPlaybackSession()
			return
		}
		startNextVideo(next, url: url)
	}

	private func startNextVideo(_ article: Article, url: URL) {
		guard canContinuePlayback else {
			return
		}
		autoplaySession.prepare(article)
		playbackIndex = playbackArticles.firstIndex { $0.articleID == article.articleID && $0.accountID == article.accountID }
		currentArticleID = article.articleID
		pendingPlaybackArticle = article
		playbackURL = url
		resumePosition = 0
		recovery = VideoPlaybackRecovery()
		coordinator?.retainArticleForVideoPlayback(article)
		let item = AVPlayerItem(url: url)
		installPlaybackItem(item)
		requestPlayback(for: item)
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
		swipeDismissGesture.install(on: playerViewController)
		return playerViewController
	}

	/// Called once the user has swiped the player off screen. Matches what closing the player
	/// with its own Done button does, minus the dismissal animation that the swipe already played.
	private func dismissByUserSwipe() {
		guard !isPiPActive else {
			return
		}
		ArticleMediaLog.log(.info, operation: "Native video dismissal", message: "request=\(playbackRequestID) articleID=\(currentArticleID ?? "(nil)") source=swipe")
		finishPlaybackSession(animated: false)
	}

	private func observePlayerItemEnd(_ item: AVPlayerItem) {
		removeEndObserver()
		observePlaybackDiagnostics(for: item)
		let sessionID = playbackSessionID
		let requestID = playbackRequestID
		endObserver = NotificationCenter.default.addObserver(
			forName: .AVPlayerItemDidPlayToEndTime,
			object: item,
			queue: .main
		) { [weak self, weak item] _ in
			Task { @MainActor in
				guard let self, self.playbackSessionID == sessionID, self.playbackRequestID == requestID,
					!self.attemptResolved, Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
					return
				}
				self.attemptResolved = true
				if let item, item.currentTime().seconds > 0 { self.commitPlaybackProgress() }
				self.consecutiveFailures = 0
				self.handleVideoEnded()
			}
		}
	}

	private func removeEndObserver() {
		if let endObserver {
			NotificationCenter.default.removeObserver(endObserver)
		}
		endObserver = nil
		playerItemStatusObservation?.invalidate()
		playerItemStatusObservation = nil
		playerTimeControlObservation?.invalidate()
		playerTimeControlObservation = nil
		for observer in playbackDiagnosticObservers {
			NotificationCenter.default.removeObserver(observer)
		}
		playbackDiagnosticObservers.removeAll()
	}

	private func observePlaybackDiagnostics(for item: AVPlayerItem) {
		playbackRequestID += 1
		playbackRequestStartUptime = ProcessInfo.processInfo.systemUptime
		let sessionID = playbackSessionID
		let requestID = playbackRequestID
		playerItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, change in
			let status = change.newValue?.rawValue ?? -1
			Task { @MainActor in
				guard let self, let item, self.playbackSessionID == sessionID, self.playbackRequestID == requestID,
					Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
					return
				}
				self.logPlaybackDiagnostics(for: item, event: "item-status-\(status)")
				if item.status == .failed { self.handlePlaybackFailure(item, reason: "item-failed") }
				if item.status == .readyToPlay { self.restorePlaybackPosition(for: item) }
			}
		}
		playerTimeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self, weak item] _, change in
			let status = change.newValue?.rawValue ?? -1
			Task { @MainActor in
				guard let self, let item, self.playbackSessionID == sessionID, self.playbackRequestID == requestID,
					Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
					return
				}
				self.logPlaybackDiagnostics(for: item, event: "time-control-\(status)")
				if item.status == .failed {
					self.handlePlaybackFailure(item, reason: "item-failed")
					return
				}
				if self.player?.timeControlStatus == .paused, item.status == .readyToPlay,
					!self.seekingForRecovery, !self.attemptResolved {
					self.recovery.pause()
				}
			}
		}
		let rateReasonKey = AVPlayer.rateDidChangeReasonKey
		let explicitRateReason = AVPlayer.RateDidChangeReason.setRateCalled.rawValue
		let rateObserver = NotificationCenter.default.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { [weak self, weak item] notification in
			let explicit = (notification.userInfo?[rateReasonKey] as? String) == explicitRateReason
			let rate = (notification.object as? AVPlayer)?.rate ?? 0
			Task { @MainActor in
				guard let self, let item, explicit, self.playbackSessionID == sessionID,
					self.playbackRequestID == requestID,
					Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
					return
				}
				self.logPlaybackDiagnostics(for: item, event: "rate-\(rate)")
				if rate == 0 {
					let ignoredPause = self.ignoredPauseRequestID == requestID
					if ignoredPause {
						self.ignoredPauseRequestID = nil
					}
					switch Self.explicitZeroRateAction(
						itemStatus: item.status,
						hasItemError: item.error != nil,
						playerRate: self.player?.rate ?? 0,
						ignoredPause: ignoredPause,
						retryPending: self.retryTask != nil,
						seekingForRecovery: self.seekingForRecovery,
						pendingVideoEnd: self.pendingVideoEnd,
						audioInterrupted: self.audioInterrupted
					) {
					case .ignore:
						break
					case .failPlayback:
						self.handlePlaybackFailure(item, reason: "item-failed")
					case .suspendRecovery:
						self.playbackRequested = false
						self.attemptResolved = true
						self.suspendRecovery(reason: "user-paused")
						self.recovery.pause()
					case .pausePlayback:
						self.playbackRequested = false
						self.recovery.pause()
					}
				} else {
					self.handleExplicitPlaybackResume()
				}
			}
		}
		playbackDiagnosticObservers.append(rateObserver)
		let events: [(Notification.Name, String)] = [
			(.AVPlayerItemTimeJumped, "time-jumped"),
			(.AVPlayerItemFailedToPlayToEndTime, "failed-to-end"),
			(.AVPlayerItemNewErrorLogEntry, "error-log"),
			(.AVPlayerItemPlaybackStalled, "stalled")
		]
		for (name, event) in events {
			let observer = NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self, weak item] notification in
				let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
				Task { @MainActor in
					guard let self, let item, self.playbackSessionID == sessionID, self.playbackRequestID == requestID,
						Self.isCurrentPlaybackItem(item, currentItem: self.player?.currentItem) else {
						return
					}
					self.logPlaybackDiagnostics(for: item, event: event, error: error)
					if event == "failed-to-end" || event == "error-log" {
						self.handlePlaybackFailure(item, reason: event, error: error)
					}
					if event == "time-jumped" {
						self.recovery.resetSample(now: ProcessInfo.processInfo.systemUptime, mediaTime: item.currentTime().seconds)
						self.recovery.pause()
					}
				}
			}
			playbackDiagnosticObservers.append(observer)
		}
	}

	private func logPlaybackDiagnostics(for item: AVPlayerItem, event: String, error: Error? = nil) {
		guard Self.isCurrentPlaybackItem(item, currentItem: player?.currentItem) else {
			return
		}
		let elapsed = (ProcessInfo.processInfo.systemUptime - playbackRequestStartUptime) * 1_000
		var details = "request=\(playbackRequestID) articleID=\(currentArticleID ?? "(nil)") event=\(event) elapsed_ms=\(String(format: "%.1f", elapsed)) item_status=\(item.status.rawValue) time_control=\(player?.timeControlStatus.rawValue ?? -1) waiting_reason=\(player?.reasonForWaitingToPlay?.rawValue ?? "none") pip=\(isPiPActive)"
		var underlyingError = (error ?? item.error).map { $0 as NSError }
		for depth in 0..<4 {
			guard let currentError = underlyingError else {
				break
			}
			details += " error_\(depth)_domain=\(currentError.domain) error_\(depth)_code=\(currentError.code)"
			underlyingError = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
		}
		if let entry = item.errorLog()?.events.last {
			details += " stream_error_domain=\(entry.errorDomain) stream_error_code=\(entry.errorStatusCode)"
		}
		let level: ErrorLogLevel = item.status == .failed || error != nil || event == "failed-to-end" ? .error :
			(event == "error-log" || event == "stalled" ? .warning : .info)
		ArticleMediaLog.log(level, operation: "Native video state", message: details)
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
			hasNextVideo: nextVideoURL != nil,
			isArticleNavigationBlocked: coordinator.isArticleQuickSettingsPresented
		)
		ArticleMediaLog.log(.info, operation: "Native video end", message: "request=\(playbackRequestID) articleID=\(currentArticleID ?? "(nil)") action=\(action) pip=\(pipActive)")

		switch action {
		case .playNextVideo:
			if let nextArticle, let nextVideoURL {
				guard !audioInterrupted else {
					// The end notification is already consumed; retain the transition until resumption.
					pendingVideoEnd = true
					ArticleMediaLog.log(.info, operation: "Native video end", message: "request=\(playbackRequestID) action=defer-next reason=audio-interruption")
					return
				}
				Self.logger.info("Swapping to next article video in PiP")
				appDelegate.resumeDatabaseProcessingIfNecessary()
				NotificationActionLog.log(.info, operation: "PiP auto-next", message: "Selecting next article \(nextArticle.articleID); isSuspended=\(AccountManager.shared.isSuspended); appState=\(UIApplication.shared.applicationState.rawValue)")

				startNextVideo(nextArticle, url: nextVideoURL)
				return
			}
		case .selectNextArticle:
			let endedRequestID = playbackRequestID
			let selectedArticleID = coordinator.currentArticle?.articleID
			finishPlaybackSession { [weak self, weak coordinator] in
				guard let self, let coordinator,
					self.playbackRequestID == endedRequestID,
					coordinator.currentArticle?.articleID == selectedArticleID else {
					return
				}
				ArticleMediaLog.log(.info, operation: "Native video end", message: "request=\(endedRequestID) event=dismissal-completed-select-next")
				coordinator.selectNextArticleAfterVideo()
			}
			return
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

	static func playbackEndAction(isPiPActive: Bool, pipAutoPlayNextVideo: Bool, autoGotoNextAfterVideo: Bool, hasNextVideo: Bool, isArticleNavigationBlocked: Bool = false) -> PlaybackEndAction {
		guard !isArticleNavigationBlocked else {
			return .finish
		}
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
		if let index = playbackIndex {
			return index + 1 < playbackArticles.count ? playbackArticles[index + 1] : nil
		}
		if let currentArticleID, coordinator.currentArticle?.articleID != currentArticleID, let article = coordinator.articleFor(currentArticleID) {
			return coordinator.findNextArticle(article)
		}
		return coordinator.nextArticle
	}

	private func finishPlaybackSession(animated: Bool = true, completion: (() -> Void)? = nil) {
		cancelRecovery()
		autoplaySession.finish()
		playbackSessionID = UUID()
		pendingPlaybackArticle = nil
		playbackIndex = nil
		playbackURL = nil
		if let item = player?.currentItem {
			logPlaybackDiagnostics(for: item, event: "finish-session")
		}
		player?.pause()
		player?.replaceCurrentItem(with: nil)
		removeEndObserver()
		currentArticleID = nil
		playbackArticles.removeAll()

		guard !isPiPActive else {
			completion?()
			return
		}
		// Clear the old session before dismissal can make the article visible again.
		// Its completion may immediately start a new playback session.
		let finishedController = playerViewController
		playerViewController = nil
		guard let finishedController, finishedController.presentingViewController != nil else {
			completion?()
			return
		}
		finishedController.dismiss(animated: animated, completion: completion)
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
			if !restored {
				self.pictureInPictureState.withLock { $0.restorationRequested = false }
				if !self.isPiPActive, playerViewController.presentingViewController == nil {
					self.finishPlaybackSession()
				}
			}
			completionHandler(restored)
		}

		guard let coordinator, !coordinator.isArticleQuickSettingsPresented else {
			finish(false)
			return
		}

		if pendingPlaybackArticle == nil, let currentArticleID, let article = coordinator.articleFor(currentArticleID) {
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
		guard pendingPlaybackArticle == nil, isPiPActive, let currentArticleID, let coordinator, !coordinator.isArticleQuickSettingsPresented,
		      let article = coordinator.articleFor(currentArticleID) else {
			return
		}
		coordinator.selectArticle(article, animations: [.navigation, .scroll])
	}
}

// Playback ownership includes a loading or paused item. History only includes real progress.
struct VideoAutoplaySession {
	private struct ArticleIdentity: Hashable {
		let accountID: String
		let articleID: String

		init(_ article: Article) {
			accountID = article.accountID
			articleID = article.articleID
		}
	}

	private var currentArticle: ArticleIdentity?
	private var startedArticles = Set<ArticleIdentity>()

	mutating func begin(_ article: Article) {
		finish()
		prepare(article)
	}

	mutating func prepare(_ article: Article) {
		currentArticle = ArticleIdentity(article)
	}

	mutating func recordProgress() {
		if let currentArticle {
			startedArticles.insert(currentArticle)
		}
	}

	func contains(_ article: Article) -> Bool {
		let identity = ArticleIdentity(article)
		return currentArticle == identity || startedArticles.contains(identity)
	}

	mutating func finish() {
		currentArticle = nil
		startedArticles.removeAll()
	}
}

// Time is supplied by the caller so recovery limits can be tested without sleeps.
nonisolated struct VideoPlaybackRecovery {
	enum Sample: Equatable { case none, progress, healthy, timeout }
	private(set) var retries = 0
	private(set) var recoveryWait: TimeInterval = 0
	private(set) var isSuspended = false
	private var lastSample: TimeInterval = 0
	private var lastMediaTime: Double = 0
	private var waitingDuration: TimeInterval = 0
	private var continuousPlayback: TimeInterval = 0
	private var hasProgress = false

	mutating func startAttempt(now: TimeInterval) {
		isSuspended = false
		waitingDuration = 0
		continuousPlayback = 0
		hasProgress = false
		resetSample(now: now, mediaTime: 0)
	}

	mutating func resetSample(now: TimeInterval, mediaTime: Double) {
		lastSample = now
		lastMediaTime = mediaTime.isFinite ? mediaTime : 0
	}

	mutating func pause() {
		waitingDuration = 0
		continuousPlayback = 0
	}

	mutating func suspend() {
		isSuspended = true
		pause()
	}

	mutating func resume(now: TimeInterval, mediaTime: Double) {
		isSuspended = false
		pause()
		resetSample(now: now, mediaTime: mediaTime)
	}

	mutating func sample(now: TimeInterval, mediaTime: Double, playing: Bool, waiting: Bool) -> Sample {
		// Do not turn time spent suspended by iOS into a burst of recovery actions.
		let elapsed = min(max(now - lastSample, 0), 1)
		let advance = mediaTime - lastMediaTime
		resetSample(now: now, mediaTime: mediaTime)
		if playing, advance > 0, advance <= max(2, elapsed * 4) {
			hasProgress = true
			waitingDuration = 0
			continuousPlayback += elapsed
			return continuousPlayback >= 5 ? .healthy : .progress
		}
		continuousPlayback = 0
		if !playing && !waiting || advance < 0 || advance > max(2, elapsed * 4) {
			waitingDuration = 0
			return .none
		}
		guard !isSuspended else {
			return .none
		}
		waitingDuration += elapsed
		recoveryWait += elapsed
		return waitingDuration >= (hasProgress ? 20 : 15) || recoveryWait >= 60 ? .timeout : .none
	}

	mutating func retryDelay() -> TimeInterval? {
		guard !isSuspended, retries < 2 else {
			return nil
		}
		let delay: TimeInterval = retries == 0 ? 1 : 3
		guard recoveryWait + delay < 60 else {
			return nil
		}
		retries += 1
		recoveryWait += delay
		return delay
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
			guard playerViewController === self.playerViewController else {
				return
			}
			Self.logger.info("PiP stopped")
			self.pendingVideoEnd = false
			self.suspendRecovery(reason: "pip-stopped")
			if !self.pictureInPictureState.withLock({ $0.restorationRequested }),
				playerViewController.presentingViewController == nil {
				self.finishPlaybackSession()
			}
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
		// AVKit can report PiP stopping before the queued restoration task starts.
		pictureInPictureState.withLock { $0.restorationRequested = true }
		Task { @MainActor in
			Self.logger.info("PiP restore requested")
			restoreUserInterface(completionHandler: completionHandler)
		}
	}

	nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
		Task { @MainActor in
			ArticleMediaLog.log(.info, operation: "Native video dismissal", message: "request=\(playbackRequestID) articleID=\(currentArticleID ?? "(nil)") controller_current=\(playerViewController === self.playerViewController) pip=\(isPiPActive) restoring=\(isRestoringUserInterface)")
			// A dismissal callback from the finished controller must not tear down
			// the next article's player after automatic navigation.
			if playerViewController === self.playerViewController, !isPiPActive, !isRestoringUserInterface {
				finishPlaybackSession()
			}
		}
	}
}
