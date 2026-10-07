#if os(iOS)
import XCTest
import UIKit
import WebKit
import Articles
@testable import NetNewsWire

@MainActor final class ArticleDisclosureTests: XCTestCase {
	func testSettingDefaultsOffAndSwitchPersists() throws {
		let key = "automaticallyExpandArticleDetails"
		let original = UserDefaults.standard.object(forKey: key)
		defer {
			if let original { UserDefaults.standard.set(original, forKey: key) }
			else { UserDefaults.standard.removeObject(forKey: key) }
		}
		UserDefaults.standard.removeObject(forKey: key)
		AppDefaults.registerDefaults()
		XCTAssertFalse(AppDefaults.shared.automaticallyExpandArticleDetails)
		let settings = try settingsController()
		XCTAssertFalse(settings.automaticallyExpandArticleDetailsSwitch.isOn)
		let index = try articleSettingsRow("articles.autoExpandDetails.row", in: settings)
		let row = settings.tableView(settings.tableView, cellForRowAt: index)
		XCTAssertEqual((row.viewWithTag(942) as? UILabel)?.text, NSLocalizedString("Automatically Expand Collapsed Content", comment: ""))
		settings.automaticallyExpandArticleDetailsSwitch.isOn = true
		settings.automaticallyExpandArticleDetailsSwitch.sendActions(for: .valueChanged)
		XCTAssertTrue(AppDefaults.shared.automaticallyExpandArticleDetails)
		XCTAssertTrue(try settingsController().automaticallyExpandArticleDetailsSwitch.isOn)
		settings.automaticallyExpandArticleDetailsSwitch.isOn = false
		settings.automaticallyExpandArticleDetailsSwitch.sendActions(for: .valueChanged)
		XCTAssertFalse(AppDefaults.shared.automaticallyExpandArticleDetails)
	}

	func testDisabledPreservesOriginalStateWithPageJavaScriptOnOrOff() async throws {
		for pageJavaScript in [false, true] {
			let webView = try await makeWebView(pageJavaScript: pageJavaScript)
			try await ArticleDisclosureController.configure(webView, enabled: false)
			try await assertOpen("folded", expected: false, in: webView)
			try await assertOpen("already", expected: true, in: webView)
			let pageScriptRan = try await evaluate("return document.body.dataset.pageScriptRan === 'true';", in: webView) as? Bool
			XCTAssertEqual(pageScriptRan, pageJavaScript)
		}
	}

	func testEnabledExpandsNestedDetailsOnlyInsideArticleBody() async throws {
		let webView = try await makeWebView()
		try await ArticleDisclosureController.configure(webView, enabled: true)
		try await assertOpen("folded", expected: true, in: webView)
		try await assertOpen("inner", expected: true, in: webView)
		try await assertOpen("alternate", expected: true, in: webView)
		try await assertOpen("outside", expected: false, in: webView)
	}

	func testNewDetailsExpandWithoutReopeningManuallyClosedDetails() async throws {
		let webView = try await makeWebView()
		try await ArticleDisclosureController.configure(webView, enabled: true)
		_ = try await evaluate("document.getElementById('folded').open = false;", in: webView)
		try await ArticleDisclosureController.configure(webView, enabled: true)
		_ = try await evaluate("document.querySelector('.articleBody').insertAdjacentHTML('beforeend', '<details id=late><summary>Later</summary><p>New content</p></details>'); await Promise.resolve();", in: webView)
		try await assertOpen("late", expected: true, in: webView)
		try await assertOpen("folded", expected: false, in: webView)
	}

	func testDisablingStopsExpandingNewDetailsWithoutCollapsingExistingContent() async throws {
		let webView = try await makeWebView()
		try await ArticleDisclosureController.configure(webView, enabled: true)
		try await ArticleDisclosureController.configure(webView, enabled: false)
		_ = try await evaluate("document.querySelector('.articleBody').insertAdjacentHTML('beforeend', '<details id=late><summary>Later</summary><p>New content</p></details>'); await Promise.resolve();", in: webView)
		try await assertOpen("late", expected: false, in: webView)
		try await assertOpen("folded", expected: true, in: webView)
	}

