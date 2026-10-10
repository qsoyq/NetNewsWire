//
//  WebViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 12/28/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
@preconcurrency import WebKit
import RSCore
import RSWeb
import Account
import Articles
import ErrorLog
import SafariServices
import MessageUI
import Images

@MainActor protocol WebViewControllerDelegate: AnyObject {
	func webViewController(_: WebViewController, articleExtractorButtonStateDidUpdate: ArticleExtractorButtonState)
	func webViewControllerDidLoadArticle(_ controller: WebViewController)
}

extension WebViewControllerDelegate {
	func webViewControllerDidLoadArticle(_ controller: WebViewController) {}
}

final class WebViewController: UIViewController {

	private struct MessageName {
		static let imageWasClicked = "imageWasClicked"
		static let imageWasShown = "imageWasShown"
		static let showFeedInspector = "showFeedInspector"
		static let mediaSourceURLs = "mediaSourceURLs"
		static let videoEnded = "videoEnded"
		static let nativeVideoPlay = "nativeVideoPlay"
		static let webViewPiPStarted = "webViewPiPStarted"
		static let webViewPiPStopped = "webViewPiPStopped"
		static let mediaContextTarget = "mediaContextTarget"
		static let mediaLongPress = "mediaLongPress"
		static let articleImageLoad = "articleImageLoad"
	}

	private enum MediaContextTarget: String {
		case image
		case video
		case header
	}

	private struct MediaContextTargetState {
		let target: MediaContextTarget
		let press: Int
		let detectedAt: Date
		let resourceURL: String?
	}

	private struct MediaSnapshot: Decodable {
		let urls: [String]
		let skipped: Int
	}

	private var topShowBarsView: UIView!
	private var bottomShowBarsView: UIView!
	private var topShowBarsViewConstraint: NSLayoutConstraint!
	private var bottomShowBarsViewConstraint: NSLayoutConstraint!

	private var webView: PreloadedWebView? {
		return view.subviews[0] as? PreloadedWebView
	}

	private var webViewProcessDidTerminate = false

	private lazy var contextMenuInteraction = UIContextMenuInteraction(delegate: self)
	private var isFullScreenAvailable: Bool {
		return AppDefaults.shared.articleFullscreenAvailable && traitCollection.userInterfaceIdiom == .phone
	}
	private lazy var articleIconSchemeHandler = ArticleIconSchemeHandler(coordinator: coordinator)
	private lazy var transition = ImageTransition(controller: self)
	private var imageDownloadTask: Task<Void, Never>?
	private var imagePresentationEnabled = false
	private var imageRequestGeneration = 0
	private var imageOpenedFromThumbnail = false
	private var mediaSourceURLs = Set<String>()
	private var clickedImageCompletion: (() -> Void)?
	private var mediaContextTargetState: MediaContextTargetState?
	private var latestMediaContextPress = 0
	private var didConfigureContextMenuForCurrentPress = false
	private var mediaSaveProgressAlert: UIAlertController?
	private var mediaSaveTask: Task<Void, Never>?
	private var mediaSaveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
	private var isConfirmingMediaSave = false
	private var pendingMediaSaveResult: (title: String, message: String)?
	private var isMediaSaveResultPresentationScheduled = false
	private var articleImageLoadTracker: ArticleImageLoadTracker?
	private var articleImageSummaryTask: Task<Void, Never>?
	private var videoDocumentReady = false
	var isArticleDocumentReady: Bool { videoDocumentReady }
	var translationViewportSize: CGSize { webView?.bounds.size ?? CGSize(width: 375, height: 800) }
	private var videoDocumentGeneration = 0
	private var nativeAutoplayPending = false
	private var nativeAutoplayStarted = false
	private var videoPresentationEnabled = false
	private let articleTranslationController = ArticleTranslationController()
	private let videoPreviewController = VideoPreviewController()
	private var thumbnailSettings = [AppDefaults.shared.showArticleMediaThumbnails, AppDefaults.shared.useNativeVideoPlayer]
	var translationState: String { articleTranslationController.state }
	var translationStateDidChange: ((String) -> Void)? {
		didSet { articleTranslationController.stateDidChange = translationStateDidChange }
	}

	func toggleTranslation() {
		articleTranslationController.toggleFromNative()
	}

	private var articleExtractor: ArticleExtractor?
	var extractedArticle: ExtractedArticle? {
		didSet {
			windowScrollY = 0
		}
	}
	var isShowingExtractedArticle = false {
		didSet {
			if AppDefaults.shared.isShowingExtractedArticle != isShowingExtractedArticle {
				AppDefaults.shared.isShowingExtractedArticle = isShowingExtractedArticle
			}
		}
	}

	var articleExtractorButtonState: ArticleExtractorButtonState = .off {
		didSet {
			delegate?.webViewController(self, articleExtractorButtonStateDidUpdate: articleExtractorButtonState)
		}
	}

	weak var coordinator: SceneCoordinator!
	weak var delegate: WebViewControllerDelegate?

	private(set) var article: Article?

	let scrollPositionQueue = CoalescingQueue(name: "Article Scroll Position", interval: 0.3, maxInterval: 0.3)
	var windowScrollY = 0 {
		didSet {
			if windowScrollY != AppDefaults.shared.articleWindowScrollY {
				AppDefaults.shared.articleWindowScrollY = windowScrollY
			}
		}
	}
	private var restoreWindowScrollY: Int?
	private var isArticleContentJavascriptEnabled = AppDefaults.shared.isArticleContentJavascriptEnabled

