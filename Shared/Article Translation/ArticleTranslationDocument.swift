import Foundation
@preconcurrency import WebKit
#if os(iOS)
import UIKit
#endif

/// Collect the same DOM units as the reader without running feed scripts or downloading media.
@MainActor final class ArticleTranslationDocument: NSObject, WKNavigationDelegate {
	private static let resourceRules = Task { @MainActor in
		try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ArticleTranslationPrefetch", encodedContentRuleList: #"[{"trigger":{"url-filter":".*","resource-type":["image","media","raw","script"]},"action":{"type":"block"}}]"#)
	}

	private var webView: WKWebView?
	private var continuation: CheckedContinuation<Void, Error>?
	private var timeoutTask: Task<Void, Never>?

	func segments(html: String, baseURL: URL?, preferences: ArticleTranslationPreferences, size: CGSize) async throws -> [ArticleTranslationSegment] {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		configuration.mediaTypesRequiringUserActionForPlayback = .all
		guard let script = ArticleTranslationController.userScript else { throw ArticleTranslationError.invalidResponse }
		configuration.userContentController.addUserScript(script)
		if let disclosureScript = ArticleDisclosureController.userScript {
			configuration.userContentController.addUserScript(disclosureScript)
		}
		if let rules = try await Self.resourceRules.value { configuration.userContentController.add(rules) }
		try Task.checkCancellation()
		let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
#if os(iOS)
		switch AppDefaults.userInterfaceColorPalette {
		case .automatic: webView.overrideUserInterfaceStyle = .unspecified
		case .light: webView.overrideUserInterfaceStyle = .light
		case .dark: webView.overrideUserInterfaceStyle = .dark
		}
#endif
		self.webView = webView
		WebViewConfiguration.addContentBlockingRules(to: webView)
		webView.navigationDelegate = self
		defer {
			timeoutTask?.cancel()
			timeoutTask = nil
			webView.stopLoading()
			webView.navigationDelegate = nil
			self.webView = nil
		}
		try await withTaskCancellationHandler {
			try Task.checkCancellation()
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				self.continuation = continuation
				timeoutTask = Task { [weak self] in
					do { try await Task.sleep(for: .seconds(20)) } catch { return }
					self?.complete(.failure(URLError(.timedOut)))
				}
				webView.loadHTMLString(html, baseURL: baseURL)
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.complete(.failure(CancellationError())) }
		}
		try Task.checkCancellation()
		try await ArticleTranslationController.configureDocument(webView, documentID: UUID().uuidString, preferences: preferences)
		let segments = try await ArticleTranslationController.collectSegments(webView)
		try Task.checkCancellation()
		return segments
	}

	private func complete(_ result: Result<Void, Error>) {
		let pending = continuation
		continuation = nil
		timeoutTask?.cancel()
		pending?.resume(with: result)
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete(.success(())) }
	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete(.failure(error)) }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { complete(.failure(error)) }
	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { complete(.failure(ArticleTranslationError.invalidResponse)) }
}