	func testPrefetchAndReaderCollectIdenticalExpandedSegmentsInBothTranslationModes() async throws {
		let original = AppDefaults.shared.automaticallyExpandArticleDetails
		defer { AppDefaults.shared.automaticallyExpandArticleDetails = original }
		for enabled in [false, true] {
			AppDefaults.shared.automaticallyExpandArticleDetails = enabled
			for mode in ArticleTranslationDisplayMode.allCases {
				var preferences = ArticleTranslationPreferences()
				preferences.automaticallyTranslate = true
				preferences.displayMode = mode
				let reader = try await makeWebView()
				try await ArticleTranslationController.configureDocument(reader, documentID: "reader", preferences: preferences)
				let expected = try await ArticleTranslationController.collectSegments(reader)
				let prefetch = try await ArticleTranslationDocument().segments(html: Self.html, baseURL: nil, preferences: preferences, size: CGSize(width: 375, height: 800))
				XCTAssertEqual(prefetch, expected)
				let fixture = TranslationFixture()
				defer { fixture.cleanUp() }
				let service = fixture.service()
				try await service.translate(prefetch, articleID: "folded", configuration: fixture.configuration(), priority: .background) { _, _, _ in }
				let before = fixture.requestCount
				try await service.translate(expected, articleID: "folded", configuration: fixture.configuration()) { _, _, _ in }
				XCTAssertEqual(fixture.requestCount, before)
			}
		}
	}