	override func viewDidLoad() {
		super.viewDidLoad()

		NotificationCenter.default.addObserver(self, selector: #selector(feedIconDidBecomeAvailable(_:)), name: .feedIconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(avatarDidBecomeAvailable(_:)), name: .AvatarDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .FaviconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(currentArticleThemeDidChangeNotification(_:)), name: .CurrentArticleThemeDidChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(presentPendingMediaSaveResult), name: UIApplication.didBecomeActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleSceneDidEnterBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleUserDefaultsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)

		// Configure the tap zones
		configureTopShowBarsView()
		configureBottomShowBarsView()

		loadWebView()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		imagePresentationEnabled = true
		webView?.evaluateJavaScript("resumeImageViewer();")
		if let webView {
			ArticleMediaThumbnails.configure(webView, active: true)
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if let webView {
			Task {
				try? await ArticleDisclosureController.configure(webView, enabled: AppDefaults.shared.automaticallyExpandArticleDetails)
			}
		}
		articleTranslationController.setActive(true)
		videoPreviewController.setActive(true)
		ArticlePrefetcher.shared.prefetchNextArticle(after: article, coordinator: coordinator)
		videoPresentationEnabled = true
		startNativeVideoDirectly()
		presentPendingMediaSaveResult()
	}

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		if isFullScreenAvailable && AppDefaults.shared.logicalArticleFullscreenEnabled {
			updateBottomSafeAreaForFullScreen()
		}
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		articleTranslationController.setActive(false)
		videoPreviewController.setActive(false)
		// Pause in-flight media before the view goes away. Leaving a video playing during
		// dismissal lets WebKit's full-screen entry continuation fire on a stale view
		// hierarchy and trip a RELEASE_ASSERT in WebFullScreenManagerProxy on iOS 26.
		stopWebViewActivity()
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		// A completed article exit starts a new autoplay opportunity on return.
		// Presenting the native player or entering PiP stays within this opening.
		if presentedViewController == nil, !VideoPlayerManager.shared.isPiPActive,
			!WebViewPiPManager.shared.isPiPActive {
			nativeAutoplayStarted = false
		}
	}

	// MARK: Notifications

	@objc func handleSceneDidEnterBackground(_ notification: Notification) {
		// The share sheet is a popover on iPad. Opening the article in another browser
		// from it backgrounds NetNewsWire mid-presentation, orphaning the popover so it
		// can't be dismissed by tapping outside on return. Dismiss it on backgrounding. (#4269)
		if presentedViewController is UIActivityViewController {
			dismiss(animated: false)
		}
	}

	@objc func feedIconDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func avatarDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func faviconDidBecomeAvailable(_ note: Notification) {
		reloadArticleImage()
	}

	@objc func currentArticleThemeDidChangeNotification(_ note: Notification) {
		loadWebView()
	}

	@objc nonisolated func handleUserDefaultsDidChange(_ note: Notification) {
		Task { @MainActor in
			self.userDefaultsDidChange()
		}
	}

	private func userDefaultsDidChange() {
		let settings = [AppDefaults.shared.showArticleMediaThumbnails, AppDefaults.shared.useNativeVideoPlayer]
		if thumbnailSettings != settings {
			thumbnailSettings = settings
			if let webView {
				ArticleMediaThumbnails.configure(webView, active: imagePresentationEnabled)
			}
		}
		guard isArticleContentJavascriptEnabled != AppDefaults.shared.isArticleContentJavascriptEnabled else {
			return
		}
		isArticleContentJavascriptEnabled = AppDefaults.shared.isArticleContentJavascriptEnabled
		loadWebView()
	}

	// MARK: Actions

	@objc func showBars(_ sender: Any) {
		showBars()
	}

	// MARK: API

	func setArticle(_ article: Article?, updateView: Bool = true) {
		stopArticleExtractor()

		if article != self.article {
			videoPreviewController.documentWillChange()
			articleTranslationController.documentWillChange()
			nativeAutoplayStarted = false
			invalidateImageDownload()
			self.article = article
			// A restoration offset belongs only to the article it was saved for.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/5243>
			restoreWindowScrollY = nil
			if updateView {
				if article?.feed?.readerViewAlwaysEnabled == true {
					startArticleExtractor()
				}
				windowScrollY = 0
				loadWebView()
			}
		}
	}

	func setScrollPosition(isShowingExtractedArticle: Bool, articleWindowScrollY: Int) {
		if isShowingExtractedArticle {
			switch articleExtractor?.state {
			case .ready:
				restoreWindowScrollY = articleWindowScrollY
				startArticleExtractor()
			case .complete:
				windowScrollY = articleWindowScrollY
				loadWebView()
			case .processing:
				restoreWindowScrollY = articleWindowScrollY
			default:
				restoreWindowScrollY = articleWindowScrollY
				startArticleExtractor()
			}
		} else {
			windowScrollY = articleWindowScrollY
			loadWebView()
		}
	}

	func focus() {
		webView?.becomeFirstResponder()
	}

	func canScrollDown() -> Bool {
		guard let webView = webView else { return false }
		return webView.scrollView.contentOffset.y < finalScrollPosition(scrollingUp: false)
	}

	func canScrollUp() -> Bool {
		guard let webView = webView else { return false }
		return webView.scrollView.contentOffset.y > finalScrollPosition(scrollingUp: true)
	}

	private func scrollPage(up scrollingUp: Bool) {
		guard let webView, let windowScene = webView.window?.windowScene else {
			return
		}

		let overlap = 2 * UIFont.systemFont(ofSize: UIFont.systemFontSize).lineHeight * windowScene.screen.scale
		let scrollToY: CGFloat = {
			let scrollDistance = webView.scrollView.layoutMarginsGuide.layoutFrame.height - overlap
			let fullScroll = webView.scrollView.contentOffset.y + (scrollingUp ? -scrollDistance : scrollDistance)
			let final = finalScrollPosition(scrollingUp: scrollingUp)
			return (scrollingUp ? fullScroll > final : fullScroll < final) ? fullScroll : final
		}()

		let convertedPoint = self.view.convert(CGPoint(x: 0, y: 0), to: webView.scrollView)
		let scrollToPoint = CGPoint(x: convertedPoint.x, y: scrollToY)
		webView.scrollView.setContentOffset(scrollToPoint, animated: true)
	}

	func scrollPageDown() {
		scrollPage(up: false)
	}

	func scrollPageUp() {
		scrollPage(up: true)
	}

	func hideClickedImage() {
		guard !imageOpenedFromThumbnail else {
			return
		}
		webView?.evaluateJavaScript("hideClickedImage();")
	}

	func showClickedImage(completion: @escaping () -> Void) {
		if imageOpenedFromThumbnail {
			completion()
			return
		}
		clickedImageCompletion = completion
		webView?.evaluateJavaScript("showClickedImage();")
	}

	func fullReload() {
		loadWebView(replaceExistingWebView: true)
	}

	func showBars(animated: Bool = true) {
		AppDefaults.shared.articleFullscreenEnabled = false
		coordinator.showStatusBar()
		topShowBarsViewConstraint?.constant = 0
		bottomShowBarsViewConstraint?.constant = 0
		navigationController?.setNavigationBarHidden(false, animated: animated)
		navigationController?.setToolbarHidden(false, animated: animated)
		additionalSafeAreaInsets.bottom = 0
		setBottomScrollEdgeEffectHidden(false)
		configureContextMenuInteraction()
	}

	func hideBars() {
		if isFullScreenAvailable {
			AppDefaults.shared.articleFullscreenEnabled = true
			coordinator.hideStatusBar()
			topShowBarsViewConstraint?.constant = -44.0
			bottomShowBarsViewConstraint?.constant = 44.0
			navigationController?.setNavigationBarHidden(true, animated: true)
			navigationController?.setToolbarHidden(true, animated: true)
			setBottomScrollEdgeEffectHidden(true)
			configureContextMenuInteraction()
		}
	}

	func toggleArticleExtractor() {

		guard let article = article else {
			return
		}

		guard articleExtractor?.state != .processing else {
			stopArticleExtractor()
			loadWebView()
			return
		}

		guard !isShowingExtractedArticle else {
			isShowingExtractedArticle = false
			loadWebView()
			articleExtractorButtonState = .off
			return
		}

		if let articleExtractor = articleExtractor {
			if article.preferredLink == articleExtractor.articleLink {
				isShowingExtractedArticle = true
				loadWebView()
				articleExtractorButtonState = .on
			}
		} else {
			startArticleExtractor()
		}

	}

	func stopArticleExtractorIfProcessing() {
		if articleExtractor?.state == .processing {
			stopArticleExtractor()
		}
	}

	func suspendImagePresentation() {
		imagePresentationEnabled = false
		invalidateImageDownload()
		if isViewLoaded {
			if let webView {
				ArticleMediaThumbnails.setActive(false, in: webView)
			}
			webView?.evaluateJavaScript("suspendImageViewer();")
		}
	}

	private func invalidateImageDownload() {
		imageRequestGeneration += 1
		imageDownloadTask?.cancel()
		imageDownloadTask = nil
	}

	private var canPresentArticleImage: Bool {
		imagePresentationEnabled && viewIfLoaded?.window != nil
			&& (delegate as? ArticleViewController)?.isCurrentWebViewController(self) == true
	}

	func stopWebViewActivity() {
		videoPreviewController.setActive(false)
		videoPresentationEnabled = false
		suspendImagePresentation()
		guard !VideoPlayerManager.shared.isPiPActive, !WebViewPiPManager.shared.isPiPActive else {
			return
		}
		guard let webView = webView else {
			return
		}
		// Resetting iframe src during an element-fullscreen transition triggers a WebKit
		// RELEASE_ASSERT. Exit fullscreen first.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5382>
		if webView.fullscreenState != .notInFullscreen {
			webView.closeAllMediaPresentations { [weak self] in
				guard let self else {
					return
				}
				self.stopMediaPlayback(webView)
			}
		} else {
			stopMediaPlayback(webView)
		}
	}

	func showActivityDialog(popOverBarButtonItem: UIBarButtonItem? = nil) {
		guard let url = article?.preferredURL else { return }
		let activityViewController = UIActivityViewController(url: url, title: article?.title, applicationActivities: [FindInArticleActivity(), OpenInBrowserActivity()])
		activityViewController.popoverPresentationController?.barButtonItem = popOverBarButtonItem
		present(activityViewController, animated: true)
	}

	func openInAppBrowser() {
		guard let url = article?.preferredURL else { return }
		if AppDefaults.shared.useSystemBrowser {
			UIApplication.shared.open(url, options: [:])
		} else {
			openURLInSafariViewController(url)
		}
	}
}

// MARK: ArticleExtractorDelegate

extension WebViewController: ArticleExtractorDelegate {

	func articleExtractionDidFail(with: Error) {
		guard articleExtractor != nil else {
			return
		}
		stopArticleExtractor()
		articleExtractorButtonState = .error
		loadWebView()
	}

	func articleExtractionDidComplete(extractedArticle: ExtractedArticle) {
		guard let articleExtractor, articleExtractor.state != .cancelled else {
			return
		}
		self.extractedArticle = extractedArticle
		if let restoreWindowScrollY = restoreWindowScrollY {
			windowScrollY = restoreWindowScrollY
			self.restoreWindowScrollY = nil
		}
		isShowingExtractedArticle = true
		loadWebView()
		articleExtractorButtonState = .on
	}

}

// MARK: UIContextMenuInteractionDelegate

extension WebViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {

		return UIContextMenuConfiguration(identifier: nil, previewProvider: contextMenuPreviewProvider) { [weak self] _ in
			guard let self = self else { return nil }

			var menus = [UIMenu]()

			var navActions = [UIAction]()
			if let action = self.prevArticleAction() {
				navActions.append(action)
			}
			if let action = self.nextArticleAction() {
				navActions.append(action)
			}
			if !navActions.isEmpty {
				menus.append(UIMenu(title: "", options: .displayInline, children: navActions))
			}

			var toggleActions = [UIAction]()
			if let action = self.toggleReadAction() {
				toggleActions.append(action)
			}
			toggleActions.append(self.toggleStarredAction())
			menus.append(UIMenu(title: "", options: .displayInline, children: toggleActions))

			if let action = self.nextUnreadArticleAction() {
				menus.append(UIMenu(title: "", options: .displayInline, children: [action]))
			}

			menus.append(UIMenu(title: "", options: .displayInline, children: [self.toggleArticleExtractorAction()]))
			menus.append(UIMenu(title: "", options: .displayInline, children: [self.shareAction()]))

			return UIMenu(title: "", children: menus)
        }
    }

