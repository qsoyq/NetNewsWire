#if os(iOS)
import XCTest
import UIKit
import WebKit
import Articles
import RSParser
@testable import Account
@testable import NetNewsWire

@MainActor final class ArticleMediaThumbnailsTests: XCTestCase {
	func testSettingDefaultsOffAndPersistsIndependently() {
		let key = AppDefaults.Key.showArticleMediaThumbnails
		let original = AppDefaults.store.object(forKey: key)
		defer {
			if let original { AppDefaults.store.set(original, forKey: key) }
			else { AppDefaults.store.removeObject(forKey: key) }
		}
		AppDefaults.store.removeObject(forKey: key)
		AppDefaults.registerDefaults()
		XCTAssertFalse(AppDefaults.shared.showArticleMediaThumbnails)
		MediaSettingsModel().binding(for: .showArticleMediaThumbnails).wrappedValue = true
		XCTAssertTrue(AppDefaults.shared.showArticleMediaThumbnails)
		XCTAssertTrue(MediaSettingsModel().binding(for: .showArticleMediaThumbnails).wrappedValue)
	}

	func testDOMOrderFilteringDeduplicationAndToggleWithPageScriptsOnAndOff() async throws {
		for pageScripts in [false, true] {
			let (webView, _) = try await makeWebView(pageScripts: pageScripts)
			let initialCount = try await evaluate("return document.querySelectorAll('[data-nnw-media-thumbnails]').length;", in: webView) as? Int
			XCTAssertEqual(initialCount, 0)
			try await configure(webView)
			let result = try await evaluate("""
			return {
			    count: document.querySelectorAll('[data-nnw-media-thumbnails] button').length,
			    bodyUnchanged: document.querySelectorAll('.articleBody img').length === 4,
			    noDuplicateMedia: document.querySelectorAll('[data-nnw-media-thumbnails] img,[data-nnw-media-thumbnails] video').length === 0,
			    beforeBody: document.querySelector('[data-nnw-media-thumbnails]').nextElementSibling.classList.contains('articleBody'),
			    scriptRan: document.body.dataset.scriptRan === 'true',
			    labels: Array.from(document.querySelectorAll('[data-nnw-media-thumbnails] button')).map(button => button.getAttribute('aria-label'))
			};
			""", in: webView) as? [String: Any]
			XCTAssertEqual(result?["count"] as? Int, 3)
			XCTAssertEqual(result?["bodyUnchanged"] as? Bool, true)
			XCTAssertEqual(result?["noDuplicateMedia"] as? Bool, true)
			XCTAssertEqual(result?["beforeBody"] as? Bool, true)
			XCTAssertEqual(result?["scriptRan"] as? Bool, pageScripts)
			XCTAssertEqual(result?["labels"] as? [String], ["Image 1", "Video 2", "Image 3"])
			try await configure(webView, enabled: false)
			let count = try await evaluate("return document.querySelectorAll('[data-nnw-media-thumbnails]').length;", in: webView) as? Int
			XCTAssertEqual(count, 0)
		}
	}

	func testImageAndNativeVideoClicksResolveOriginalURLsAndInactiveClicksAreIgnored() async throws {
		let (webView, messages) = try await makeWebView()
		try await configure(webView)
		_ = try await evaluate("document.querySelector('[data-nnw-media-thumbnails] button').click();", in: webView)
		try await waitUntil { messages.images.count == 1 }
		let message = try XCTUnwrap(messages.images.first)
		let data = try XCTUnwrap(message.data(using: .utf8))
		let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(payload["imageURL"] as? String, Self.image)
		XCTAssertEqual(payload["imageTitle"] as? String, "Mountain")
		_ = try await evaluate("document.querySelectorAll('[data-nnw-media-thumbnails] button')[1].click();", in: webView)
		try await waitUntil { messages.videos.count == 1 }
		XCTAssertEqual(messages.videos.first, "https://example.test/movie.mp4")
		_ = try await evaluate("window.nnwMediaThumbnails.setActive(false); document.querySelector('[data-nnw-media-thumbnails] button').click();", in: webView)
		try await Task.sleep(for: .milliseconds(100))
		XCTAssertEqual(messages.images.count, 1)
	}

