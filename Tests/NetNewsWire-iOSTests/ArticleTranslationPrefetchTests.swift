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
					XCTAssertFalse(segments.isEmpty, theme.name)
					try await service.translate(segments, articleID: source.articleID, configuration: ArticleTranslationSettings.configuration()) { @MainActor translations, _, _ in
						_ = try await reader.callAsyncJavaScript("window.nnwTranslation.apply('reader', translations);", arguments: ["translations": translations.map { ["id": $0.id, "text": $0.text] }], in: nil, contentWorld: ArticleTranslationController.contentWorld)
					}
					XCTAssertEqual(fixture.requestCount, before, "Cache miss: \(theme.name), \(mode), plain=\(plain)")
					let text = try await reader.callAsyncJavaScript("return document.body.textContent;", arguments: [:], in: nil, contentWorld: ArticleTranslationController.contentWorld) as? String
					XCTAssertTrue(text?.contains("译:") == true)
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

	private func translationPreferences(_ fixture: TranslationFixture) -> ArticleTranslationPreferences {
		var preferences = ArticleTranslationPreferences()
		preferences.baseURL = "https://" + fixture.host
		preferences.model = "model"
		preferences.automaticallyTranslate = true
		preferences.prefetchNextArticleTranslation = true
		return preferences
	}

	private func article(_ id: String, plain: Bool = false) -> Article {
		Article(accountID: "test", articleID: id, feedID: "feed", uniqueID: id, title: "Test article",
			contentHTML: plain ? nil : "<p>First paragraph \(id).</p><p>Second <a href='https://example.invalid'>paragraph</a> with <b>formatting</b>.</p>",
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