	func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
		coordinator.showBrowserForCurrentArticle()
	}

}

// MARK: WKUIDelegate

extension WebViewController: WKUIDelegate {

	func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void) {
		if currentMediaContextTarget == .header || isFeedHomePageLink(elementInfo.linkURL),
			let headerMenu = goToFeedMenuConfiguration() {
			didConfigureContextMenuForCurrentPress = true
			logMediaEvent(.debug, operation: "Context menu", message: "Public callback began for article header")
			completionHandler(headerMenu)
			return
		}

		// Links keep WebKit's own menu and preview. Returning nil restores exactly the behavior this
		// app had before batch saving existed, so the only thing this callback adds is the extra
		// action for a link-wrapped image.
		let mediaContextTarget = currentMediaContextTarget
		if mediaContextTarget != nil {
			didConfigureContextMenuForCurrentPress = true
		}
		logMediaEvent(.debug, operation: "Context menu", message: "Public callback began for \(mediaContextTarget?.rawValue ?? "non-media") target")
		completionHandler(mediaContextMenuConfiguration(appending: mediaContextTarget))
	}

	/// WebKit routes link elements through the public callback above, but long-pressing a plain image
	/// element goes through this private callback instead. WebKit's own header keeps it private "to
	/// continue to do callbacks for image element context menus"; without it WebKit builds the image
	/// menu by itself and the Save All action can never be appended.
	@objc(_webView:contextMenuConfigurationForElement:completionHandler:)
	func webView(_ webView: WKWebView, _privateContextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void) {
		if currentMediaContextTarget == .header, let headerMenu = goToFeedMenuConfiguration() {
			didConfigureContextMenuForCurrentPress = true
			logMediaEvent(.debug, operation: "Context menu", message: "Private callback began for article header")
			completionHandler(headerMenu)
			return
		}

		guard let mediaContextTarget = currentMediaContextTarget else {
			// Not one of ours: keep hands off so WebKit's own menu and preview stay untouched.
			logMediaEvent(.debug, operation: "Context menu", message: "Private callback found no media target; leaving the system menu alone")
			completionHandler(nil)
			return
		}

		didConfigureContextMenuForCurrentPress = true
		logMediaEvent(.debug, operation: "Context menu", message: "Private callback began for \(mediaContextTarget.rawValue) target")
		completionHandler(mediaContextMenuConfiguration(appending: mediaContextTarget))
	}

}

// MARK: WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		guard webView === self.webView else {
			return
		}
		videoDocumentReady = true
		ArticleMediaThumbnails.configure(webView, active: imagePresentationEnabled)
		videoPreviewController.documentDidLoad(webView)
		videoPreviewController.setActive(viewIfLoaded?.window != nil && ((delegate as? ArticleViewController)?.isCurrentWebViewController(self) ?? true))
		articleTranslationController.setActive(viewIfLoaded?.window != nil && (delegate as? ArticleViewController)?.isCurrentWebViewController(self) == true)
		if article != nil, articleExtractor?.state != .processing {
			articleTranslationController.documentDidLoad(webView, articleID: article?.articleID)
		}
		webView.evaluateJavaScript(imagePresentationEnabled ? "resumeImageViewer();" : "suspendImageViewer();")
		if let article {
			logMediaEvent(.info, operation: "Render", message: "documentURL=\(webView.url?.absoluteString ?? "(nil)") articleID=\(article.articleID)")
			scheduleArticleImageSummary(documentURL: webView.url?.absoluteString ?? "")
		}
		for (index, view) in view.subviews.enumerated() {
			if index != 0, let oldWebView = view as? PreloadedWebView {
				oldWebView.removeFromSuperview()
			}
		}

		if AppDefaults.shared.useNativeVideoPlayer {
			webView.evaluateJavaScript("setupVideoAutoFullscreenNative();")
		} else if AppDefaults.shared.autoFullscreenVideo {
			webView.evaluateJavaScript("setupVideoAutoFullscreen();")
		}
		if AppDefaults.shared.useNativeVideoPlayer && AppDefaults.shared.autoplayVideo {
			startNativeVideoDirectly()
		} else if AppDefaults.shared.autoplayVideo {
			webView.evaluateJavaScript("setupVideoAutoplay();")
		}
		if AppDefaults.shared.autoGotoNextAfterVideo {
			webView.evaluateJavaScript("setupVideoEndedHandler();")
		}

		if viewIfLoaded?.window != nil, (delegate as? ArticleViewController)?.isCurrentWebViewController(self) ?? true {
			ArticlePrefetcher.shared.prefetchNextArticle(after: article, coordinator: coordinator)
		}
		delegate?.webViewControllerDidLoadArticle(self)
	}

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {

		preferences.allowsContentJavaScript = WebViewConfiguration.allowsContentJavaScript(for: article)

		if navigationAction.navigationType == .linkActivated {
			guard let url = navigationAction.request.url else {
				decisionHandler(.allow, preferences)
				return
			}

			// WebKit reports a tap on a not-yet-loaded video’s controls as a link activation
			// targeting the media source. The tap already operates the control — don’t open a browser.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/3788>
			if mediaSourceURLs.contains(url.absoluteString) {
				decisionHandler(.cancel, preferences)
				return
			}

			let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
			if components?.scheme == "http" || components?.scheme == "https" {
				decisionHandler(.cancel, preferences)
				if AppDefaults.shared.useSystemBrowser {
					UIApplication.shared.open(url, options: [:])
				} else {
					UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { didOpen in
						guard didOpen == false else {
							return
						}
						self.openURLInSafariViewController(url)
					}
				}

			} else if components?.scheme == "mailto" {
				decisionHandler(.cancel, preferences)

				guard let emailAddress = url.percentEncodedEmailAddress else {
					return
				}

				if UIApplication.shared.canOpenURL(emailAddress) {
					UIApplication.shared.open(emailAddress, options: [.universalLinksOnly: false], completionHandler: nil)
				} else {
					let alert = UIAlertController(title: NSLocalizedString("Error", comment: "Error"), message: NSLocalizedString("This device cannot send emails.", comment: "This device cannot send emails."), preferredStyle: .alert)
					alert.addAction(.init(title: NSLocalizedString("Dismiss", comment: "Dismiss"), style: .cancel, handler: nil))
					self.present(alert, animated: true, completion: nil)
				}
			} else if components?.scheme == "tel" {
				decisionHandler(.cancel, preferences)

				if UIApplication.shared.canOpenURL(url) {
					UIApplication.shared.open(url, options: [.universalLinksOnly: false], completionHandler: nil)
				}

			} else {
				decisionHandler(.allow, preferences)
			}
		} else {
			decisionHandler(.allow, preferences)
		}
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		webViewProcessDidTerminate = true
		fullReload()
	}

}

extension WebViewController {

	func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo, willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
		// We need to have at least an unimplemented WKUIDelegate assigned to the WKWebView.  This makes the
		// link preview launch Safari when the link preview is tapped.  In theory, you should be able to get
		// the link from the elementInfo above and transition to SFSafariViewController instead of launching
		// Safari.  As the time of this writing, the link in elementInfo is always nil.  ¯\_(ツ)_/¯
	}

	func webView(_ webView: WKWebView, contextMenuDidEndForElement elementInfo: WKContextMenuElementInfo) {
		mediaContextTargetState = nil
	}

	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		guard let url = navigationAction.request.url else {
			return nil
		}

		openURL(url)
		return nil
	}

}

// MARK: WKScriptMessageHandler

