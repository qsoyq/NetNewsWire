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

@MainActor protocol WebViewControllerDelegate: AnyObject {
	func webViewController(_: WebViewController, articleExtractorButtonStateDidUpdate: ArticleExtractorButtonState)
}

final class WebViewController: UIViewController {

	private struct MessageName {
		static let imageWasClicked = "imageWasClicked"
		static let imageWasShown = "imageWasShown"
		static let showFeedInspector = "showFeedInspector"
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

	private lazy var contextMenuInteraction = UIContextMenuInteraction(delegate: self)
	private var isFullScreenAvailable: Bool {
		return AppDefaults.shared.articleFullscreenAvailable && traitCollection.userInterfaceIdiom == .phone && coordinator.isRootSplitCollapsed
	}
	private lazy var articleIconSchemeHandler = ArticleIconSchemeHandler(coordinator: coordinator)
	private lazy var transition = ImageTransition(controller: self)
	private var clickedImageCompletion: (() -> Void)?
	private var mediaContextTargetState: MediaContextTargetState?
	private var didConfigureContextMenuForCurrentPress = false
	private var mediaSaveProgressAlert: UIAlertController?
	private var articleImageLoadTracker: ArticleImageLoadTracker?
	private var articleImageSummaryTask: Task<Void, Never>?

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

