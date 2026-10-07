#if os(iOS)
import XCTest
import UIKit
import WebKit
import Network
import Articles
import RSParser
@testable import Account
@testable import NetNewsWire

@MainActor final class ArticleTranslationNavigationTests: XCTestCase {
	func testVisibleReaderPrefetchesOnlyNextArticleAndReusesItOnNavigation() async throws {
		try await verifyNavigation(mode: .bilingual)
	}

	func testReplacementTranslationIsRestoredFromCacheWhenReturning() async throws {
		try await verifyNavigation(mode: .replaceOriginal)
	}

	private func verifyNavigation(mode: ArticleTranslationDisplayMode) async throws {
		let original = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		let originalMedia = AppDefaults.shared.prefetchNextArticleContent
		let server = try LoopbackTranslationServer()
		try await server.start()
		defer {
			server.stop()
			try? ArticleTranslationSettings.save(original, apiKey: originalKey)
			AppDefaults.shared.prefetchNextArticleContent = originalMedia
		}
		let baseline = try ArticleTranslationConfiguration(baseURL: server.baseURL, apiKey: "local-test-key", model: "local-test", language: "中文")
		let (_, response) = try await URLSession.shared.data(for: baseline.request(for: [ArticleTranslationSegment(id: "health", text: "HTTP baseline")]))
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
		await ArticleTranslationService.shared.clearCache()
		AppDefaults.shared.prefetchNextArticleContent = false
		var preferences = ArticleTranslationPreferences()
		preferences.baseURL = server.baseURL
		preferences.model = "local-test"
		preferences.automaticallyTranslate = true
		preferences.prefetchNextArticleTranslation = true
		preferences.displayMode = mode
		try ArticleTranslationSettings.save(preferences, apiKey: "local-test-key")

		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let window = try XCTUnwrap(scene.window)
		let root = try XCTUnwrap(window.rootViewController as? RootSplitViewController)
		let coordinator = try XCTUnwrap(scene.coordinator)
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		let token = UUID().uuidString
		let feed = account.createFeed(with: "Translation navigation test", url: "https://example.invalid/" + token,
			feedID: "https://example.invalid/" + token, homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		defer {
			coordinator.selectArticle(nil)
			coordinator.navigateToTimeline()
			coordinator.selectFeed(nil)
			AccountManager.shared.deleteAccount(account)
		}
		let items = Set((0..<3).map { index in
			ParsedItem(syncServiceID: nil, uniqueID: "\(token)-\(index)", feedURL: feed.url,
				url: nil, externalURL: nil, title: "Navigation article \(index)", language: nil,
				contentHTML: "<p>Navigation paragraph \(token)-\(index)</p><p>A <a href='https://example.invalid/link'>linked</a> sentence with <b>formatting</b>.</p>", contentText: nil, markdown: nil,
				summary: nil, imageURL: nil, bannerImageURL: nil, datePublished: Date().addingTimeInterval(Double(-index)),
				dateModified: nil, authors: nil, tags: nil, attachments: nil)
		})
		_ = await account.updateAsync(feedID: feed.feedID, parsedItems: items, deleteOlder: false)
		let seeded = await account.fetchArticlesAsync(.feed(feed))
		XCTAssertEqual(seeded.count, 3)
		let timeline = try XCTUnwrap(root.viewController(for: .supplementary) as? MainTimelineModernViewController)
		timeline.loadViewIfNeeded()
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			coordinator.discloseFeed(feed, initialLoad: true, animations: []) { continuation.resume() }
		}
		try await waitUntil { coordinator.articles.count == 3 }
		let articles = coordinator.articles
		let firstText = "Navigation paragraph " + articles[0].uniqueID
		let nextText = "Navigation paragraph " + articles[1].uniqueID
		let laterText = "Navigation paragraph " + articles[2].uniqueID
		coordinator.selectArticle(articles[0], animations: [.navigation])
		do {
			try await waitUntil {
				guard server.count(for: nextText) == 1 else { return false }
				return (try await self.readerText(root)).contains("译:" + firstText)
			}
		} catch {
			let articleController = root.viewController(for: .secondary) as? ArticleViewController
			let pager = articleController?.children.first { $0 is UIPageViewController } as? UIPageViewController
			let reader = pager?.viewControllers?.first as? WebViewController
			print("Reader probe: app=\(UIApplication.shared.applicationState.rawValue) visible=\(articleController?.viewIfLoaded?.window != nil) pending=\(coordinator.isArticleViewControllerPending) showing=\(coordinator.isArticleViewControllerShowing) documentReady=\(reader?.isArticleDocumentReady ?? false) first=\(server.count(for: firstText)) next=\(server.count(for: nextText)) later=\(server.count(for: laterText)) selected=\(articleController?.article?.uniqueID ?? "nil") readerText=\(try await self.readerText(root))")
			let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
			attachment.name = "Reader Translation Probe"
			attachment.lifetime = .keepAlways
			add(attachment)
			throw error
		}
		let unexpected = expectation(description: "Hidden neighbor must not prefetch a third article")
		unexpected.isInverted = true
		server.onTranslation = { texts in if texts.contains(laterText) { unexpected.fulfill() } }
		await fulfillment(of: [unexpected], timeout: 0.25)
		XCTAssertEqual(server.count(for: laterText), 0)
		server.onTranslation = nil
		coordinator.selectArticle(articles[1], animations: [.navigation])
		try await waitUntil { (try await self.readerText(root)).contains("译:" + nextText) }
		XCTAssertEqual(server.count(for: nextText), 1, "Opening the next page should reuse its completed or in-flight request")
		let activeArticleController = try XCTUnwrap(root.viewController(for: .secondary) as? ArticleViewController)
		let activePager = try XCTUnwrap(activeArticleController.children.first { $0 is UIPageViewController } as? UIPageViewController)
		let activeReader = try XCTUnwrap(activePager.viewControllers?.first as? WebViewController)
		let originalCallback = activeReader.translationStateDidChange
		var returnedStates = [String]()
		activeReader.translationStateDidChange = { state in
			returnedStates.append(state)
			originalCallback?(state)
		}
		coordinator.selectArticle(articles[0], animations: [.navigation])
		try await waitUntil {
			guard returnedStates.last == "translated" else { return false }
			return (try await self.readerText(root)).contains("译:" + firstText)
		}
		let stateTrace = XCTAttachment(string: "\(mode): first_article_requests=\(server.count(for: firstText)), returned_states=\(returnedStates)")
		stateTrace.name = "Return Navigation Cache State"
		stateTrace.lifetime = .keepAlways
		add(stateTrace)
		XCTAssertEqual(server.count(for: firstText), 1, "Returning should reuse the first article translation")
		XCTAssertFalse(returnedStates.contains("running"), "Fully cached articles should restore directly without restarting translation")
		let articleController = try XCTUnwrap(root.viewController(for: .secondary) as? ArticleViewController)
		let translationButton = try XCTUnwrap(articleController.toolbarItems?.first { $0.accessibilityIdentifier == "article.translation" })
		let labelBeforeRefresh = translationButton.accessibilityLabel
		articleController.updateUI()
		let buttonTrace = XCTAttachment(string: "\(mode): before_refresh=\(labelBeforeRefresh ?? "nil"), after_refresh=\(translationButton.accessibilityLabel ?? "nil")")
		buttonTrace.name = "Cached Translation Toolbar State"
		buttonTrace.lifetime = .keepAlways
		add(buttonTrace)
		XCTAssertEqual(translationButton.accessibilityLabel, ArticleTranslationStrings.text("Show Original"), "UI refresh must preserve the cached translated button state")
		let neighbor = try XCTUnwrap(articleController.pageViewController(activePager, viewControllerAfter: activeReader) as? WebViewController)
		neighbor.translationStateDidChange?("running")
		neighbor.translationStateDidChange?("paused")
		XCTAssertEqual(translationButton.accessibilityLabel, ArticleTranslationStrings.text("Show Original"), "Hidden-page callbacks must not overwrite the visible cached button")
		let action = try XCTUnwrap(translationButton.action)
		XCTAssertTrue(UIApplication.shared.sendAction(action, to: translationButton.target, from: translationButton, for: nil))
		try await waitUntil { !(try await self.readerText(root)).contains("译:") }
		XCTAssertEqual(translationButton.accessibilityLabel, ArticleTranslationStrings.text("Translate"))
		articleController.updateUI()
		XCTAssertEqual(translationButton.accessibilityLabel, ArticleTranslationStrings.text("Translate"))
		XCTAssertTrue(UIApplication.shared.sendAction(action, to: translationButton.target, from: translationButton, for: nil))
		try await waitUntil {
			guard translationButton.accessibilityLabel == ArticleTranslationStrings.text("Show Original") else { return false }
			return (try await self.readerText(root)).contains("译:" + firstText)
		}
		XCTAssertEqual(server.count(for: firstText), 1, "The bottom button should restore cached translation without new requests")
		let pager = try XCTUnwrap(articleController.children.first { $0 is UIPageViewController } as? UIPageViewController)
		let reader = try XCTUnwrap(pager.viewControllers?.first as? WebViewController)
		translationButton.accessibilityLabel = ArticleTranslationStrings.text("Stop")
		articleController.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
		XCTAssertEqual(translationButton.accessibilityLabel, ArticleTranslationStrings.text("Show Original"), "Finishing a page transition should synchronize the current page button")
		let webView = try XCTUnwrap(reader.viewIfLoaded?.subviews.first as? WKWebView)
		let snapshotConfiguration = WKSnapshotConfiguration()
		snapshotConfiguration.afterScreenUpdates = true
		let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
			webView.takeSnapshot(with: snapshotConfiguration) { image, error in
				if let image { continuation.resume(returning: image) }
				else { continuation.resume(throwing: error ?? ArticleTranslationError.invalidResponse) }
			}
		}
		let attachment = XCTAttachment(image: image)
		attachment.name = "Returning Article Restores Cached Translation - \(mode)"
		attachment.lifetime = .keepAlways
		add(attachment)
		let toolbarImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
			window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
		}
		let toolbarAttachment = XCTAttachment(image: toolbarImage)
		toolbarAttachment.name = "Cached Translation Bottom Button - \(mode)"
		toolbarAttachment.lifetime = .keepAlways
		add(toolbarAttachment)
	}

	private func readerText(_ root: RootSplitViewController) async throws -> String {
		guard let article = root.viewController(for: .secondary) as? ArticleViewController,
			let pager = article.children.first(where: { $0 is UIPageViewController }) as? UIPageViewController,
			let reader = pager.viewControllers?.first as? WebViewController,
			let webView = reader.viewIfLoaded?.subviews.first as? WKWebView else { return "" }
		return (try? await webView.callAsyncJavaScript("return document.body.textContent;", arguments: [:], in: nil, contentWorld: ArticleTranslationController.contentWorld) as? String) ?? ""
	}

	private func waitUntil(_ predicate: () async throws -> Bool) async throws {
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline {
			if try await predicate() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		XCTFail("Reader did not reach the expected translation state")
		throw URLError(.timedOut)
	}
}