extension WebViewController: WKScriptMessageHandler {

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		switch message.name {
		case MessageName.imageWasShown:
			clickedImageCompletion?()
		case MessageName.imageWasClicked:
			guard canPresentArticleImage, message.webView === webView else {
				return
			}
			imageWasClicked(body: message.body as? String, fromThumbnail: message.world == ArticleMediaThumbnails.contentWorld)
		case MessageName.showFeedInspector:
			if let feed = article?.feed {
				coordinator.showFeedInspector(for: feed)
			}
		case MessageName.videoEnded:
			handleVideoEnded()
		case MessageName.nativeVideoPlay:
			logMediaEvent(.info, operation: "Native video handoff", message: "articleID=\(article?.articleID ?? "(nil)") document_current=\(message.webView === webView) main_frame=\(message.frameInfo.isMainFrame) article_current=\((delegate as? ArticleViewController)?.isCurrentWebViewController(self) == true) view_visible=\(viewIfLoaded?.window != nil) autoplay=\(AppDefaults.shared.autoplayVideo) cache_video=\(AppDefaults.shared.cacheVideoContent) prefetch=\(AppDefaults.shared.prefetchNextArticleContent)")
			guard message.webView === webView, message.frameInfo.isMainFrame,
				canPresentNativeVideo else {
				logMediaEvent(.info, operation: "Native video handoff", message: "outcome=ignored-inactive")
				return
			}
			handleNativeVideoPlay(body: message.body as? String)
		case MessageName.webViewPiPStarted:
			WebViewPiPManager.shared.pipDidStart(from: self)
		case MessageName.webViewPiPStopped:
			WebViewPiPManager.shared.pipDidStop(from: self)
		case MessageName.mediaLongPress:
			guard message.webView === webView, message.frameInfo.isMainFrame else {
				return
			}
			handleMediaLongPressMessage(message.body as? String)
		case MessageName.articleImageLoad:
			handleArticleImageLoadMessage(message.body)
		case MessageName.mediaContextTarget:
			guard message.webView === webView, message.frameInfo.isMainFrame,
				let report = message.body as? [String: Any],
				let reportedType = report["type"] as? String,
				let reportedPress = report["press"] as? Int else {
				return
			}
			// Keep the sequence even after a non-media press clears the target, so a late report
			// cannot restore the resource from an earlier press.
			guard reportedPress >= latestMediaContextPress else {
				logMediaEvent(.debug, operation: "Long press", message: "Ignored a target report from an earlier press")
				return
			}
			latestMediaContextPress = reportedPress

			guard let aTarget = MediaContextTarget(rawValue: reportedType) else {
				// A press that did not start on media clears the target, matching what WebKit will do.
				mediaContextTargetState = nil
				didConfigureContextMenuForCurrentPress = false
				logMediaEvent(.debug, operation: "Long press", message: "Cleared the media target for a non-media press")
				return
			}

			let isNewPress = mediaContextTargetState?.press != reportedPress
			if isNewPress {
				didConfigureContextMenuForCurrentPress = false
			}
			let resourceURL = report["resourceURL"] as? String
			mediaContextTargetState = MediaContextTargetState(target: aTarget, press: reportedPress, detectedAt: Date(), resourceURL: resourceURL?.isEmpty == false ? resourceURL : nil)
			logMediaEvent(.debug, operation: "Long press", message: "Detected \(aTarget.rawValue) target")
		case MessageName.mediaSourceURLs:
			mediaSourceURLs = Set((message.body as? [String]) ?? [])
		default:
			return
		}
	}

	private func handleVideoEnded() {
		appDelegate.resumeDatabaseProcessingIfNecessary()
		coordinator.selectNextArticle()
	}

	private var canPresentNativeVideo: Bool {
		AppDefaults.shared.useNativeVideoPlayer && videoPresentationEnabled && viewIfLoaded?.window != nil
			&& (delegate as? ArticleViewController)?.isCurrentWebViewController(self) == true
			&& presentedViewController == nil
			&& !VideoPlayerManager.shared.isPiPActive && !WebViewPiPManager.shared.isPiPActive
	}

	func startNativeVideoDirectly() {
		guard AppDefaults.shared.useNativeVideoPlayer, AppDefaults.shared.autoplayVideo,
			!nativeAutoplayStarted, !nativeAutoplayPending, let articleID = article?.articleID else {
			return
		}
		logMediaEvent(.info, operation: "Native video autoplay", message: "articleID=\(articleID) document=\(videoDocumentGeneration) ready=\(videoDocumentReady) eligible=\(canPresentNativeVideo) pip=\(VideoPlayerManager.shared.isPiPActive || WebViewPiPManager.shared.isPiPActive)")
		guard videoDocumentReady, canPresentNativeVideo, let webView else {
			return
		}
		let generation = videoDocumentGeneration
		nativeAutoplayPending = true
		webView.evaluateJavaScript("nativeVideoAutoplaySource();") { [weak self, weak webView] result, error in
			guard let self, generation == self.videoDocumentGeneration, articleID == self.article?.articleID,
				webView === self.webView else {
				return
			}
			self.nativeAutoplayPending = false
			guard self.canPresentNativeVideo, !self.nativeAutoplayStarted,
				AppDefaults.shared.useNativeVideoPlayer, AppDefaults.shared.autoplayVideo else {
				self.logMediaEvent(.info, operation: "Native video autoplay", message: "articleID=\(articleID) outcome=ignored-late-result")
				return
			}
			guard error == nil, let snapshot = result as? [String: Any] else {
				self.logMediaEvent(.warning, operation: "Native video autoplay", message: "articleID=\(articleID) outcome=script-error error=\(error?.localizedDescription ?? "invalid-result")")
				return
			}
			self.logMediaEvent(.info, operation: "Native video autoplay", message: "articleID=\(articleID) outcome=\(snapshot["outcome"] ?? "unknown") ready_state=\(snapshot["readyState"] ?? -1) network_state=\(snapshot["networkState"] ?? -1) error_code=\(snapshot["errorCode"] ?? 0)")
			guard snapshot["outcome"] as? String == "ready", let source = snapshot["url"] as? String else {
				return
			}
			self.handleNativeVideoPlay(body: source)
		}
	}

	func resumeNativeVideoAfterPageTransition() {
		guard viewIfLoaded?.window != nil,
			(delegate as? ArticleViewController)?.isCurrentWebViewController(self) == true,
			presentedViewController == nil, !isBeingDismissed,
			UIApplication.shared.applicationState == .active,
			!VideoPlayerManager.shared.isPiPActive, !WebViewPiPManager.shared.isPiPActive else {
			return
		}
		// Programmatic navigation can reuse this controller without viewDidAppear.
		if let webView {
			ArticleMediaThumbnails.configure(webView, active: true)
		}
		videoPreviewController.setActive(true)
		ArticlePrefetcher.shared.prefetchNextArticle(after: article, coordinator: coordinator)
		videoPresentationEnabled = true
		startNativeVideoDirectly()
	}

	private func handleNativeVideoPlay(body: String?) {
		guard var urlString = body else {
			return
		}

		// Resolve nnwVideoCache:// URL to original HTTP URL (scheme is lowercased by WebKit)
		if urlString.lowercased().hasPrefix("\(VideoCacheSchemeHandler.scheme.lowercased())://"),
		   let range = urlString.range(of: "?url=") {
			let extracted = String(urlString[range.upperBound...])
			urlString = extracted.removingPercentEncoding ?? extracted
		}

		guard let url = URL(string: urlString) else {
			return
		}
		guard let articleID = article?.articleID else {
			return
		}
		// Both direct autoplay and a queued webpage handoff share this entry point.
		// Mark before presenting: returning from the player must not autoplay again.
		nativeAutoplayStarted = true
		VideoPlayerManager.shared.play(url: url, articleID: articleID, from: self)
	}

}

// MARK:

extension WebViewController: UIScrollViewDelegate {

	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		scrollPositionQueue.add(self, #selector(scrollPositionDidChange))
	}

	@objc func scrollPositionDidChange() {
		let articleIDWhenAsked = article?.articleID
		webView?.evaluateJavaScript("window.scrollY") { (scrollY, error) in
			guard error == nil else { return }
			// A late callback must not record the previous article’s offset.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/5243>
			guard articleIDWhenAsked == self.article?.articleID else {
				return
			}
			let javascriptScrollY = scrollY as? Int ?? 0
			// I don't know why this value gets returned sometimes, but it is in error
			guard javascriptScrollY != 33554432 else { return }
			self.windowScrollY = javascriptScrollY
		}
	}
}

// MARK: JSON

private struct ImageClickMessage: Codable {
	let x: Float
	let y: Float
	let width: Float
	let height: Float
	let imageTitle: String?
	let imageURL: String
	let resourceURL: String?
}

// MARK: Private

private extension WebViewController {

	private var currentMediaContextTarget: MediaContextTarget? {
		guard let mediaContextTargetState,
			Date().timeIntervalSince(mediaContextTargetState.detectedAt) < 2 else {
			return nil
		}
		return mediaContextTargetState.target
	}

