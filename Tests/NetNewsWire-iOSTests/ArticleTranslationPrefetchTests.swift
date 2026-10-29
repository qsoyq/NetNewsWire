#if os(iOS)
import XCTest
import UIKit
import WebKit
import Articles
@testable import NetNewsWire

@MainActor final class ArticleTranslationPrefetchTests: XCTestCase {
	func testTranslationPrefetchIsIndependentOfMediaPrefetchAndRequiresAutomaticTranslation() async throws {
		let original = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		let originalMedia = AppDefaults.shared.prefetchNextArticleContent
		defer {
			try? ArticleTranslationSettings.save(original, apiKey: originalKey)
			AppDefaults.shared.prefetchNextArticleContent = originalMedia
		}
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let prefetcher = ArticleTranslationPrefetcher(service: service)
		for media in [false, true] {
			for enabled in [false, true] {
				AppDefaults.shared.prefetchNextArticleContent = media
				var preferences = translationPreferences(fixture)
				preferences.prefetchNextArticleTranslation = enabled
				try ArticleTranslationSettings.save(preferences, apiKey: "test-key")
				let before = fixture.requestCount
				prefetcher.prefetch(article("media-\(media)-translation-\(enabled)"), size: CGSize(width: 375, height: 800))
				await prefetcher.task?.value
				if enabled { XCTAssertGreaterThan(fixture.requestCount, before) }
				else { XCTAssertEqual(fixture.requestCount, before) }
			}
		}
		var preferences = translationPreferences(fixture)
		preferences.automaticallyTranslate = false
		preferences.manuallyTranslate = true
		try ArticleTranslationSettings.save(preferences, apiKey: "test-key")
		let before = fixture.requestCount
		prefetcher.prefetch(article("manual-only"), size: CGSize(width: 375, height: 800))
		XCTAssertNil(prefetcher.task)
		XCTAssertEqual(fixture.requestCount, before)
	}

	func testHTMLAndPlainTextArticlesReusePrefetchInBothModesAcrossThemes() async throws {
		let original = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		let themeManager = ArticleThemesManager.shared
		let originalTheme = themeManager.currentTheme
		defer {
			try? ArticleTranslationSettings.save(original, apiKey: originalKey)
			themeManager.currentTheme = originalTheme
		}
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let themes = [ArticleTheme.defaultTheme] + (Bundle.main.urls(forResourcesWithExtension: ArticleTheme.nnwThemeSuffix, subdirectory: nil) ?? []).compactMap { try? ArticleTheme(url: $0, isAppTheme: true) }
		XCTAssertGreaterThan(themes.count, 1)
		for theme in themes {
			themeManager.currentTheme = theme
			for mode in ArticleTranslationDisplayMode.allCases {
				var preferences = translationPreferences(fixture)
				preferences.displayMode = mode
				preferences.translateTitle = true
				try ArticleTranslationSettings.save(preferences, apiKey: "test-key")
				for plain in [false, true] {
					let source = article("\(theme.name)-\(mode)-\(plain)", plain: plain)
					let prefetcher = ArticleTranslationPrefetcher(service: service)
					prefetcher.prefetch(source, size: CGSize(width: 375, height: 800))
					await prefetcher.task?.value
					let before = fixture.requestCount
					let rendered = try ArticleTranslationPrefetcher.render(source)
					let reader = try await makeReader(html: rendered.html, baseURL: rendered.baseURL)
					try await ArticleTranslationController.configureDocument(reader, documentID: "reader", preferences: preferences)
					let segments = try await ArticleTranslationController.collectSegments(reader)
					XCTAssertTrue(segments.contains { $0.text == "Test article" }, theme.name)
					XCTAssertFalse(segments.isEmpty, theme.name)
					try await service.translate(segments, articleID: source.articleID, configuration: ArticleTranslationSettings.configuration()) { @MainActor translations, _, _ in
						_ = try await reader.callAsyncJavaScript("window.nnwTranslation.apply('reader', translations);", arguments: ["translations": translations.map { ["id": $0.id, "text": $0.text] }], in: nil, contentWorld: ArticleTranslationController.contentWorld)
					}
					let title = try await reader.callAsyncJavaScript("return document.querySelector('.articleTitle,.article-title').textContent;", arguments: [:], in: nil, contentWorld: ArticleTranslationController.contentWorld) as? String
					XCTAssertTrue(title?.contains("译:Test article") == true, theme.name)
					XCTAssertEqual(fixture.requestCount, before, "Cache miss: \(theme.name), \(mode), plain=\(plain)")
					let text = try await reader.callAsyncJavaScript("return document.body.textContent;", arguments: [:], in: nil, contentWorld: ArticleTranslationController.contentWorld) as? String
					XCTAssertTrue(text?.contains("译:") == true)
					if theme.name == ArticleTheme.defaultTheme.name, !plain {
						try await attachReader(reader, mode: mode)
					}
				}
			}
		}
	}

