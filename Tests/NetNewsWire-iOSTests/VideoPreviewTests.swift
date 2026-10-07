#if os(iOS)
import XCTest
import UIKit
import WebKit
import Articles
@testable import NetNewsWire

@MainActor final class VideoPreviewTests: XCTestCase {
	func testSettingDefaultsOffAndSwitchPersists() throws {
		let key = AppDefaults.Key.loadVideoFirstFramePreview
		let original = AppDefaults.store.object(forKey: key)
		defer {
			if let original {
				AppDefaults.store.set(original, forKey: key)
			} else {
				AppDefaults.store.removeObject(forKey: key)
			}
		}
		AppDefaults.store.removeObject(forKey: key)
		AppDefaults.registerDefaults()
		XCTAssertFalse(AppDefaults.shared.loadVideoFirstFramePreview)
		let settings = MediaSettingsModel()
		XCTAssertFalse(settings.binding(for: .loadVideoFirstFramePreview).wrappedValue)
		XCTAssertEqual(MediaSetting.loadVideoFirstFramePreview.title, NSLocalizedString("Load Video First Frame Preview", comment: ""))
		settings.binding(for: .loadVideoFirstFramePreview).wrappedValue = true
		XCTAssertTrue(AppDefaults.shared.loadVideoFirstFramePreview)
		XCTAssertTrue(MediaSettingsModel().binding(for: .loadVideoFirstFramePreview).wrappedValue)
		settings.binding(for: .loadVideoFirstFramePreview).wrappedValue = false
		XCTAssertFalse(AppDefaults.shared.loadVideoFirstFramePreview)
	}

	func testPrefetchHTMLCollectorMatchesEligibleDOMSources() {
		let html = """
		<base href="https://example.test/media/"><VIDEO SRC='a.mp4?a=1&amp;b=2' preload='none'></VIDEO>
		<video poster='cover.jpg' src='skip.mp4'></video><video class='other nnwAnimatedGIF' src='gif.mp4'></video>
		<video><source src='b.mp4' type='video/mp4'><source src='unused.mp4'></video>
		<video src='data:video/mp4;base64,abc'></video><video src='a.mp4?a=1&amp;b=2'></video>
		"""
		XCTAssertEqual(VideoPreviewSources.urls(in: html, baseURL: nil).map(\.absoluteString), ["https://example.test/media/a.mp4?a=1&b=2", "https://example.test/media/b.mp4"])
		let cached = "nnwvideocache://cache?url=https%3A%2F%2Fexample.test%2Fc.mp4%3Fx%3D1%26y%3D2"
		XCTAssertEqual(VideoPreviewSources.originalURL(cached, baseURL: nil)?.absoluteString, "https://example.test/c.mp4?x=1&y=2")
	}