	/// Builds the menu WebKit shows, with resource actions appended after the actions the system
	/// provides. Passing nil for the target keeps the original menu exactly as it was.
	private func mediaContextMenuConfiguration(appending mediaContextTarget: MediaContextTarget?) -> UIContextMenuConfiguration {
		let resourceURL = mediaContextTargetState?.resourceURL
		return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggestedActions in
			guard let self, let mediaContextTarget, mediaContextTarget != .header else {
				return UIMenu(title: "", children: suggestedActions)
			}

			var menuElements = suggestedActions
			var resourceActions = [UIAction]()
			if let resourceURL {
				resourceActions.append(UIAction(title: NSLocalizedString("Copy Resource URL", comment: "Copy the original image or video URL"), image: UIImage(systemName: "doc.on.doc")) { _ in
					UIPasteboard.general.string = resourceURL
				})
			}
			resourceActions.append(self.saveAllMediaAction(for: mediaContextTarget))
			menuElements.append(UIMenu(title: "", options: .displayInline, children: resourceActions))
			return UIMenu(title: "", children: menuElements)
		}
	}

	private func isFeedHomePageLink(_ url: URL?) -> Bool {
		guard let url, let homePageURL = article?.feed?.homePageURL, !homePageURL.isEmpty else {
			return false
		}
		func normalize(_ value: String) -> String {
			var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
			while trimmed.hasSuffix("/") {
				trimmed.removeLast()
			}
			return trimmed.lowercased()
		}
		return normalize(url.absoluteString) == normalize(homePageURL)
	}

	private func goToFeedAction() -> UIAction? {
		guard let feed = article?.feed, !coordinator.timelineFeedIsEqualTo(feed) else {
			return nil
		}
		let title = NSLocalizedString("Go to Feed", comment: "Go to Feed")
		return UIAction(title: title, image: Assets.Images.openInSidebar) { [weak self] _ in
			self?.coordinator.discloseFeed(feed, animations: [.scroll, .navigation])
		}
	}

	private func goToFeedMenuConfiguration() -> UIContextMenuConfiguration? {
		guard let action = goToFeedAction() else {
			return nil
		}
		return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
			UIMenu(title: "", children: [action])
		}
	}

	private func presentGoToFeedActions() {
		guard let feed = article?.feed, !coordinator.timelineFeedIsEqualTo(feed) else {
			return
		}
		let title = NSLocalizedString("Go to Feed", comment: "Go to Feed")
		let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
		alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
			self?.coordinator.discloseFeed(feed, animations: [.scroll, .navigation])
		})
		alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel))
		if let webView {
			alert.popoverPresentationController?.sourceView = webView
			alert.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.minY + 40, width: 0, height: 0)
		}
		present(alert, animated: true)
	}

	/// WebKit exposes no hook to extend the media-controls menu, so a video gets an app-provided menu.
	/// The page reports the long press from JavaScript instead of this class adding its own gesture
	/// recognizer: an extra recognizer on the web view risks interfering with the image and link
	/// menus WebKit owns, and those must stay untouched.
	///
	/// Images are deliberately excluded here. WebKit owns their menu, and the context menu callback
	/// above extends it with Save All Images.
	func handleMediaLongPressMessage(_ body: String?) {
		let components = (body ?? "").split(separator: ":", maxSplits: 1)
		let reportedType = components.first.map(String.init)
		guard components.count > 1, let press = Int(components[1]),
			press == latestMediaContextPress,
			currentMediaContextTarget?.rawValue == reportedType else {
			return
		}
		if reportedType == MediaContextTarget.header.rawValue {
			if didConfigureContextMenuForCurrentPress {
				logMediaEvent(.debug, operation: "Long press", message: "WebKit already provided the header menu for this press")
				return
			}
			guard presentedViewController == nil else {
				logMediaEvent(.debug, operation: "Long press", message: "Another menu is already on screen")
				return
			}
			presentGoToFeedActions()
			return
		}
		guard reportedType == MediaContextTarget.video.rawValue else {
			return
		}
		guard !didConfigureContextMenuForCurrentPress else {
			logMediaEvent(.debug, operation: "Long press", message: "WebKit already provided the menu for this press")
			return
		}
		guard presentedViewController == nil else {
			logMediaEvent(.debug, operation: "Long press", message: "Another menu is already on screen")
			return
		}

		logMediaEvent(.info, operation: "Long press", message: "Showing the app video menu")
		presentVideoActions()
	}

	private func presentVideoActions() {
		let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
		if let resourceURL = mediaContextTargetState?.resourceURL {
			alert.addAction(UIAlertAction(title: NSLocalizedString("Copy Resource URL", comment: "Copy the original image or video URL"), style: .default) { _ in
				UIPasteboard.general.string = resourceURL
			})
		}
		alert.addAction(UIAlertAction(title: NSLocalizedString("Save All Videos", comment: "Save all article videos"), style: .default) { [weak self] _ in
			self?.logMediaEvent(.info, operation: "Save all", message: "Selected video batch save")
			self?.confirmSaveAllMedia(for: .video)
		})
		alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel))
		if let webView {
			alert.popoverPresentationController?.sourceView = webView
			alert.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
		}
		present(alert, animated: true)
	}

	private func saveAllMediaAction(for mediaContextTarget: MediaContextTarget) -> UIAction {
		let title = mediaContextTarget == .image ? NSLocalizedString("Save All Images", comment: "Save all article images") : NSLocalizedString("Save All Videos", comment: "Save all article videos")
		let image = mediaContextTarget == .image ? UIImage(systemName: "photo.on.rectangle") : UIImage(systemName: "video")
		return UIAction(title: title, image: image) { [weak self] _ in
			self?.logMediaEvent(.info, operation: "Save all", message: "Selected \(mediaContextTarget.rawValue) batch save")
			self?.confirmSaveAllMedia(for: mediaContextTarget)
		}
	}

	private func confirmSaveAllMedia(for mediaContextTarget: MediaContextTarget) {
		guard let webView, mediaSaveTask == nil, !isConfirmingMediaSave, !ArticleMediaSaveStage.isActive else {
			return
		}
		isConfirmingMediaSave = true

		webView.evaluateJavaScript("collectMediaForSaving('\(mediaContextTarget.rawValue)')") { [weak self] result, error in
			guard let self,
				error == nil,
				let result = result as? String,
				let data = result.data(using: .utf8),
				let snapshot = try? JSONDecoder().decode(MediaSnapshot.self, from: data) else {
				self?.isConfirmingMediaSave = false
				self?.logMediaEvent(.warning, operation: "Save all", message: "Could not read the media list from the article (error: \(error?.localizedDescription ?? "none"))")
				self?.presentMediaSaveResult(title: NSLocalizedString("Unable to Save Media", comment: "Unable to save media title"), message: NSLocalizedString("The article media could not be read.", comment: "Unable to read article media"))
				return
			}

			guard !snapshot.urls.isEmpty else {
				self.isConfirmingMediaSave = false
				self.logMediaEvent(.warning, operation: "Save all", message: "No supported \(mediaContextTarget.rawValue) media found; skipped \(snapshot.skipped) items")
				self.presentMediaSaveResult(title: NSLocalizedString("No Media to Save", comment: "No media to save title"), message: NSLocalizedString("No supported media was found on this page.", comment: "No supported article media"))
				return
			}

			let mediaName = mediaContextTarget == .image ? NSLocalizedString("images", comment: "Article image count") : NSLocalizedString("videos", comment: "Article video count")
			let title = mediaContextTarget == .image ? NSLocalizedString("Save All Images", comment: "Save all article images") : NSLocalizedString("Save All Videos", comment: "Save all article videos")
			let message = String.localizedStringWithFormat(NSLocalizedString("Save %ld %@ to your photo library?", comment: "Confirm saving all article media"), snapshot.urls.count, mediaName)
			let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
			alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel) { [weak self] _ in
				self?.isConfirmingMediaSave = false
			})
			alert.addAction(UIAlertAction(title: NSLocalizedString("Save", comment: "Save"), style: .default) { [weak self] _ in
				self?.isConfirmingMediaSave = false
				self?.saveMedia(snapshot: snapshot, type: mediaContextTarget)
			})
			self.present(alert, animated: true)
		}
	}

	private func saveMedia(snapshot: MediaSnapshot, type: MediaContextTarget) {
		guard mediaSaveTask == nil, !ArticleMediaSaveStage.isActive else {
			return
		}
		mediaSaveTask = Task { @MainActor [weak self] in
			guard let self else {
				return
			}
			await performMediaSave(snapshot: snapshot, type: type)
		}
	}

	private func performMediaSave(snapshot: MediaSnapshot, type: MediaContextTarget) async {
		defer { mediaSaveTask = nil }
		guard ArticleMediaSaveStage.begin(type: type.rawValue, requestedCount: snapshot.urls.count) else {
			return
		}
		defer {
			ArticleMediaSaveStage.finish()
			endMediaSaveBackgroundTask()
		}
		mediaSaveBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SaveArticleMedia") { [weak self] in
			self?.cancelMediaSave(reason: "background time expired")
			self?.endMediaSaveBackgroundTask()
		}
		logMediaEvent(.debug, operation: "Save all", message: "Saving \(snapshot.urls.count) \(type.rawValue) media; \(snapshot.skipped) skipped; sources: \(snapshot.urls.map { ArticleMediaLog.urlDescription($0, level: .debug) })")
		let iconData = type == .image ? renderedArticleIconData() : nil

		let mediaName = type == .image ? NSLocalizedString("Images", comment: "Saving images title") : NSLocalizedString("Videos", comment: "Saving videos title")
		let progressAlert = UIAlertController(title: String.localizedStringWithFormat(NSLocalizedString("Saving %@", comment: "Saving article media title"), mediaName), message: nil, preferredStyle: .alert)
		progressAlert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel) { [weak self] _ in
			self?.cancelMediaSave(reason: "user")
		})
		mediaSaveProgressAlert = progressAlert
		if let confirmation = presentedViewController as? UIAlertController {
			await dismissMediaSaveAlert(confirmation)
		}
		ArticleMediaSaveStage.update("presenting progress")
		if viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive {
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				present(progressAlert, animated: true) { continuation.resume() }
			}
		}

		let saver = ArticleMediaSaver()
		ArticleMediaSaveStage.update("authorizing")
		let authorized: Bool
		if Task.isCancelled {
			authorized = false
		} else {
			authorized = await saver.authorize()
		}
		guard authorized || Task.isCancelled else {
			logMediaEvent(.warning, operation: "Photo Library", message: "Add-only Photos permission was not granted")
			await dismissMediaSaveAlert(progressAlert)
			mediaSaveProgressAlert = nil
			pendingMediaSaveResult = (NSLocalizedString("Photo Library Access Required", comment: "Photo library access required title"), NSLocalizedString("Allow NetNewsWire to add media to your photo library and try again.", comment: "Photo library access required message"))
			presentPendingMediaSaveResult()
			return
		}
		if authorized {
			logMediaEvent(.debug, operation: "Save all", message: "Add-only Photos permission is granted")
		}

		if type == .image {
			logMediaEvent(.debug, operation: "Save all", message: iconData == nil ? "No feed icon data available for an nnwImageIcon source" : "Feed icon data is \(iconData?.count ?? 0) bytes")
		}

		let progress: @MainActor (Int, Int) -> Void = { [weak self] current, total in
			self?.mediaSaveProgressAlert?.message = String.localizedStringWithFormat(NSLocalizedString("Saving %ld of %ld", comment: "Article media saving progress"), current, total)
		}

		let result: ArticleMediaSaver.Result
		if type == .image {
			result = await saver.saveImages(sources: snapshot.urls, iconData: iconData, skippedCount: snapshot.skipped, progress: progress)
		} else {
			result = await saver.saveVideos(sources: snapshot.urls, skippedCount: snapshot.skipped, progress: progress)
		}

		ArticleMediaSaveStage.update("finalizing")
		endMediaSaveBackgroundTask()
		await dismissMediaSaveAlert(progressAlert)
		mediaSaveProgressAlert = nil
		logMediaEvent(result.failedCount > 0 ? .warning : .info, operation: "Save all", message: "Saved \(result.savedCount) of \(result.requestedCount); failed \(result.failedCount); skipped \(result.skippedCount); cancelled \(result.cancelledCount)")
		let title = result.wasCancelled ? NSLocalizedString("Media Save Cancelled", comment: "Article media save cancelled title") : NSLocalizedString("Media Saved", comment: "Article media saved title")
		pendingMediaSaveResult = (title, mediaSaveResultMessage(result))
		presentPendingMediaSaveResult()
	}

	private func cancelMediaSave(reason: String) {
		guard let mediaSaveTask, !mediaSaveTask.isCancelled else {
			return
		}
		ArticleMediaSaveStage.cancel(reason: reason)
		logMediaEvent(.info, operation: "Save all", message: "Cancellation requested: \(reason)")
		mediaSaveTask.cancel()
	}

	private func endMediaSaveBackgroundTask() {
		guard mediaSaveBackgroundTask != .invalid else {
			return
		}
		let identifier = mediaSaveBackgroundTask
		mediaSaveBackgroundTask = .invalid
		UIApplication.shared.endBackgroundTask(identifier)
	}

	private func dismissMediaSaveAlert(_ alert: UIAlertController) async {
		if alert.isBeingDismissed, let transition = alert.transitionCoordinator {
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				var didResume = false
				func resumeOnce() {
					guard !didResume else { return }
					didResume = true
					continuation.resume()
				}
				// UIKit may call completion even when registering alongside animation returns false.
				if !transition.animate(alongsideTransition: nil, completion: { _ in resumeOnce() }) {
					resumeOnce()
				}
			}
		} else if alert.presentingViewController != nil {
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				alert.dismiss(animated: true) { continuation.resume() }
			}
		}
	}

	@objc private func presentPendingMediaSaveResult() {
		guard let result = pendingMediaSaveResult,
			viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else {
			return
		}
		guard presentedViewController == nil, !isBeingDismissed, !isBeingPresented else {
			guard !isMediaSaveResultPresentationScheduled else { return }
			isMediaSaveResultPresentationScheduled = true
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
				self?.isMediaSaveResultPresentationScheduled = false
				self?.presentPendingMediaSaveResult()
			}
			return
		}
		pendingMediaSaveResult = nil
		presentMediaSaveResult(title: result.title, message: result.message)
	}

	func renderedArticleIconData() -> Data? {
		guard let iconImage = article?.iconImage() else {
			return nil
		}

		let iconView = IconView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
		iconView.iconImage = iconImage
		return iconView.asImage().dataRepresentation()
	}

	func mediaSaveResultMessage(_ result: ArticleMediaSaver.Result) -> String {
		var components = [String.localizedStringWithFormat(NSLocalizedString("Saved %ld of %ld.", comment: "Article media save result"), result.savedCount, result.requestedCount)]
		if result.failedCount > 0 {
			components.append(String.localizedStringWithFormat(NSLocalizedString("%ld failed.", comment: "Article media failed count"), result.failedCount))
		}
		if result.skippedCount > 0 {
			components.append(String.localizedStringWithFormat(NSLocalizedString("%ld skipped.", comment: "Article media skipped count"), result.skippedCount))
		}
		if result.cancelledCount > 0 {
			components.append(String.localizedStringWithFormat(NSLocalizedString("%ld cancelled.", comment: "Article media cancelled count"), result.cancelledCount))
		}
		return components.joined(separator: " ")
	}

	func presentMediaSaveResult(title: String, message: String) {
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK"), style: .default))
		present(alert, animated: true)
	}

	func logMediaEvent(_ level: ErrorLogLevel, operation: String, message: String) {
		ArticleMediaLog.log(level, operation: operation, message: message)
	}

	func handleArticleImageLoadMessage(_ body: Any) {
		guard let event = ArticleImageDiagnostics.imageLoadEvent(from: body) else {
			return
		}
		articleImageLoadTracker?.events.append(event)
		ArticleMediaLog.logImageLoad(event)
		if event.isFailure {
			let source = event.source
			Task { @MainActor in
				let probe = await ArticleImageProbe.describe(source)
				ArticleMediaLog.log(.warning, operation: "Image probe", message: probe)
			}
		}
	}

	func scheduleArticleImageSummary(documentURL: String) {
		articleImageSummaryTask?.cancel()
		articleImageSummaryTask = Task { @MainActor in
			try? await Task.sleep(for: .seconds(2))
			guard !Task.isCancelled, let tracker = articleImageLoadTracker else {
				return
			}
			ArticleMediaLog.logLoadSummary(
				articleID: tracker.articleID,
				link: tracker.link,
				loadBaseURL: tracker.loadBaseURL,
				htmlBaseURL: tracker.htmlBaseURL,
				documentURL: documentURL,
				expectedCount: tracker.sources.count,
				events: tracker.events
			)
		}
	}

	func loadWebView(replaceExistingWebView: Bool = false) {
		guard isViewLoaded else { return }

		// Never render into a web view whose content process died — the load
		// can fail silently, leaving the article view blank.
		if !replaceExistingWebView, !webViewProcessDidTerminate, let webView = webView {
			self.renderPage(webView)
			return
		}

		webViewProcessDidTerminate = false

		coordinator.webViewProvider.dequeueWebView { webView in

			webView.ready {

				// Add the webview
				webView.translatesAutoresizingMaskIntoConstraints = false
				self.view.insertSubview(webView, at: 0)
				NSLayoutConstraint.activate([
					self.view.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
					self.view.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
					self.view.topAnchor.constraint(equalTo: webView.topAnchor),
					self.view.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
				])

				// UISplitViewController reports the wrong size to WKWebView which can cause horizontal
				// rubberbanding on the iPad.  This interferes with our UIPageViewController preventing
				// us from easily swiping between WKWebViews.  This hack fixes that.
				webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: -1, bottom: 0, right: 0)

				webView.scrollView.setZoomScale(1.0, animated: false)

				self.view.setNeedsLayout()
				self.view.layoutIfNeeded()

				// Configure the webview
				webView.navigationDelegate = self
				webView.uiDelegate = self
				webView.scrollView.delegate = self
				self.configureContextMenuInteraction()

				// Remove possible existing message handlers
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.imageWasClicked)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.imageWasShown)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.showFeedInspector)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.videoEnded)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.nativeVideoPlay)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.webViewPiPStarted)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.webViewPiPStopped)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.mediaContextTarget)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.mediaLongPress)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.articleImageLoad)
				webView.configuration.userContentController.removeScriptMessageHandler(forName: MessageName.mediaSourceURLs)

				// The thumbnail script also works when article JavaScript is disabled.
				for name in [MessageName.imageWasClicked, MessageName.nativeVideoPlay] {
					webView.configuration.userContentController.removeScriptMessageHandler(forName: name, contentWorld: ArticleMediaThumbnails.contentWorld)
					webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), contentWorld: ArticleMediaThumbnails.contentWorld, name: name)
				}

				// Add handlers
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.imageWasClicked)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.imageWasShown)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.showFeedInspector)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.videoEnded)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.nativeVideoPlay)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.webViewPiPStarted)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.webViewPiPStopped)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.mediaContextTarget)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.mediaLongPress)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.articleImageLoad)
				webView.configuration.userContentController.add(WrapperScriptMessageHandler(self), name: MessageName.mediaSourceURLs)

				self.renderPage(webView)
			}
		}
	}

	func renderPage(_ webView: PreloadedWebView?) {
		guard let webView = webView else { return }

		// Rendering during an element-fullscreen transition triggers a WebKit
		// RELEASE_ASSERT. Exit fullscreen first — the strong webView capture
		// keeps it alive until then.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5382>
		if webView.fullscreenState != .notInFullscreen {
			webView.closeAllMediaPresentations { [weak self] in
				self?.renderPage(webView)
			}
			return
		}

		let theme = ArticleThemesManager.shared.currentTheme
		let rendering: ArticleRenderer.Rendering

		if let articleExtractor = articleExtractor, articleExtractor.state == .processing {
			rendering = ArticleRenderer.loadingHTML(theme: theme)
		} else if let articleExtractor = articleExtractor, articleExtractor.state == .failedToParse, let article = article {
			rendering = ArticleRenderer.articleHTML(article: article, theme: theme)
		} else if let article = article, let extractedArticle = extractedArticle {
			if isShowingExtractedArticle {
				rendering = ArticleRenderer.articleHTML(article: article, extractedArticle: extractedArticle, theme: theme)
			} else {
				rendering = ArticleRenderer.articleHTML(article: article, theme: theme)
			}
		} else if let article = article {
			rendering = ArticleRenderer.articleHTML(article: article, theme: theme)
		} else {
			rendering = ArticleRenderer.noSelectionHTML(theme: theme)
		}

		let substitutions = [
			"title": rendering.title,
			"baseURL": rendering.baseURL,
			"style": rendering.style,
			"body": rendering.html,
			"windowScrollY": String(windowScrollY)
		]

		var html = try! MacroProcessor.renderedText(withTemplate: ArticleRenderer.page.html, substitutions: substitutions)
		html = ArticleRenderingSpecialCases.filterHTMLIfNeeded(baseURL: rendering.baseURL, html: html)

		// Uncomment when you want to debug HTML and CSS for an article.
		// If you’re running in the simulator, this will write the file to a location on your Mac.
//		let debugFolderURL = AppConfig.dataSubfolder(named: "debug")
//		let fileURL = debugFolderURL.appendingPathComponent("article.html")
//		try? html.write(to: fileURL, atomically: true, encoding: .utf8)
//		print("article.html written to \(fileURL.path)")

		if AppDefaults.shared.cacheVideoContent {
			let (rewrittenHTML, uncachedVideoURLs) = VideoCacheHTMLRewriter.rewriteForCaching(html)
			html = rewrittenHTML
			if !uncachedVideoURLs.isEmpty {
				VideoCacheSchemeHandler.cacheURLsInBackground(uncachedVideoURLs)
			}
		}

		if AppDefaults.shared.prefetchNextArticleContent {
			let (rewrittenHTML, uncachedImageURLs) = VideoCacheHTMLRewriter.rewriteImagesForCaching(html)
			html = rewrittenHTML
			if !uncachedImageURLs.isEmpty {
				VideoCacheSchemeHandler.cacheURLsInBackground(uncachedImageURLs)
			}
		}

		WebViewConfiguration.addContentBlockingRules(to: webView)
		if let article {
			let imageSources = ArticleImageDiagnostics.imageSources(inHTML: html)
			articleImageSummaryTask?.cancel()
			articleImageLoadTracker = ArticleImageLoadTracker(
				articleID: article.articleID,
				link: article.preferredLink,
				loadBaseURL: rendering.baseURL,
				htmlBaseURL: rendering.baseURL,
				sources: imageSources
			)
			ArticleMediaLog.logRender(
				articleID: article.articleID,
				link: article.preferredLink,
				loadBaseURL: rendering.baseURL,
				htmlBaseURL: rendering.baseURL,
				imageSources: imageSources
			)
		} else {
			articleImageLoadTracker = nil
		}
		videoDocumentReady = false
		videoPreviewController.documentWillChange()
		articleTranslationController.documentWillChange()
		videoDocumentGeneration += 1
		mediaContextTargetState = nil
		latestMediaContextPress = 0
		didConfigureContextMenuForCurrentPress = false
		nativeAutoplayPending = false
		webView.loadHTMLString(html, baseURL: URL(string: rendering.baseURL))
	}

	func finalScrollPosition(scrollingUp: Bool) -> CGFloat {
		guard let webView = webView else { return 0 }

		if scrollingUp {
			return -webView.scrollView.safeAreaInsets.top
		} else {
			return webView.scrollView.contentSize.height - webView.scrollView.bounds.height + webView.scrollView.safeAreaInsets.bottom
		}
	}

	func startArticleExtractor() {
		guard articleExtractor == nil else { return }
		if let link = article?.preferredLink, let extractor = ArticleExtractor(link, delegate: self) {
			extractor.process()
			articleExtractor = extractor
			articleExtractorButtonState = .animated
		}
	}

	func stopArticleExtractor() {
		articleExtractor?.cancel()
		articleExtractor = nil
		isShowingExtractedArticle = false
		articleExtractorButtonState = .off
	}

	func reloadArticleImage() {
		guard let article = article else { return }

		var components = URLComponents()
		components.scheme = ArticleRenderer.imageIconScheme
		components.path = article.articleID

		if let imageSrc = components.string {
			webView?.evaluateJavaScript("reloadArticleImage(\"\(imageSrc)\")")
		}
	}

	func imageWasClicked(body: String?, fromThumbnail: Bool = false) {
		guard canPresentArticleImage, let article, let webView, let body else {
			return
		}

		let data = Data(body.utf8)
		guard let clickMessage = try? JSONDecoder().decode(ImageClickMessage.self, from: data) else {
			return
		}

		guard let imageURL = URL(string: clickMessage.imageURL) else { return }

		invalidateImageDownload()
		let generation = imageRequestGeneration
		imageDownloadTask = Task { [weak self] in
			let imageData: Data?
			if imageURL.scheme == "data" {
				imageData = try? ArticleMediaSaver.dataURLData(clickMessage.imageURL)
			} else {
				imageData = try? await Downloader.shared.download(imageURL, userAgentStyle: .browser).data
			}
			// A late completion must not present the viewer over a different article
			// or a returning app.
			guard !Task.isCancelled, let self, self.canPresentArticleImage,
				  self.imageRequestGeneration == generation, self.article === article, self.webView === webView,
				  let data = imageData, !data.isEmpty,
				  let image = UIImage(data: data) else {
				return
			}
			self.imageOpenedFromThumbnail = fromThumbnail
			self.showFullScreenImage(image: image, clickMessage: clickMessage, webView: webView)
		}
	}

	private func showFullScreenImage(image: UIImage, clickMessage: ImageClickMessage, webView: WKWebView) {

		let y = CGFloat(clickMessage.y) + webView.safeAreaInsets.top
		let rect = CGRect(x: CGFloat(clickMessage.x), y: y, width: CGFloat(clickMessage.width), height: CGFloat(clickMessage.height))
		transition.originFrame = webView.convert(rect, to: nil)

		if navigationController?.navigationBar.isHidden ?? false {
			transition.maskFrame = webView.convert(webView.frame, to: nil)
		} else {
			transition.maskFrame = webView.convert(webView.safeAreaLayoutGuide.layoutFrame, to: nil)
		}

		transition.originImage = image

		coordinator.showFullScreenImage(image: image, imageTitle: clickMessage.imageTitle, resourceURL: clickMessage.resourceURL, transition: transition, saveAllImagesHandler: { [weak self] in
			self?.confirmSaveAllMedia(for: .image)
		})
	}

	func stopMediaPlayback(_ webView: WKWebView) {
		webView.evaluateJavaScript("stopMediaPlayback();")
	}

	func configureTopShowBarsView() {
		topShowBarsView = UIView()
		topShowBarsView.backgroundColor = .clear
		topShowBarsView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(topShowBarsView)

		if AppDefaults.shared.logicalArticleFullscreenEnabled {
			topShowBarsViewConstraint = view.topAnchor.constraint(equalTo: topShowBarsView.bottomAnchor, constant: -44.0)
		} else {
			topShowBarsViewConstraint = view.topAnchor.constraint(equalTo: topShowBarsView.bottomAnchor, constant: 0.0)
		}

		NSLayoutConstraint.activate([
			topShowBarsViewConstraint,
			view.leadingAnchor.constraint(equalTo: topShowBarsView.leadingAnchor),
			view.trailingAnchor.constraint(equalTo: topShowBarsView.trailingAnchor),
			topShowBarsView.heightAnchor.constraint(equalToConstant: 44.0)
		])
		topShowBarsView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showBars(_:))))
	}

	func configureBottomShowBarsView() {
		bottomShowBarsView = UIView()
		bottomShowBarsView.backgroundColor = .clear
		bottomShowBarsView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(bottomShowBarsView)
		if AppDefaults.shared.logicalArticleFullscreenEnabled {
			bottomShowBarsViewConstraint = view.bottomAnchor.constraint(equalTo: bottomShowBarsView.topAnchor, constant: 44.0)
		} else {
			bottomShowBarsViewConstraint = view.bottomAnchor.constraint(equalTo: bottomShowBarsView.topAnchor, constant: 0.0)
		}
		NSLayoutConstraint.activate([
			bottomShowBarsViewConstraint,
			view.leadingAnchor.constraint(equalTo: bottomShowBarsView.leadingAnchor),
			view.trailingAnchor.constraint(equalTo: bottomShowBarsView.trailingAnchor),
			bottomShowBarsView.heightAnchor.constraint(equalToConstant: 44.0)
		])
		bottomShowBarsView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showBars(_:))))
	}

	func updateBottomSafeAreaForFullScreen() {
		let rawBottom = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
		additionalSafeAreaInsets.bottom = -rawBottom
	}

	/// Hide or show the toolbar scroll edge effect at the bottom of the web view.
	///
	/// Hidden when entering fullscreen so a residual effect doesn't obscure the
	/// bottom of the article.
	///
	/// <https://github.com/Ranchero-Software/NetNewsWire/issues/5298>
	func setBottomScrollEdgeEffectHidden(_ hidden: Bool) {
		guard #available(iOS 26, *) else {
			return
		}
		guard let scrollView = webView?.scrollView else {
			return
		}
		scrollView.bottomEdgeEffect.isHidden = hidden
	}

	func configureContextMenuInteraction() {
		if isFullScreenAvailable {
			if navigationController?.isNavigationBarHidden ?? false {
				webView?.addInteraction(contextMenuInteraction)
			} else {
				webView?.removeInteraction(contextMenuInteraction)
			}
		}
	}

	func contextMenuPreviewProvider() -> UIViewController {
		let previewProvider = UIStoryboard.main.instantiateController(ofType: ContextMenuPreviewViewController.self)
		previewProvider.article = article
		return previewProvider
	}

	func prevArticleAction() -> UIAction? {
		guard coordinator.isPrevArticleAvailable else { return nil }
		let title = NSLocalizedString("Previous Article", comment: "Previous Article")
		return UIAction(title: title, image: Assets.Images.prevArticle) { [weak self] _ in
			self?.coordinator.selectPrevArticle()
		}
	}

	func nextArticleAction() -> UIAction? {
		guard coordinator.isNextArticleAvailable else { return nil }
		let title = NSLocalizedString("Next Article", comment: "Next Article")
		return UIAction(title: title, image: Assets.Images.nextArticle) { [weak self] _ in
			self?.coordinator.selectNextArticle()
		}
	}

	func toggleReadAction() -> UIAction? {
		guard let article = article, !article.status.read || article.isAvailableToMarkUnread else { return nil }

		let title = article.status.read ? NSLocalizedString("Mark as Unread", comment: "Command") : NSLocalizedString("Mark as Read", comment: "Command")
		let readImage = article.status.read ? Assets.Images.circleClosed : Assets.Images.circleOpen
		return UIAction(title: title, image: readImage) { [weak self] _ in
			self?.coordinator.toggleReadForCurrentArticle()
		}
	}

	func toggleStarredAction() -> UIAction {
		let starred = article?.status.starred ?? false
		let title = starred ? NSLocalizedString("Mark as Unstarred", comment: "Command") : NSLocalizedString("Mark as Starred", comment: "Command")
		let starredImage = starred ? Assets.Images.starOpen : Assets.Images.starClosed
		return UIAction(title: title, image: starredImage) { [weak self] _ in
			self?.coordinator.toggleStarredForCurrentArticle()
		}
	}

	func nextUnreadArticleAction() -> UIAction? {
		guard coordinator.isNextUnreadAvailable else { return nil }
		let title = NSLocalizedString("Next Unread Article", comment: "Next Unread Article")
		return UIAction(title: title, image: Assets.Images.nextUnread) { [weak self] _ in
			self?.coordinator.selectNextUnread()
		}
	}

	func toggleArticleExtractorAction() -> UIAction {
		let extracted = articleExtractorButtonState == .on
		let title = extracted ? NSLocalizedString("Show Feed Article", comment: "Show Feed Article") : NSLocalizedString("Show Reader View", comment: "Show Reader View")
		let extractorImage = extracted ? Assets.Images.articleExtractorOff : Assets.Images.articleExtractorOn
		return UIAction(title: title, image: extractorImage) { [weak self] _ in
			self?.toggleArticleExtractor()
		}
	}

	func shareAction() -> UIAction {
		let title = NSLocalizedString("Share", comment: "Share button")
		return UIAction(title: title, image: Assets.Images.share) { [weak self] _ in
			self?.showActivityDialog()
		}
	}

	// If the resource cannot be opened with an installed app, present the web view.
	func openURL(_ url: URL) {
		UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { didOpen in
			assert(Thread.isMainThread)
			guard didOpen == false else {
				return
			}
			self.openURLInSafariViewController(url)
		}
	}

	func openURLInSafariViewController(_ url: URL) {
		guard let viewController = SFSafariViewController.safeSafariViewController(url) else {
			return
		}
		// Apply the resolved userInterfaceStyle before presenting to avoid a white flash in dark mode.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5383>
		viewController.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
		viewController.delegate = self
		coordinator?.beganBrowsing(url: url)
		present(viewController, animated: true)
	}
}