	func testNativeReaderExpandsFreshRSSArticleWithoutTranslationEnabled() async throws {
		let original = AppDefaults.shared.automaticallyExpandArticleDetails
		let originalTranslation = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		defer {
			AppDefaults.shared.automaticallyExpandArticleDetails = original
			try? ArticleTranslationSettings.save(originalTranslation, apiKey: originalKey)
		}
		AppDefaults.shared.automaticallyExpandArticleDetails = true
		var preferences = originalTranslation
		preferences.automaticallyTranslate = false
		preferences.manuallyTranslate = false
		try ArticleTranslationSettings.save(preferences, apiKey: originalKey)
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let coordinator = try XCTUnwrap(scene.coordinator)
		let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previousWindow = windowScene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: windowScene)
		let reader = WebViewController()
		reader.coordinator = coordinator
		let loaded = expectation(description: "Native article loaded")
		let delegate = DisclosureReaderDelegate { loaded.fulfill() }
		reader.delegate = delegate
		let article = Article(accountID: "disclosure-test", articleID: "1791220553858326", feedID: "uncle-lu", uniqueID: "folded-article",
			title: "这两天我用 GPT-6", contentHTML: Self.freshRSSContent, contentText: nil, markdown: nil,
			url: "https://x.com/GemstoneNicole/status/2107133766632398991", externalURL: nil, summary: nil,
			imageURL: nil, datePublished: Date(timeIntervalSince1970: 1791214813), dateModified: nil, authors: nil,
			status: ArticleStatus(articleID: "1791220553858326", read: false, dateArrived: Date()))
		reader.setArticle(article)
		window.rootViewController = UINavigationController(rootViewController: reader)
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
		await fulfillment(of: [loaded], timeout: 5)
		let webView = try XCTUnwrap(reader.view.subviews.first as? WKWebView)
		for _ in 0..<100 {
			if try await evaluate("return document.querySelector('.articleBody details')?.open === true;", in: webView) as? Bool == true { break }
			try await Task.sleep(for: .milliseconds(20))
		}
		let open = try await evaluate("return document.querySelector('.articleBody details')?.open === true;", in: webView) as? Bool
		XCTAssertEqual(open, true)
		let image = try await snapshot(webView)
		let attachment = XCTAttachment(image: image)
		attachment.name = "FreshRSS Collapsed Article Automatically Expanded"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	func testArticleSettingInLightAndDarkAppearance() async throws {
		let original = AppDefaults.shared.automaticallyExpandArticleDetails
		defer { AppDefaults.shared.automaticallyExpandArticleDetails = original }
		AppDefaults.shared.automaticallyExpandArticleDetails = false
		let settings = try settingsController()
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previousWindow = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		window.rootViewController = UINavigationController(rootViewController: settings)
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
		for style in [UIUserInterfaceStyle.light, .dark] {
			window.overrideUserInterfaceStyle = style
			settings.tableView.scrollToRow(at: try articleSettingsRow("articles.autoExpandDetails.row", in: settings), at: .middle, animated: false)
			window.layoutIfNeeded()
			try await Task.sleep(for: .milliseconds(200))
			let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
			let attachment = XCTAttachment(image: image)
			attachment.name = style == .light ? "Auto Expand Setting Light" : "Auto Expand Setting Dark"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
	}

	private func settingsController() throws -> SettingsViewController {
		let controller = try XCTUnwrap(UIStoryboard(name: "Settings", bundle: .main).instantiateViewController(withIdentifier: "SettingsViewController") as? SettingsViewController)
		controller.loadViewIfNeeded()
		controller.beginAppearanceTransition(true, animated: false)
		controller.endAppearanceTransition()
		return controller
	}

	private func makeWebView(pageJavaScript: Bool = false) async throws -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = pageJavaScript
		configuration.userContentController.addUserScript(try XCTUnwrap(ArticleDisclosureController.userScript))
		configuration.userContentController.addUserScript(try XCTUnwrap(ArticleTranslationController.userScript))
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 800), configuration: configuration)
		let loader = DisclosureLoader()
		webView.navigationDelegate = loader
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			loader.continuation = continuation
			webView.loadHTMLString(Self.html, baseURL: nil)
		}
		webView.navigationDelegate = nil
		return webView
	}

	private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
		try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: ArticleDisclosureController.contentWorld)
	}

	private func assertOpen(_ id: String, expected: Bool, in webView: WKWebView) async throws {
		let open = try await isOpen(id, in: webView)
		XCTAssertEqual(open, expected, id)
	}

	private func isOpen(_ id: String, in webView: WKWebView) async throws -> Bool {
		let value = try await webView.callAsyncJavaScript("return document.getElementById(id).open;", arguments: ["id": id], in: nil, contentWorld: ArticleDisclosureController.contentWorld)
		return try XCTUnwrap(value as? Bool)
	}

	private func snapshot(_ webView: WKWebView) async throws -> UIImage {
		let configuration = WKSnapshotConfiguration()
		configuration.afterScreenUpdates = true
		return try await withCheckedThrowingContinuation { continuation in
			webView.takeSnapshot(with: configuration) { image, error in
				if let image { continuation.resume(returning: image) }
				else { continuation.resume(throwing: error ?? ArticleTranslationError.invalidResponse) }
			}
		}
	}

	private static let freshRSSContent = """
	<details><summary>查看正文</summary><p>这两天我用 GPT-6.1-Sol 实现了一些个人项目，发现它倾向于将所有功能堆砌在单个页面上。无论是个人还是公司项目，它都习惯从上到下无规则地罗列内容，缺乏对页面或功能的模块化切割。这种处理方式导致 UX 和 UI 设计效果极差。</p></details><p><a href="https://x.com/GemstoneNicole/status/2107133766632398991">查看原贴</a></p>
	"""
	private static let html = """
	<html><head><meta name="viewport" content="width=device-width"></head><body>
	<details id="outside"><summary>Outside the article</summary><p>Leave collapsed</p></details>
	<div class="articleBody"><details id="folded"><summary>查看正文</summary><p>Folded article body.</p>
	<details id="inner"><summary>Nested</summary><p>Nested body.</p></details></details>
	<details id="already" open><summary>Already open</summary><p>Keep open.</p></details></div>
	<div class="article-body"><details id="alternate"><summary>Alternate theme</summary><p>Body.</p></details></div>
	<script>document.body.dataset.pageScriptRan = 'true';</script></body></html>
	"""
}

@MainActor private final class DisclosureLoader: NSObject, WKNavigationDelegate {
	var continuation: CheckedContinuation<Void, Error>?
	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}

@MainActor private final class DisclosureReaderDelegate: WebViewControllerDelegate {
	let didLoad: () -> Void
	init(_ didLoad: @escaping () -> Void) { self.didLoad = didLoad }
	func webViewController(_: WebViewController, articleExtractorButtonStateDidUpdate: ArticleExtractorButtonState) {}
	func webViewControllerDidLoadArticle(_ controller: WebViewController) { didLoad() }
}
#endif