	func testNativeExtractionCreatesPortraitJPEGAndReusesDiskCache() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let fixture = try fixtureURL()
		let cache = VideoPreviewCache(directory: directory)
		let counter = PreviewCounter()
		let service = VideoPreviewService(cache: cache) { url in
			await counter.increment()
			return try await VideoPreviewService.generatePreview(for: url)
		}
		let first = try await service.preview(for: fixture)
		let image = try XCTUnwrap(UIImage(data: first))
		XCTAssertEqual(image.size.height, 720)
		XCTAssertEqual(image.size.width / image.size.height, 960.0 / 1704.0, accuracy: 0.01)
		let second = try await service.preview(for: fixture)
		XCTAssertEqual(first, second)
		let count = await counter.value
		XCTAssertEqual(count, 1)
		await service.clearCache()
		let cleared = await cache.data(for: fixture)
		XCTAssertNil(cleared)
	}

	func testCacheCapacityAndClearRejectsLateWrites() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let cache = VideoPreviewCache(directory: directory, maximumSize: 8)
		let a = URL(string: "https://example.test/a.mp4")!
		let b = URL(string: "https://example.test/b.mp4")!
		let epoch = await cache.epoch()
		await cache.store(Data(repeating: 1, count: 6), for: a, epoch: epoch)
		await cache.store(Data(repeating: 2, count: 6), for: b, epoch: epoch)
		let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
		let total = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
		XCTAssertLessThanOrEqual(total, 8)
		await cache.clear()
		await cache.store(Data([3]), for: a, epoch: epoch)
		let stale = await cache.data(for: a)
		XCTAssertNil(stale)
	}

	func testExistingVideoCacheIsReusableWithFullVideoCachingDisabled() async throws {
		let original = AppDefaults.shared.cacheVideoContent
		defer { AppDefaults.shared.cacheVideoContent = original }
		AppDefaults.shared.cacheVideoContent = false
		let url = try XCTUnwrap(URL(string: "https://example.invalid/cached-preview-\(UUID().uuidString).mp4"))
		VideoCacheDatabase.shared.cacheData(url: url.absoluteString, data: try Data(contentsOf: fixtureURL()), contentType: "video/mp4")
		let data = try await VideoPreviewService.generatePreview(for: url)
		XCTAssertNotNil(UIImage(data: data))
		XCTAssertFalse(AppDefaults.shared.cacheVideoContent)
	}

	func testExtractionAppliesRotationAndLimitsSize() async throws {
		let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "video-preview-rotated", withExtension: "mp4"))
		let data = try await VideoPreviewService.generatePreview(for: url)
		let image = try XCTUnwrap(UIImage(data: data))
		XCTAssertEqual(image.size.width, 720)
		XCTAssertLessThan(image.size.height, image.size.width)
	}

	func testTwoWorkerLimitAndCurrentArticlePriority() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = PreviewGenerationProbe()
		let service = VideoPreviewService(cache: VideoPreviewCache(directory: directory)) { try await probe.generate($0) }
		let urls = ["a", "b", "c", "d"].map { URL(string: "https://example.test/\($0).mp4")! }
		let a = Task { try await service.preview(for: urls[0], priority: .prefetch) }
		let b = Task { try await service.preview(for: urls[1], priority: .prefetch) }
		try await waitUntil { await probe.started.count == 2 }
		let c = Task { try await service.preview(for: urls[2], priority: .prefetch) }
		let d = Task { try await service.preview(for: urls[3], priority: .current) }
		defer { a.cancel(); b.cancel(); c.cancel(); d.cancel() }
		try await waitUntil { await service.queuedJobCount == 2 }
		await probe.complete(urls[0])
		try await waitUntil { await probe.started.count == 3 }
		let third = await probe.started[2]
		XCTAssertEqual(third, urls[3])
		await probe.complete(urls[1])
		try await waitUntil { await probe.started.count == 4 }
		await probe.complete(urls[2])
		await probe.complete(urls[3])
		_ = try await (a.value, b.value, c.value, d.value)
		let peak = await probe.peak
		XCTAssertEqual(peak, 2)
	}

	func testSameURLSharesWorkAndCancellingOneWaiterKeepsOtherAlive() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = PreviewGenerationProbe()
		let service = VideoPreviewService(cache: VideoPreviewCache(directory: directory)) { try await probe.generate($0) }
		let url = URL(string: "https://example.test/shared.mp4")!
		let prefetch = Task { try await service.preview(for: url, priority: .prefetch) }
		let current = Task { try await service.preview(for: url) }
		defer { prefetch.cancel(); current.cancel() }
		try await waitUntil { await service.pendingRequestCount == 2 }
		prefetch.cancel()
		try await waitUntil { await service.pendingRequestCount == 1 }
		await probe.complete(url)
		let data = try await current.value
		XCTAssertEqual(data, Data([1]))
		let count = await probe.started.count
		XCTAssertEqual(count, 1)
		do {
			_ = try await prefetch.value
			XCTFail("Cancelled consumer must not receive the preview")
		} catch is CancellationError { }
	}

	func testCancellingLastWaiterReleasesWorkerAndDoesNotCache() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = PreviewGenerationProbe()
		let cache = VideoPreviewCache(directory: directory)
		let service = VideoPreviewService(cache: cache) { try await probe.generate($0) }
		let url = URL(string: "https://example.test/cancel.mp4")!
		let task = Task { try await service.preview(for: url) }
		try await waitUntil { await probe.started.count == 1 }
		task.cancel()
		do {
			_ = try await task.value
			XCTFail("Cancellation must propagate")
		} catch is CancellationError { }
		try await waitUntil { await probe.running == 0 }
		let data = await cache.data(for: url)
		XCTAssertNil(data)
	}

	func testNativeTimeoutCancelsExtraction() async throws {
		do {
			_ = try await VideoPreviewService.generatePreview(for: fixtureURL(), timeout: .zero)
			XCTFail("Zero deadline must time out before asynchronous decoding")
		} catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
	}

	func testIsolatedDOMPreviewWithContentJavaScriptEnabledAndDisabled() async throws {
		let data = try await VideoPreviewService.generatePreview(for: fixtureURL())
		for enabled in [false, true] {
			let webView = try await makeWebView(contentJavaScript: enabled)
			_ = try await evaluate("window.nnwVideoPreview.configure('first', true);", in: webView)
			let sources = try await VideoPreviewController.collect(webView, documentID: "first")
			XCTAssertEqual(sources.count, 1)
			let source = try XCTUnwrap(sources.first)
			let applied = try await VideoPreviewController.apply(data, source: source, documentID: "first", in: webView)
			XCTAssertTrue(applied)
			let src = try await evaluate("return document.getElementById('missing').getAttribute('src');", in: webView) as? String
			XCTAssertEqual(src, "https://example.test/video.mp4")
			let ran = try await evaluate("return document.body.dataset.pageScriptRan === 'true';", in: webView) as? Bool
			XCTAssertEqual(ran, enabled)
			_ = try await evaluate("window.nnwVideoPreview.configure('first', false);", in: webView)
			let removed = try await evaluate("return document.getElementById('missing').hasAttribute('poster');", in: webView) as? Bool
			XCTAssertEqual(removed, false)
			let existing = try await evaluate("return document.getElementById('covered').getAttribute('poster');", in: webView) as? String
			XCTAssertEqual(existing, "cover.jpg")
		}
	}

	func testControllerToggleClearsPreviewAndRejectsPendingWork() async throws {
		let original = AppDefaults.shared.loadVideoFirstFramePreview
		defer { AppDefaults.shared.loadVideoFirstFramePreview = original }
		AppDefaults.shared.loadVideoFirstFramePreview = true
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = PreviewGenerationProbe()
		let service = VideoPreviewService(cache: VideoPreviewCache(directory: directory)) { try await probe.generate($0) }
		let controller = VideoPreviewController(service: service)
		let webView = try await makeWebView()
		controller.documentDidLoad(webView)
		controller.setActive(true)
		try await waitUntil { await probe.started.count == 1 }
		AppDefaults.shared.loadVideoFirstFramePreview = false
		try await waitUntil { await probe.running == 0 }
		let hasPoster = try await evaluate("return document.getElementById('missing').hasAttribute('poster');", in: webView) as? Bool
		XCTAssertEqual(hasPoster, false)
		controller.documentWillChange()
	}

	func testPrefetchRequiresBothSettingsAndCurrentViewReusesResult() async throws {
		let originalPreview = AppDefaults.shared.loadVideoFirstFramePreview
		let originalPrefetch = AppDefaults.shared.prefetchNextArticleContent
		defer {
			AppDefaults.shared.loadVideoFirstFramePreview = originalPreview
			AppDefaults.shared.prefetchNextArticleContent = originalPrefetch
		}
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let counter = PreviewCounter()
		let fixture = try fixtureURL()
		let service = VideoPreviewService(cache: VideoPreviewCache(directory: directory)) { _ in
			await counter.increment()
			return try await VideoPreviewService.generatePreview(for: fixture)
		}
		let prefetcher = ArticlePrefetcher(previewService: service)
		for preview in [false, true] {
			for prefetch in [false, true] {
				AppDefaults.shared.loadVideoFirstFramePreview = preview
				AppDefaults.shared.prefetchNextArticleContent = prefetch
				prefetcher.prefetchVideoPreviews(html: Self.html, baseURL: nil, articleID: "fixture")
				await prefetcher.previewTask?.value
				let count = await counter.value
				XCTAssertEqual(count, preview && prefetch ? 1 : 0)
			}
		}
		_ = try await service.preview(for: URL(string: "https://example.test/video.mp4")!)
		let count = await counter.value
		XCTAssertEqual(count, 1)
	}

	func testDisablingPrefetchCancelsItsPendingPreview() async throws {
		let originalPreview = AppDefaults.shared.loadVideoFirstFramePreview
		let originalPrefetch = AppDefaults.shared.prefetchNextArticleContent
		defer {
			AppDefaults.shared.loadVideoFirstFramePreview = originalPreview
			AppDefaults.shared.prefetchNextArticleContent = originalPrefetch
		}
		AppDefaults.shared.loadVideoFirstFramePreview = true
		AppDefaults.shared.prefetchNextArticleContent = true
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = PreviewGenerationProbe()
		let service = VideoPreviewService(cache: VideoPreviewCache(directory: directory)) { try await probe.generate($0) }
		let prefetcher = ArticlePrefetcher(previewService: service)
		prefetcher.prefetchVideoPreviews(html: Self.html, baseURL: nil, articleID: "next")
		try await waitUntil { await probe.started.count == 1 }
		AppDefaults.shared.prefetchNextArticleContent = false
		try await waitUntil { await probe.running == 0 }
		XCTAssertNil(prefetcher.previewTask)
	}

	func testFailedPreviewIsNotRetriedWhenSameDocumentReappears() async throws {
		let original = AppDefaults.shared.loadVideoFirstFramePreview
		defer { AppDefaults.shared.loadVideoFirstFramePreview = original }
		AppDefaults.shared.loadVideoFirstFramePreview = true
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let counter = PreviewCounter()
		let service = VideoPreviewService(cache: VideoPreviewCache(directory: directory)) { _ in
			await counter.increment()
			throw URLError(.notConnectedToInternet)
		}
		let controller = VideoPreviewController(service: service)
		let webView = try await makeWebView()
		controller.documentDidLoad(webView)
		controller.setActive(true)
		try await waitUntil { await counter.value == 1 }
		try await waitUntil { await service.pendingRequestCount == 0 }
		try await Task.sleep(for: .milliseconds(50))
		controller.setActive(false)
		controller.setActive(true)
		try await Task.sleep(for: .milliseconds(100))
		let count = await counter.value
		XCTAssertEqual(count, 1)
		let poster = try await evaluate("return document.getElementById('missing').hasAttribute('poster');", in: webView) as? Bool
		XCTAssertEqual(poster, false)
		controller.documentWillChange()
	}

	func testNativeReaderDisplaysPreviewForCachedFreshRSSVideo() async throws {
		let preview = AppDefaults.shared.loadVideoFirstFramePreview
		let videoCache = AppDefaults.shared.cacheVideoContent
		let autoplay = AppDefaults.shared.autoplayVideo
		let scripts = AppDefaults.shared.isArticleContentJavascriptEnabled
		defer {
			AppDefaults.shared.loadVideoFirstFramePreview = preview
			AppDefaults.shared.cacheVideoContent = videoCache
			AppDefaults.shared.autoplayVideo = autoplay
			AppDefaults.shared.isArticleContentJavascriptEnabled = scripts
		}
		AppDefaults.shared.loadVideoFirstFramePreview = true
		AppDefaults.shared.cacheVideoContent = true
		AppDefaults.shared.autoplayVideo = false
		AppDefaults.shared.isArticleContentJavascriptEnabled = false
		let url = "https://example.invalid/video-preview-\(UUID().uuidString).mp4"
		VideoCacheDatabase.shared.cacheData(url: url, data: try Data(contentsOf: fixtureURL()), contentType: "video/mp4")
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let coordinator = try XCTUnwrap(scene.coordinator)
		let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = windowScene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: windowScene)
		let reader = WebViewController()
		reader.coordinator = coordinator
		let loaded = expectation(description: "Native reader loaded")
		let delegate = PreviewReaderDelegate { loaded.fulfill() }
		reader.delegate = delegate
		let articleID = UUID().uuidString
		let article = Article(accountID: "preview-test", articleID: articleID, feedID: "x-for-you", uniqueID: UUID().uuidString,
			title: "视频首帧预览", contentHTML: "<video src=\"\(url)\" width=\"320\" height=\"568\" controls preload=\"none\"></video>", contentText: nil, markdown: nil,
			url: "https://example.invalid/article", externalURL: nil, summary: nil, imageURL: nil,
			datePublished: Date(), dateModified: nil, authors: nil, status: ArticleStatus(articleID: articleID, read: false, dateArrived: Date()))
		reader.setArticle(article)
		window.rootViewController = UINavigationController(rootViewController: reader)
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		await fulfillment(of: [loaded], timeout: 10)
		let webView = try XCTUnwrap(reader.view.subviews.first as? WKWebView)
		try await waitUntil {
			let value = try await self.evaluate("return document.querySelector('video').poster.startsWith('data:image/jpeg;base64,');", in: webView)
			return value as? Bool == true
		}
		let paused = try await evaluate("return document.querySelector('video').paused;", in: webView) as? Bool
		XCTAssertEqual(paused, true)
		_ = try await evaluate("const image = new Image(); image.src = document.querySelector('video').poster; await image.decode(); await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return { width: image.naturalWidth, height: image.naturalHeight };", in: webView)
		var screenshot: UIImage?
		try await waitUntil {
			let image = try await webView.takeSnapshot(configuration: nil)
			guard self.bluePixels(in: image) > 200 else { return false }
			screenshot = image
			return true
		}
		let attachment = XCTAttachment(image: try XCTUnwrap(screenshot))
		attachment.name = "Video First Frame Preview in Native Reader"
		attachment.lifetime = .keepAlways
		add(attachment)
		AppDefaults.shared.loadVideoFirstFramePreview = false
		try await waitUntil {
			let value = try await self.evaluate("return !document.querySelector('video').hasAttribute('poster');", in: webView)
			return value as? Bool == true
		}
	}

	private func bluePixels(in image: UIImage) -> Int {
		guard let image = image.cgImage else { return 0 }
		var pixels = [UInt8](repeating: 0, count: 24 * 48 * 4)
		pixels.withUnsafeMutableBytes { buffer in
			let context = CGContext(data: buffer.baseAddress, width: 24, height: 48, bitsPerComponent: 8, bytesPerRow: 24 * 4,
				space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
			context?.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 48))
		}
		return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 100 && pixels[$0 + 1] < 100 && pixels[$0 + 2] > 150 }.count
	}
	private func fixtureURL() throws -> URL {
		try XCTUnwrap(Bundle(for: Self.self).url(forResource: "video-preview", withExtension: "mp4"))
	}
	private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
	private func waitUntil(_ predicate: () async throws -> Bool) async throws {
		for _ in 0..<500 {
			if try await predicate() { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		XCTFail("Timed out waiting for preview state")
		throw URLError(.timedOut)
	}
	private func makeWebView(contentJavaScript: Bool = false) async throws -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = contentJavaScript
		configuration.userContentController.addUserScript(try XCTUnwrap(VideoPreviewController.userScript))
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 800), configuration: configuration)
		let loader = PreviewLoader()
		webView.navigationDelegate = loader
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			loader.continuation = continuation
			webView.loadHTMLString(Self.html, baseURL: URL(string: "https://example.test/"))
		}
		webView.navigationDelegate = nil
		return webView
	}
	private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
		try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: VideoPreviewController.contentWorld)
	}
	private static let html = """
	<html><head><meta name="viewport" content="width=device-width"></head><body>
	<video id="missing" src="https://example.test/video.mp4" width="320" height="568" controls preload="none"></video>
	<video id="covered" src="https://example.test/covered.mp4" poster="cover.jpg" preload="none"></video>
	<video class="nnwAnimatedGIF" src="https://example.test/gif.mp4" preload="none"></video>
	<script>document.body.dataset.pageScriptRan = 'true';</script></body></html>
	"""
}