/// Exercise the app's actual URLSession and page lifecycle using a local Responses endpoint.
private final class LoopbackTranslationServer: @unchecked Sendable {
	private let listener: NWListener
	private let queue = DispatchQueue(label: "ArticleTranslationNavigationTests.HTTP")
	private let lock = NSLock()
	private var started: CheckedContinuation<Void, Error>?
	private var translated = [String: Int]()
	private var observer: (@Sendable ([String]) -> Void)?

	init() throws { listener = try NWListener(using: .tcp, on: .any) }
	var baseURL: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }
	var onTranslation: (@Sendable ([String]) -> Void)? {
		get { lock.withLock { observer } }
		set { lock.withLock { observer = newValue } }
	}
	func count(for text: String) -> Int { lock.withLock { translated[text] ?? 0 } }

	func start() async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			lock.withLock { started = continuation }
			listener.stateUpdateHandler = { [weak self] state in
				guard let self else { return }
				switch state {
				case .ready: self.completeStart(.success(()))
				case .failed(let error): self.completeStart(.failure(error))
				default: break
				}
			}
			listener.newConnectionHandler = { [weak self] connection in
				guard let self else { connection.cancel(); return }
				connection.start(queue: self.queue)
				self.receive(connection, previous: Data())
			}
			listener.start(queue: queue)
		}
	}

	func stop() { listener.cancel() }
	private func completeStart(_ result: Result<Void, Error>) {
		let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
			defer { started = nil }
			return started
		}
		continuation?.resume(with: result)
	}

	private func receive(_ connection: NWConnection, previous: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
			guard let self, error == nil else { connection.cancel(); return }
			let buffer = previous + (data ?? Data())
			guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
				if complete { connection.cancel() } else { self.receive(connection, previous: buffer) }
				return
			}
			let headers = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
			let length = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
				.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
			let body = Data(buffer[boundary.upperBound...])
			guard body.count >= length else {
				if complete { connection.cancel() } else { self.receive(connection, previous: buffer) }
				return
			}
			self.respond(connection, body: body.prefix(length))
		}
	}

	private func respond(_ connection: NWConnection, body: Data) {
		do {
			guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any], let input = request["input"] as? String else { throw URLError(.badServerResponse) }
			let segments = try JSONDecoder().decode([ArticleTranslationSegment].self, from: Data(input.utf8))
			let texts = segments.map(\.text)
			let callback = lock.withLock {
				for text in texts { translated[text, default: 0] += 1 }
				return observer
			}
			callback?(texts)
			let output = try JSONSerialization.data(withJSONObject: ["translations": segments.map { ["id": $0.id, "text": "译:" + $0.text] }])
			let result = try JSONSerialization.data(withJSONObject: ["status": "completed", "output_text": String(decoding: output, as: UTF8.self)])
			let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(result.count)\r\nConnection: close\r\n\r\n"
			connection.send(content: Data(headers.utf8) + result, completion: .contentProcessed { _ in connection.cancel() })
		} catch { connection.cancel() }
	}
}
#endif