	override func viewDidLoad() {
		super.viewDidLoad()

		NotificationCenter.default.addObserver(self, selector: #selector(feedIconDidBecomeAvailable(_:)), name: .feedIconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(avatarDidBecomeAvailable(_:)), name: .AvatarDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .FaviconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(currentArticleThemeDidChangeNotification(_:)), name: .CurrentArticleThemeDidChangeNotification, object: nil)

		// Configure the tap zones
		configureTopShowBarsView()
		configureBottomShowBarsView()

		loadWebView()
	}

	// MARK: Notifications

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

	// MARK: Actions

	@objc func showBars(_ sender: Any) {
		showBars()
	}

	// MARK: API

	func setArticle(_ article: Article?, updateView: Bool = true) {
		stopArticleExtractor()

		if article != self.article {
			self.article = article
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
		webView?.evaluateJavaScript("hideClickedImage();")
	}

	func showClickedImage(completion: @escaping () -> Void) {
		clickedImageCompletion = completion
		webView?.evaluateJavaScript("showClickedImage();")
	}

	func fullReload() {
		loadWebView(replaceExistingWebView: true)
	}

	func showBars() {
		AppDefaults.shared.articleFullscreenEnabled = false
		coordinator.showStatusBar()
		topShowBarsViewConstraint?.constant = 0
		bottomShowBarsViewConstraint?.constant = 0
		navigationController?.setNavigationBarHidden(false, animated: true)
		navigationController?.setToolbarHidden(false, animated: true)
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

	func stopWebViewActivity() {
		if let webView = webView {
			if !VideoPlayerManager.shared.isPiPActive && !WebViewPiPManager.shared.isPiPActive {
				stopMediaPlayback(webView)
			}
			cancelImageLoad(webView)
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
		stopArticleExtractor()
		articleExtractorButtonState = .error
		loadWebView()
	}

	func articleExtractionDidComplete(extractedArticle: ExtractedArticle) {
		if articleExtractor?.state != .cancelled {
			self.extractedArticle = extractedArticle
			if let restoreWindowScrollY = restoreWindowScrollY {
				windowScrollY = restoreWindowScrollY
			}
			isShowingExtractedArticle = true
			loadWebView()
			articleExtractorButtonState = .on
		}
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
		if AppDefaults.shared.autoplayVideo {
			webView.evaluateJavaScript("setupVideoAutoplay();")
		}
		if AppDefaults.shared.autoGotoNextAfterVideo {
			webView.evaluateJavaScript("setupVideoEndedHandler();")
		}

		ArticlePrefetcher.shared.prefetchNextArticle(after: article, coordinator: coordinator)
	}

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {

		if navigationAction.navigationType == .linkActivated {
			guard let url = navigationAction.request.url else {
				decisionHandler(.allow)
				return
			}

			let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
			if components?.scheme == "http" || components?.scheme == "https" {
				decisionHandler(.cancel)
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
				decisionHandler(.cancel)

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
				decisionHandler(.cancel)

				if UIApplication.shared.canOpenURL(url) {
					UIApplication.shared.open(url, options: [.universalLinksOnly: false], completionHandler: nil)
				}

			} else {
				decisionHandler(.allow)
			}
		} else {
			decisionHandler(.allow)
		}
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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
			imageWasClicked(body: message.body as? String)
		case MessageName.showFeedInspector:
			if let feed = article?.feed {
				coordinator.showFeedInspector(for: feed)
			}
		case MessageName.videoEnded:
			handleVideoEnded()
		case MessageName.nativeVideoPlay:
			handleNativeVideoPlay(body: message.body as? String)
		case MessageName.webViewPiPStarted:
			WebViewPiPManager.shared.pipDidStart(from: self)
		case MessageName.webViewPiPStopped:
			WebViewPiPManager.shared.pipDidStop(from: self)
		case MessageName.mediaLongPress:
			handleMediaLongPressMessage(message.body as? String)
		case MessageName.articleImageLoad:
			handleArticleImageLoadMessage(message.body)
		case MessageName.mediaContextTarget:
			// Reports carry "<type>:<press>" so a straggler from an earlier press can never overwrite
			// the media element the current press is about to build a menu for.
			let components = (message.body as? String ?? "").split(separator: ":", maxSplits: 1)
			let reportedType = components.first.map(String.init) ?? ""
			let reportedPress = components.count > 1 ? Int(components[1]) : nil

			// A straggler from an earlier press must never change the target of the press in progress.
			let isFromEarlierPress = reportedPress != nil && mediaContextTargetState != nil && reportedPress! < mediaContextTargetState!.press

			guard let aTarget = MediaContextTarget(rawValue: reportedType) else {
				guard !isFromEarlierPress else {
					logMediaEvent(.debug, operation: "Long press", message: "Ignored a non-media report from an earlier press")
					return
				}
				// A press that did not start on media clears the target, matching what WebKit will do.
				mediaContextTargetState = nil
				didConfigureContextMenuForCurrentPress = false
				logMediaEvent(.debug, operation: "Long press", message: "Cleared the media target for a non-media press")
				return
			}

			guard !isFromEarlierPress else {
				logMediaEvent(.debug, operation: "Long press", message: "Ignored \(aTarget.rawValue) report from an earlier press")
				return
			}

			let isNewPress = mediaContextTargetState?.press != reportedPress
			if isNewPress {
				didConfigureContextMenuForCurrentPress = false
			}
			mediaContextTargetState = MediaContextTargetState(target: aTarget, press: reportedPress ?? 0, detectedAt: Date())
			logMediaEvent(.debug, operation: "Long press", message: "Detected \(aTarget.rawValue) target")
		default:
			return
		}
	}

	private func handleVideoEnded() {
		appDelegate.resumeDatabaseProcessingIfNecessary()
		coordinator.selectNextArticle()
	}

	private func startNativeVideoDirectly() {
		guard let articleID = article?.articleID,
			  let body = article?.body,
			  let url = VideoPlayerManager.extractFirstVideoURL(from: body) else {
			return
		}
		VideoPlayerManager.shared.play(url: url, articleID: articleID, from: self)
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
		VideoPlayerManager.shared.play(url: url, articleID: articleID, from: self)
	}

}

// MARK: UIViewControllerTransitioningDelegate

extension WebViewController: UIViewControllerTransitioningDelegate {

	func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
		transition.presenting = true
		return transition
	}

	func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
		transition.presenting = false
		return transition
	}
}

// MARK:

extension WebViewController: UIScrollViewDelegate {

	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		scrollPositionQueue.add(self, #selector(scrollPositionDidChange))
	}