	func testPosterAndDynamicContentUpdatesAndDisabledCleanup() async throws {
		let (webView, _) = try await makeWebView()
		try await configure(webView)
		_ = try await evaluate("document.querySelector('video').poster = '\(Self.image)';", in: webView)
		try await waitForScript("return document.querySelectorAll('[data-nnw-media-thumbnails] button')[1].style.backgroundImage.includes('data:image/svg+xml');", in: webView)
		_ = try await evaluate("document.querySelector('video').removeAttribute('poster');", in: webView)
		try await waitForScript("return document.querySelectorAll('[data-nnw-media-thumbnails] button')[1].style.backgroundImage === 'none';", in: webView)
		_ = try await evaluate("document.querySelector('.articleBody').insertAdjacentHTML('beforeend', '<img src=https://example.test/late.jpg>');", in: webView)
		try await waitForScript("return document.querySelectorAll('[data-nnw-media-thumbnails] button').length === 4;", in: webView)
		try await configure(webView, enabled: false)
		_ = try await evaluate("document.querySelector('.articleBody').insertAdjacentHTML('beforeend', '<img src=https://example.test/later.jpg>');", in: webView)
		try await Task.sleep(for: .milliseconds(100))
		let absent = try await evaluate("return !document.querySelector('[data-nnw-media-thumbnails]');", in: webView) as? Bool
		XCTAssertEqual(absent, true)
	}

	func testEmptyArticleAndNarrowLightDarkLayouts() async throws {
		let (empty, _) = try await makeWebView(html: "<div class=articleBody><p>Text only</p></div>")
		try await configure(empty)
		let absent = try await evaluate("return !document.querySelector('[data-nnw-media-thumbnails]');", in: empty) as? Bool
		XCTAssertEqual(absent, true)
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		let controller = UIViewController()
		window.rootViewController = controller
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		for style in [UIUserInterfaceStyle.light, .dark] {
			window.overrideUserInterfaceStyle = style
			let (webView, _) = try await makeWebView()
			webView.frame = CGRect(x: 0, y: 80, width: 375, height: 700)
			controller.view.addSubview(webView)
			try await configure(webView)
			try await Task.sleep(for: .milliseconds(250))
			let geometry = try await evaluate("""
			const strip = document.querySelector('[data-nnw-media-thumbnails]');
			return { height: strip.querySelector('button').getBoundingClientRect().height,
			    fits: document.documentElement.scrollWidth <= window.innerWidth,
			    scrolls: strip.scrollWidth > strip.clientWidth };
			""", in: webView) as? [String: Any]
			XCTAssertEqual(geometry?["height"] as? Double, 88)
			XCTAssertEqual(geometry?["fits"] as? Bool, true)
			XCTAssertEqual(geometry?["scrolls"] as? Bool, true)
			let image = try await webView.takeSnapshot(configuration: nil)
			let attachment = XCTAttachment(image: image)
			attachment.name = style == .light ? "Media Thumbnails Light" : "Media Thumbnails Dark"
			attachment.lifetime = .keepAlways
			add(attachment)
			webView.removeFromSuperview()
		}
	}