	func testSelectingInFlightPrefetchKeepsItAliveAtEndOfList() async throws {
		let original = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		defer { try? ArticleTranslationSettings.save(original, apiKey: originalKey) }
		let fixture = TranslationFixture(hold: true)
		defer { fixture.cleanUp() }
		try ArticleTranslationSettings.save(translationPreferences(fixture), apiKey: "test-key")
		let service = fixture.service()
		let prefetcher = ArticleTranslationPrefetcher(service: service)
		let started = expectation(description: "Next article translation started")
		fixture.onRequest = { _, _ in started.fulfill() }
		let source = article("last-article", plain: true)
		prefetcher.prefetch(source, size: CGSize(width: 375, height: 800))
		let work = prefetcher.task
		await fulfillment(of: [started], timeout: 5)
		prefetcher.select(source)
		prefetcher.prefetch(nil, size: CGSize(width: 375, height: 800))
		XCTAssertNil(prefetcher.task)
		fixture.onRequest = nil
		fixture.releaseNext()
		await work?.value
		let rendered = try ArticleTranslationPrefetcher.render(source)
		let segments = try await ArticleTranslationDocument().segments(html: rendered.html, baseURL: rendered.baseURL,
			preferences: ArticleTranslationSettings.preferences, size: CGSize(width: 375, height: 800))
		try await service.translate(segments, articleID: source.articleID, configuration: ArticleTranslationSettings.configuration()) { _, _, _ in }
		XCTAssertEqual(fixture.requestCount, 1)
		prefetcher.cancel()
	}

	func testCancelledPrefetchCanBeScheduledAgain() async throws {
		let original = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		defer { try? ArticleTranslationSettings.save(original, apiKey: originalKey) }
		let fixture = TranslationFixture(hold: true)
		defer { fixture.cleanUp() }
		try ArticleTranslationSettings.save(translationPreferences(fixture), apiKey: "test-key")
		let prefetcher = ArticleTranslationPrefetcher(service: fixture.service())
		let first = expectation(description: "First prefetch started")
		let retried = expectation(description: "Same article can retry")
		fixture.onRequest = { count, _ in if count == 1 { first.fulfill() } else { retried.fulfill() } }
		let source = article("retry-same-article", plain: true)
		prefetcher.prefetch(source, size: CGSize(width: 375, height: 800))
		let cancelled = prefetcher.task
		await fulfillment(of: [first], timeout: 5)
		prefetcher.cancel()
		await cancelled?.value
		prefetcher.prefetch(source, size: CGSize(width: 375, height: 800))
		await fulfillment(of: [retried], timeout: 5)
		fixture.onRequest = nil
		fixture.hold = false
		fixture.releaseNext()
		await prefetcher.task?.value
		XCTAssertEqual(fixture.requestCount, 2)
	}