private actor PreviewCounter {
	var value = 0
	func increment() { value += 1 }
}
private actor PreviewGenerationProbe {
	var started: [URL] = []
	var running = 0
	var peak = 0
	private var waiters: [URL: CheckedContinuation<Data, Error>] = [:]
	func generate(_ url: URL) async throws -> Data {
		started.append(url)
		running += 1
		peak = max(peak, running)
		defer { running -= 1 }
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { waiters[url] = $0 }
		} onCancel: { Task { await self.cancel(url) } }
	}
	func complete(_ url: URL) { waiters.removeValue(forKey: url)?.resume(returning: Data([1])) }
	private func cancel(_ url: URL) { waiters.removeValue(forKey: url)?.resume(throwing: CancellationError()) }
}
@MainActor private final class PreviewLoader: NSObject, WKNavigationDelegate {
	var continuation: CheckedContinuation<Void, Error>?
	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
@MainActor private final class PreviewReaderDelegate: WebViewControllerDelegate {
	let didLoad: () -> Void
	init(_ didLoad: @escaping () -> Void) { self.didLoad = didLoad }
	func webViewController(_: WebViewController, articleExtractorButtonStateDidUpdate: ArticleExtractorButtonState) {}
	func webViewControllerDidLoadArticle(_ controller: WebViewController) { didLoad() }
}
#endif