	@objc func scrollPositionDidChange() {
		webView?.evaluateJavaScript("window.scrollY") { (scrollY, error) in
			guard error == nil else { return }
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

	/// Builds the menu WebKit shows, with the batch save action appended after the actions the system
	/// provides. Passing nil for the target keeps the original menu exactly as it was.
	private func mediaContextMenuConfiguration(appending mediaContextTarget: MediaContextTarget?) -> UIContextMenuConfiguration {
		UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggestedActions in
			guard let self, let mediaContextTarget, mediaContextTarget != .header else {
				return UIMenu(title: "", children: suggestedActions)
			}

			var menuElements = suggestedActions
			menuElements.append(UIMenu(title: "", options: .displayInline, children: [self.saveAllMediaAction(for: mediaContextTarget)]))
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
		if reportedType == MediaContextTarget.header.rawValue {
			if components.count > 1, let press = Int(components[1]), let mediaContextTargetState, press != mediaContextTargetState.press {
				logMediaEvent(.debug, operation: "Long press", message: "Ignored a header report from an earlier press")
				return
			}
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
		if components.count > 1, let press = Int(components[1]), let mediaContextTargetState, press != mediaContextTargetState.press {
			logMediaEvent(.debug, operation: "Long press", message: "Ignored a video report from an earlier press")
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
		guard let webView else {
			return
		}

		webView.evaluateJavaScript("collectMediaForSaving('\(mediaContextTarget.rawValue)')") { [weak self] result, error in
			guard let self,
				error == nil,
				let result = result as? String,
				let data = result.data(using: .utf8),
				let snapshot = try? JSONDecoder().decode(MediaSnapshot.self, from: data) else {
				self?.logMediaEvent(.warning, operation: "Save all", message: "Could not read the media list from the article (error: \(error?.localizedDescription ?? "none"))")
				self?.presentMediaSaveResult(title: NSLocalizedString("Unable to Save Media", comment: "Unable to save media title"), message: NSLocalizedString("The article media could not be read.", comment: "Unable to read article media"))
				return
			}

			guard !snapshot.urls.isEmpty else {
				self.logMediaEvent(.warning, operation: "Save all", message: "No supported \(mediaContextTarget.rawValue) media found; skipped \(snapshot.skipped) items")
				self.presentMediaSaveResult(title: NSLocalizedString("No Media to Save", comment: "No media to save title"), message: NSLocalizedString("No supported media was found on this page.", comment: "No supported article media"))
				return
			}

			let mediaName = mediaContextTarget == .image ? NSLocalizedString("images", comment: "Article image count") : NSLocalizedString("videos", comment: "Article video count")
			let title = mediaContextTarget == .image ? NSLocalizedString("Save All Images", comment: "Save all article images") : NSLocalizedString("Save All Videos", comment: "Save all article videos")
			let message = String.localizedStringWithFormat(NSLocalizedString("Save %ld %@ to your photo library?", comment: "Confirm saving all article media"), snapshot.urls.count, mediaName)
			let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
			alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel))
			alert.addAction(UIAlertAction(title: NSLocalizedString("Save", comment: "Save"), style: .default) { [weak self] _ in
				self?.saveMedia(snapshot: snapshot, type: mediaContextTarget)
			})
			self.present(alert, animated: true)
		}
	}

	private func saveMedia(snapshot: MediaSnapshot, type: MediaContextTarget) {
		Task { @MainActor [weak self] in
			guard let self else {
				return
			}
			await performMediaSave(snapshot: snapshot, type: type)
		}
	}

	/// Performs a batch save, reporting every step it reaches.
	///
	/// This runs inside a single method with one top-level catch so an unexpected failure is logged
	/// rather than silently swallowed. The stage marker is also kept up to date, because the error
	/// log is written asynchronously and its last messages are lost if the process terminates during
	/// the save.
	private func performMediaSave(snapshot: MediaSnapshot, type: MediaContextTarget) async {
		ArticleMediaSaveStage.begin(type: type.rawValue, requestedCount: snapshot.urls.count)
		logMediaEvent(.debug, operation: "Save all", message: "Saving \(snapshot.urls.count) \(type.rawValue) media; \(snapshot.skipped) skipped; sources: \(snapshot.urls.map { ArticleMediaLog.urlDescription($0, level: .debug) })")

		let saver = ArticleMediaSaver()
		ArticleMediaSaveStage.update("authorizing")
		guard await saver.authorize() else {
			ArticleMediaSaveStage.finish()
			logMediaEvent(.warning, operation: "Photo Library", message: "Add-only Photos permission was not granted")
			presentMediaSaveResult(title: NSLocalizedString("Photo Library Access Required", comment: "Photo library access required title"), message: NSLocalizedString("Allow NetNewsWire to add media to your photo library and try again.", comment: "Photo library access required message"))
			return
		}
		logMediaEvent(.debug, operation: "Save all", message: "Add-only Photos permission is granted")

		let iconData = type == .image ? renderedArticleIconData() : nil
		if type == .image {
			logMediaEvent(.debug, operation: "Save all", message: iconData == nil ? "No feed icon data available for an nnwImageIcon source" : "Feed icon data is \(iconData?.count ?? 0) bytes")
		}

		let mediaName = type == .image ? NSLocalizedString("Images", comment: "Saving images title") : NSLocalizedString("Videos", comment: "Saving videos title")
		let progressAlert = UIAlertController(title: String.localizedStringWithFormat(NSLocalizedString("Saving %@", comment: "Saving article media title"), mediaName), message: nil, preferredStyle: .alert)
		mediaSaveProgressAlert = progressAlert
		ArticleMediaSaveStage.update("presenting progress")
		present(progressAlert, animated: true)

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
		progressAlert.dismiss(animated: true) { [weak self] in
			ArticleMediaSaveStage.finish()
			self?.logMediaEvent(result.failedCount > 0 ? .warning : .info, operation: "Save all", message: "Saved \(result.savedCount) of \(result.requestedCount); failed \(result.failedCount); skipped \(result.skippedCount)")
			self?.mediaSaveProgressAlert = nil
			self?.presentMediaSaveResult(title: NSLocalizedString("Media Saved", comment: "Article media saved title"), message: self?.mediaSaveResultMessage(result) ?? "")
		}
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

		if !replaceExistingWebView, let webView = webView {
			self.renderPage(webView)
			return
		}

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

				self.renderPage(webView)
			}
		}
	}