// MARK: SFSafariViewControllerDelegate

extension WebViewController: @preconcurrency SFSafariViewControllerDelegate {

	func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
		coordinator?.endedBrowsing()
	}
}

// MARK: Find in Article

private struct FindInArticleOptions: Codable {
	var text: String
	var caseSensitive = false
	var regex = false
}

internal struct FindInArticleState: Codable {
	struct WebViewClientRect: Codable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double
	}

	struct FindInArticleResult: Codable {
		let rects: [WebViewClientRect]
		let bounds: WebViewClientRect
		let index: UInt
		let matchGroups: [String]
	}

	let index: UInt?
	let results: [FindInArticleResult]
	let count: UInt
}

extension WebViewController {

	func searchText(_ searchText: String, completionHandler: @escaping (FindInArticleState) -> Void) {
		guard let json = try? JSONEncoder().encode(FindInArticleOptions(text: searchText)) else {
			return
		}
		let encoded = json.base64EncodedString()

		webView?.evaluateJavaScript("updateFind(\"\(encoded)\")") { (result, error) in
			guard error == nil,
				let b64 = result as? String,
				let rawData = Data(base64Encoded: b64),
				let findState = try? JSONDecoder().decode(FindInArticleState.self, from: rawData) else {
					return
			}

			completionHandler(findState)
		}
	}

	func endSearch() {
		webView?.evaluateJavaScript("endFind()")
	}

	func selectNextSearchResult() {
		webView?.evaluateJavaScript("selectNextResult()")
	}

	func selectPreviousSearchResult() {
		webView?.evaluateJavaScript("selectPreviousResult()")
	}

}

private final class ArticleImageLoadTracker {
	let articleID: String
	let link: String?
	let loadBaseURL: String
	let htmlBaseURL: String
	let sources: [String]
	var events: [ArticleImageDiagnostics.ImageLoadEvent] = []

	init(articleID: String, link: String?, loadBaseURL: String, htmlBaseURL: String, sources: [String]) {
		self.articleID = articleID
		self.link = link
		self.loadBaseURL = loadBaseURL
		self.htmlBaseURL = htmlBaseURL
		self.sources = sources
	}
}