	func testNativeReaderSettingToggleAndImagePresentationRoundTrip() async throws {
		let original = AppDefaults.shared.showArticleMediaThumbnails
		let originalJavaScript = AppDefaults.shared.isArticleContentJavascriptEnabled
		let originalHide = AppDefaults.shared.hideArticleBodyMedia
		AppDefaults.shared.hideArticleBodyMedia = true
		AppDefaults.shared.showArticleMediaThumbnails = true
		AppDefaults.shared.isArticleContentJavascriptEnabled = false
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let window = try XCTUnwrap(scene.window)
		let root = try XCTUnwrap(window.rootViewController as? RootSplitViewController)
		let coordinator = try XCTUnwrap(scene.coordinator)
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		let token = UUID().uuidString
		let feed = account.createFeed(with: "Media preview test", url: "https://example.invalid/" + token,
			feedID: "https://example.invalid/" + token, homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		defer {
			coordinator.selectArticle(nil)
			coordinator.navigateToTimeline()
			coordinator.selectFeed(nil)
			AccountManager.shared.deleteAccount(account)
			AppDefaults.shared.showArticleMediaThumbnails = original
			AppDefaults.shared.isArticleContentJavascriptEnabled = originalJavaScript
			AppDefaults.shared.hideArticleBodyMedia = originalHide
		}
		let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
			UIColor.systemTeal.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
		}
		let imageURL = "data:image/png;base64," + (try XCTUnwrap(image.pngData())).base64EncodedString()
		let item = ParsedItem(syncServiceID: nil, uniqueID: token, feedURL: feed.url,
			url: nil, externalURL: nil, title: "Media thumbnail preview", language: nil,
			contentHTML: "<p>A photo from this article.</p><img src='\(imageURL)' alt='Preview image'><p>Continue reading below the image.</p>",
			contentText: nil, markdown: nil, summary: nil, imageURL: nil, bannerImageURL: nil,
			datePublished: Date(), dateModified: nil, authors: nil, tags: nil, attachments: nil)
		_ = await account.updateAsync(feedID: feed.feedID, parsedItems: [item], deleteOlder: false)
		let articles = await account.fetchArticlesAsync(.feed(feed))
		let article = try XCTUnwrap(articles.first)
		let timeline = try XCTUnwrap(root.viewController(for: .supplementary) as? MainTimelineModernViewController)
		timeline.loadViewIfNeeded()
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			coordinator.discloseFeed(feed, initialLoad: true, animations: []) { continuation.resume() }
		}
		coordinator.selectArticle(article, animations: [.navigation])
		try await Task.sleep(for: .milliseconds(500))
		let articleController = try XCTUnwrap(root.viewController(for: .secondary) as? ArticleViewController)
		let pager = try XCTUnwrap(articleController.children.first { $0 is UIPageViewController } as? UIPageViewController)
		let reader = try XCTUnwrap(pager.viewControllers?.first as? WebViewController)
		try await waitUntil { reader.isArticleDocumentReady }
		let webView = try XCTUnwrap(reader.view.subviews.first as? WKWebView)
		try await waitForScript("return !!document.querySelector('[data-nnw-media-thumbnails] button');", in: webView)
		AppDefaults.shared.showArticleMediaThumbnails = false
		try await waitForScript("return !document.querySelector('[data-nnw-media-thumbnails]');", in: webView)
		AppDefaults.shared.showArticleMediaThumbnails = true
		try await waitForScript("return !!document.querySelector('[data-nnw-media-thumbnails] button');", in: webView)
		let snapshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
			window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
		})
		snapshot.name = "Hidden Body Media in Native Reader"
		snapshot.lifetime = .keepAlways
		add(snapshot)
		_ = try await evaluate("document.querySelector('[data-nnw-media-thumbnails] button').click();", in: webView)
		try await waitUntil { root.presentedViewController != nil }
		let viewer = try XCTUnwrap(root.presentedViewController as? UINavigationController)
		XCTAssertTrue(viewer.viewControllers.first is ImageViewController)
		try await Task.sleep(for: .milliseconds(500))
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			viewer.dismiss(animated: true) { continuation.resume() }
		}
		XCTAssertNil(root.presentedViewController)
		XCTAssertNotNil(reader.view.window)
		AppDefaults.shared.hideArticleBodyMedia = false
		try await waitForScript("return document.querySelector('.articleBody img').getClientRects().length > 0;", in: webView)
		AppDefaults.shared.hideArticleBodyMedia = true
		try await waitForScript("return document.querySelector('.articleBody img').getClientRects().length === 0;", in: webView)
		try await waitForScript("return !!document.querySelector('[data-nnw-media-thumbnails] button');", in: webView)
	}

	func testHideSettingDefaultsOffAndPersists() {
		let key = AppDefaults.Key.hideArticleBodyMedia
		let original = AppDefaults.store.object(forKey: key)
		defer {
			if let original { AppDefaults.store.set(original, forKey: key) }
			else { AppDefaults.store.removeObject(forKey: key) }
		}
		AppDefaults.store.removeObject(forKey: key)
		AppDefaults.registerDefaults()
		XCTAssertFalse(AppDefaults.shared.hideArticleBodyMedia)
		MediaSettingsModel().binding(for: .hideArticleBodyMedia).wrappedValue = true
		XCTAssertTrue(MediaSettingsModel().binding(for: .hideArticleBodyMedia).wrappedValue)
	}

	func testAllVisibilityCombinationsPreserveThumbnailsLinksCaptionsAndRestoreDOM() async throws {
		for scripts in [false, true] {
			let (webView, _) = try await makeWebView(pageScripts: scripts)
			_ = try await evaluate("""
			const body = document.querySelector('.articleBody');
			body.insertAdjacentHTML('beforeend', '<figure id="captioned"><img src="https://example.test/caption.jpg"><figcaption>Keep this caption</figcaption></figure><div id="emptyWrapper" style="height:400px"><p><img src="https://example.test/only.jpg"></p></div>');
			window.originalBody = body.innerHTML;
			""", in: webView)
			for thumbnails in [false, true] {
				for hide in [false, true] {
					_ = try await evaluate("window.nnwMediaThumbnails.configure(\(thumbnails), true, {media:'Media',image:'Image',video:'Video',link:'Open link'}, \(hide));", in: webView)
					let result = try await evaluate("""
					return {
					    count: document.querySelectorAll('[data-nnw-media-thumbnails] button').length,
					    hidden: Array.from(document.querySelectorAll('.articleBody img,.articleBody video')).every(node => getComputedStyle(node).display === 'none'),
					    caption: document.querySelector('figcaption').getClientRects().length > 0,
					    empty: document.getElementById('emptyWrapper').getClientRects().length === 0,
					    linked: document.querySelector('.articleBody a').textContent,
					    header: document.getElementById('nnwImageIcon').getClientRects().length > 0
					};
					""", in: webView) as? [String: Any]
					XCTAssertEqual(result?["count"] as? Int, thumbnails ? 5 : 0)
					XCTAssertEqual(result?["hidden"] as? Bool, hide)
					XCTAssertEqual(result?["caption"] as? Bool, true)
					XCTAssertEqual(result?["empty"] as? Bool, hide)
					XCTAssertEqual(result?["linked"] as? String, hide ? "Open link" : "")
					XCTAssertEqual(result?["header"] as? Bool, true)
				}
			}
			try await configure(webView, enabled: false)
			let restored = try await evaluate("return document.querySelector('.articleBody').innerHTML === window.originalBody;", in: webView) as? Bool
			XCTAssertEqual(restored, true)
		}
	}

	func testHiddenMediaSavingDynamicUpdatesAndWebVideoFallback() async throws {
		let (webView, _) = try await makeWebView()
		let scriptURL = try XCTUnwrap(Bundle.main.url(forResource: "main_ios", withExtension: "js"))
		let mainScript = try String(contentsOf: scriptURL, encoding: .utf8)
		_ = try await evaluate(mainScript + "\nwindow.collectMediaForSaving = collectMediaForSaving;", in: webView)
		_ = try await evaluate("""
		document.querySelector('.articleBody').insertAdjacentHTML('beforeend', '<img hidden src="https://example.test/already-hidden.jpg">');
		window.nnwMediaThumbnails.configure(true, false, {media:'Media',image:'Image',video:'Video'}, true);
		""", in: webView)
		let prevented = try await evaluate("""
		const hiddenVideo = document.querySelector('video');
		let paused = false, handedOff = false;
		hiddenVideo.pause = () => { paused = true; };
		hiddenVideo.addEventListener('playing', () => { handedOff = true; });
		hiddenVideo.dispatchEvent(new Event('playing'));
		return paused && !handedOff;
		""", in: webView) as? Bool
		XCTAssertEqual(prevented, true)
		let saved = try await evaluate("return JSON.parse(collectMediaForSaving('image')).urls;", in: webView) as? [String]
		XCTAssertEqual(saved?.count, 3)
		XCTAssertFalse(saved?.contains("https://example.test/already-hidden.jpg") ?? true)
		_ = try await evaluate("""
		document.querySelector('.articleBody').insertAdjacentHTML('beforeend', '<p id="late"><img src="https://example.test/late.jpg"></p>');
		""", in: webView)
		try await waitForScript("return getComputedStyle(document.getElementById('late')).display === 'none' && document.querySelectorAll('[data-nnw-media-thumbnails] button').length === 4;", in: webView)
		_ = try await evaluate("""
		const video = document.querySelector('video');
		video.play = () => Promise.reject(new Error('Unavailable test video'));
		video.webkitEnterFullscreen = () => { throw new Error('Fullscreen unavailable'); };
		document.querySelectorAll('[data-nnw-media-thumbnails] button')[1].click();
		""", in: webView)
		let fallback = try await evaluate("return document.querySelector('video').getClientRects().length > 0 && document.querySelector('video').controls;", in: webView) as? Bool
		XCTAssertEqual(fallback, true)
		_ = try await evaluate("document.querySelector('video').dispatchEvent(new Event('webkitendfullscreen'));", in: webView)
		try await waitForScript("return getComputedStyle(document.querySelector('video')).display === 'none';", in: webView)
	}

	private func configure(_ webView: WKWebView, enabled: Bool = true) async throws {
		_ = try await evaluate("window.nnwMediaThumbnails.configure(\(enabled), true, {media:'Media',image:'Image',video:'Video'});", in: webView)
	}

	private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
		try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: ArticleMediaThumbnails.contentWorld)
	}

	private func waitForScript(_ script: String, in webView: WKWebView) async throws {
		for _ in 0..<50 {
			if try await evaluate(script, in: webView) as? Bool == true {
				return
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		XCTFail("Timed out waiting for thumbnail DOM update")
	}

	private func waitUntil(_ predicate: () -> Bool) async throws {
		for _ in 0..<50 {
			if predicate() {
				return
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		XCTFail("Timed out waiting for media message")
	}

	private func makeWebView(pageScripts: Bool = false, html: String? = nil) async throws -> (WKWebView, ThumbnailMessages) {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = pageScripts
		configuration.userContentController.addUserScript(try XCTUnwrap(ArticleMediaThumbnails.userScript))
		let messages = ThumbnailMessages()
		for name in ["imageWasClicked", "nativeVideoPlay"] {
			configuration.userContentController.add(messages, contentWorld: ArticleMediaThumbnails.contentWorld, name: name)
		}
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 700), configuration: configuration)
		let loader = ThumbnailLoader()
		webView.navigationDelegate = loader
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			loader.continuation = continuation
			webView.loadHTMLString(html ?? Self.html, baseURL: URL(string: "https://example.test/"))
		}
		webView.navigationDelegate = nil
		return (webView, messages)
	}

	private static let image = "data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22400%22 height=%22300%22%3E%3Crect width=%22400%22 height=%22300%22 fill=%22%23547565%22/%3E%3Cpath d=%22M0 300L150 70L270 300M160 300L300 100L400 300%22 fill=%22%23b5c8a9%22/%3E%3C/svg%3E"
	private static let html = """
	<html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
	:root { color-scheme:light dark } body { margin:24px; font:17px -apple-system; } h1 { font: bold 28px Georgia; }
	.articleBody img { max-width:100%; } video { width:100%; height:150px; } .date { opacity:.6; font-size:13px; }
	</style></head><body><header><img id=nnwImageIcon src="\(image)" width=32></header>
	<h1>A weekend in the mountains</h1><p class=date>Field Notes · September 26</p>
	<div class=articleBody><p>Follow the trail above the valley. Tap a preview to take a closer look.</p>
	<a href="https://example.test/link"><img src="\(image)" alt="Mountain"></a>
	<video preload=none src="nnwvideocache://cache?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"></video>
	<img src="\(image)"><img src="https://example.test/pixel" width=1 height=1>
	<img src="\(image)#second" alt="Another view"></div>
	<script>document.body.dataset.scriptRan = 'true';</script></body></html>
	"""
}

@MainActor private final class ThumbnailMessages: NSObject, WKScriptMessageHandler {
	var images: [String] = []
	var videos: [String] = []
	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		guard let value = message.body as? String else {
			return
		}
		if message.name == "imageWasClicked" { images.append(value) }
		else { videos.append(value) }
	}
}

@MainActor private final class ThumbnailLoader: NSObject, WKNavigationDelegate {
	var continuation: CheckedContinuation<Void, Error>?
	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
#endif