	func renderPage(_ webView: PreloadedWebView?) {
		guard let webView = webView else { return }

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
				loadBaseURL: ArticleRenderer.page.baseURL.absoluteString,
				htmlBaseURL: rendering.baseURL,
				sources: imageSources
			)
			ArticleMediaLog.logRender(
				articleID: article.articleID,
				link: article.preferredLink,
				loadBaseURL: ArticleRenderer.page.baseURL.absoluteString,
				htmlBaseURL: rendering.baseURL,
				imageSources: imageSources
			)
		} else {
			articleImageLoadTracker = nil
		}
		webView.loadHTMLString(html, baseURL: ArticleRenderer.page.baseURL)
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

	func imageWasClicked(body: String?) {
		guard let webView, let body else { return }

		let data = Data(body.utf8)
		guard let clickMessage = try? JSONDecoder().decode(ImageClickMessage.self, from: data) else {
			return
		}

		guard let imageURL = URL(string: clickMessage.imageURL) else { return }

		Downloader.shared.download(imageURL) { [weak self] data, _, error in
			guard let self, let data, error == nil, !data.isEmpty,
				  let image = UIImage(data: data) else {
				return
			}
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

		coordinator.showFullScreenImage(image: image, imageTitle: clickMessage.imageTitle, transitioningDelegate: self, saveAllImagesHandler: { [weak self] in
			self?.confirmSaveAllMedia(for: .image)
		})
	}

	func stopMediaPlayback(_ webView: WKWebView) {
		webView.evaluateJavaScript("stopMediaPlayback();")
	}

	func cancelImageLoad(_ webView: WKWebView) {
		webView.evaluateJavaScript("cancelImageLoad();")
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
		topShowBarsView.backgroundColor = .clear
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

		let title = article.status.read ? NSLocalizedString("Mark as Unread", comment: "Mark as Unread") : NSLocalizedString("Mark as Read", comment: "Mark as Read")
		let readImage = article.status.read ? Assets.Images.circleClosed : Assets.Images.circleOpen
		return UIAction(title: title, image: readImage) { [weak self] _ in
			self?.coordinator.toggleReadForCurrentArticle()
		}
	}

	func toggleStarredAction() -> UIAction {
		let starred = article?.status.starred ?? false
		let title = starred ? NSLocalizedString("Mark as Unstarred", comment: "Mark as Unstarred") : NSLocalizedString("Mark as Starred", comment: "Mark as Starred")
		let starredImage = starred ? Assets.Images.starOpen : Assets.Images.starClosed
		return UIAction(title: title, image: starredImage) { [weak self] _ in
			self?.coordinator.toggleStarredForCurrentArticle()
		}
	}

	func nextUnreadArticleAction() -> UIAction? {
		guard coordinator.isAnyUnreadAvailable else { return nil }
		let title = NSLocalizedString("Next Unread Article", comment: "Next Unread Article")
		return UIAction(title: title, image: Assets.Images.nextUnread) { [weak self] _ in
			self?.coordinator.selectNextUnread()
		}
	}

	func toggleArticleExtractorAction() -> UIAction {
		let extracted = articleExtractorButtonState == .on
		let title = extracted ? NSLocalizedString("Show Feed Article", comment: "Show Feed Article") : NSLocalizedString("Show Reader View", comment: "Show Reader View")
		let extractorImage = extracted ? Assets.Images.articleExtractorOffSF : Assets.Images.articleExtractorOnSF
		return UIAction(title: title, image: extractorImage) { [weak self] _ in
			self?.toggleArticleExtractor()
		}
	}

	func shareAction() -> UIAction {
		let title = NSLocalizedString("Share", comment: "Share")
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
		present(viewController, animated: true)
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