	func testPageDirectionLockPreservesAutomaticRTLUnlessEnabled() async throws {
		let original = AppDefaults.shared.lockArticlePageDirection
		defer { AppDefaults.shared.lockArticlePageDirection = original }
		let rtlTitle = "به معنای واقعی دستشو گذاشته زیر چونه‌اش"
		for locked in [false, true] {
			AppDefaults.shared.lockArticlePageDirection = locked
			for title in ["A normal title", rtlTitle, "عنوان المقال", "כותרת המאמר"] {
				for mode in ArticleTranslationDisplayMode.allCases {
					for translateTitle in [false, true] {
						var preferences = ArticleTranslationPreferences()
						preferences.automaticallyTranslate = true
						preferences.displayMode = mode
						preferences.translateTitle = translateTitle
						let content = "<p>RT by <a href='https://example.invalid'>@author</a></p><details open><summary>查看正文</summary><p dir='rtl'>این متن فارسی است</p></details><p><a href='https://example.invalid'>查看原贴</a></p>"
						let source = article("layout-\(mode)-\(translateTitle)", title: title, content: content)
						let rendered = try ArticleTranslationPrefetcher.render(source)
						let reader = try await makeReader(html: rendered.html, baseURL: rendered.baseURL)
						_ = try await reader.callAsyncJavaScript("document.querySelector('.headerTable td').textContent = '订阅源';", arguments: [:], in: nil, contentWorld: ArticleTranslationController.contentWorld)
						try await ArticleTranslationController.configureDocument(reader, documentID: "layout", preferences: preferences)
						let segments = try await ArticleTranslationController.collectSegments(reader)
						XCTAssertFalse(segments.isEmpty)
						XCTAssertEqual(segments.contains { $0.text == title }, translateTitle)
						for translated in [false, true] {
							if translated {
								_ = try await reader.callAsyncJavaScript("window.nnwTranslation.apply('layout', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "中文译文"] }], in: nil, contentWorld: ArticleTranslationController.contentWorld)
							}
							let snapshot = try await reader.callAsyncJavaScript("""
							const cells = document.querySelectorAll('.headerTable td');
							return {
							    pageDirection: getComputedStyle(document.documentElement).direction,
							    bodyDirection: getComputedStyle(document.body).direction,
							    headerLeftOfAvatar: cells[0].getBoundingClientRect().left < cells[1].getBoundingClientRect().left,
							    explicitRTL: getComputedStyle(document.querySelector('[dir=rtl]')).direction
							};
							""", arguments: [:], in: nil, contentWorld: ArticleTranslationController.contentWorld) as? [String: Any]
							let layout = try XCTUnwrap(snapshot)
							let isLTR = locked || title == "A normal title"
							let context = "locked=\(locked), title=\(title), mode=\(mode), translateTitle=\(translateTitle), translated=\(translated)"
							XCTAssertEqual(layout["pageDirection"] as? String, isLTR ? "ltr" : "rtl", context)
							XCTAssertEqual(layout["bodyDirection"] as? String, isLTR ? "ltr" : "rtl", context)
							XCTAssertEqual(layout["headerLeftOfAvatar"] as? Bool, isLTR, context)
							XCTAssertEqual(layout["explicitRTL"] as? String, "rtl", context)
							if title == rtlTitle, mode == .bilingual, !translateTitle, !translated {
								try await attachReader(reader, mode: mode, name: "RTL Article - Page Direction Lock \(locked)")
							}
						}
					}
				}
			}
		}
	}

	func testPageDirectionLockUpdatesNativeReaderWithoutReloading() async throws {
		let originalLock = AppDefaults.shared.lockArticlePageDirection
		let originalTranslation = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		defer {
			AppDefaults.shared.lockArticlePageDirection = originalLock
			try? ArticleTranslationSettings.save(originalTranslation, apiKey: originalKey)
		}
		AppDefaults.shared.lockArticlePageDirection = false
		try ArticleTranslationSettings.save(ArticleTranslationPreferences(), apiKey: originalKey)
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let coordinator = try XCTUnwrap(scene.coordinator)
		let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previousWindow = windowScene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: windowScene)
		let reader = WebViewController()
		reader.coordinator = coordinator
		let loaded = expectation(description: "Native RTL article loaded")
		let delegate = LayoutReaderDelegate { loaded.fulfill() }
		reader.delegate = delegate
		let content = "<p id='translation-marker'>Original paragraph</p>" + (0..<80).map { "<p>Paragraph \($0) keeps this article scrollable.</p>" }.joined()
		reader.setArticle(article("live-layout", title: "عنوان المقال", content: content))
		window.rootViewController = UINavigationController(rootViewController: reader)
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
		await fulfillment(of: [loaded], timeout: 5)
		let webView = try XCTUnwrap(reader.view.subviews.first as? WKWebView)
		var preferences = ArticleTranslationPreferences()
		preferences.manuallyTranslate = true
		preferences.displayMode = .replaceOriginal
		try await ArticleTranslationController.configureDocument(webView, documentID: "live-layout", preferences: preferences)
		let segments = try await ArticleTranslationController.collectSegments(webView)
		XCTAssertFalse(segments.isEmpty)
		_ = try await webView.callAsyncJavaScript("window.nnwTranslation.apply('live-layout', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "中文译文"] }], in: nil, contentWorld: ArticleTranslationController.contentWorld)
		_ = try await webView.callAsyncJavaScript("window.layoutToken = 'same-document';", arguments: [:], in: nil, contentWorld: .defaultClient)
		for locked in [true, false] {
			ArticleSettingsModel().binding(for: .lockArticlePageDirection).wrappedValue = locked
			let expected = locked ? "ltr" : "rtl"
			let deadline = Date().addingTimeInterval(5)
			var direction: String?
			repeat {
				direction = try await webView.callAsyncJavaScript("return getComputedStyle(document.documentElement).direction;", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
				if direction == expected { break }
				try await Task.sleep(for: .milliseconds(20))
			} while Date() < deadline
			XCTAssertEqual(direction, expected)
			let snapshot = try await webView.callAsyncJavaScript("return {token: window.layoutToken, text: document.getElementById('translation-marker').textContent};", arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
			let state = try XCTUnwrap(snapshot)
			XCTAssertEqual(state["token"] as? String, "same-document")
			XCTAssertEqual(state["text"] as? String, "中文译文")

		}
	}

	func testChangingPageDirectionPreservesScrollPosition() async throws {
		let original = AppDefaults.shared.lockArticlePageDirection
		defer { AppDefaults.shared.lockArticlePageDirection = original }
		let paragraphs = (0..<80).map { "<p>Paragraph \($0)</p>" }.joined()
		let reader = try await makeReader(html: "<html dir='auto'><head><title>عنوان المقال</title></head><body>\(paragraphs)</body></html>", baseURL: nil)
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previousWindow = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		let controller = UIViewController()
		controller.view = reader
		window.rootViewController = controller
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
		window.layoutIfNeeded()
		_ = try await reader.takeSnapshot(configuration: nil)
		for locked in [true, false] {
			_ = try await reader.callAsyncJavaScript("window.scrollTo(0, 200);", arguments: [:], in: nil, contentWorld: .defaultClient)
			let before = try await reader.callAsyncJavaScript("return window.scrollY;", arguments: [:], in: nil, contentWorld: .defaultClient) as? Double
			XCTAssertGreaterThan(try XCTUnwrap(before), 0)
			AppDefaults.shared.lockArticlePageDirection = locked
			try await WebViewConfiguration.configureArticlePageDirection(reader)
			_ = try await reader.takeSnapshot(configuration: nil)
			let after = try await reader.callAsyncJavaScript("return window.scrollY;", arguments: [:], in: nil, contentWorld: .defaultClient) as? Double
			XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1)
		}
	}

	private func attachReader(_ reader: WKWebView, mode: ArticleTranslationDisplayMode, name: String? = nil) async throws {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previousWindow = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		let controller = UIViewController()
		controller.view = reader
		window.rootViewController = controller
		window.makeKeyAndVisible()
		defer {
			window.isHidden = true
			previousWindow?.makeKeyAndVisible()
		}
		window.layoutIfNeeded()
		let configuration = WKSnapshotConfiguration()
		configuration.afterScreenUpdates = true
		let image = try await reader.takeSnapshot(configuration: configuration)
		let attachment = XCTAttachment(image: image)
		attachment.name = name ?? "Article Title Translation - \(mode)"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	private func translationPreferences(_ fixture: TranslationFixture) -> ArticleTranslationPreferences {
		var preferences = ArticleTranslationPreferences()
		preferences.baseURL = "https://" + fixture.host
		preferences.model = "model"
		preferences.automaticallyTranslate = true
		preferences.prefetchNextArticleTranslation = true
		return preferences
	}

	private func article(_ id: String, plain: Bool = false, title: String = "Test article", content: String? = nil) -> Article {
		Article(accountID: "test", articleID: id, feedID: "feed", uniqueID: id, title: title,
			contentHTML: plain ? nil : (content ?? "<p>First paragraph \(id).</p><p>Second <a href='https://example.invalid'>paragraph</a> with <b>formatting</b>.</p>"),
			contentText: plain ? "First paragraph \(id).\n\nSecond paragraph." : nil,
			markdown: nil, url: "https://example.invalid/article", externalURL: nil, summary: nil,
			imageURL: nil, datePublished: nil, dateModified: nil, authors: nil,
			status: ArticleStatus(articleID: id, read: false, dateArrived: Date()))
	}

	private func makeReader(html: String, baseURL: URL?) async throws -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = false
		configuration.userContentController.addUserScript(try XCTUnwrap(ArticleTranslationController.userScript))
		configuration.userContentController.addUserScript(try XCTUnwrap(ArticleDisclosureController.userScript))
		let reader = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 800), configuration: configuration)
		let loader = ReaderLoader()
		reader.navigationDelegate = loader
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			loader.continuation = continuation
			reader.loadHTMLString(html, baseURL: baseURL)
		}
		reader.navigationDelegate = nil
		return reader
	}

	private final class LayoutReaderDelegate: WebViewControllerDelegate {
		let didLoad: () -> Void
		init(_ didLoad: @escaping () -> Void) { self.didLoad = didLoad }
		func webViewController(_: WebViewController, articleExtractorButtonStateDidUpdate: ArticleExtractorButtonState) {}
		func webViewControllerDidLoadArticle(_ controller: WebViewController) { didLoad() }
	}

	private final class ReaderLoader: NSObject, WKNavigationDelegate {
		var continuation: CheckedContinuation<Void, Error>?
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			continuation?.resume()
			continuation = nil
		}
		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			continuation?.resume(throwing: error)
			continuation = nil
		}
	}
}
#endif
