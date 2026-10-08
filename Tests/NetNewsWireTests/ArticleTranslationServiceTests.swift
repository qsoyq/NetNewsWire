import XCTest
import CryptoKit
@testable import NetNewsWire

final class ArticleTranslationServiceTests: XCTestCase {
	func testLegacyFragmentAndArticleCacheAreNotReused() async throws {
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let configuration = try fixture.configuration()
		let segments = [ArticleTranslationSegment(id: "0", text: "查看正文", context: "查看正文")]
		func legacyKey(text: String, context: String, version: String? = nil) -> String {
			let fields = [configuration.endpoint.absoluteString, configuration.apiKey, configuration.model, configuration.language, text, context]
			let identity = ((version.map { [$0] } ?? []) + fields).joined(separator: "\u{0}")
			return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let fingerprint = String(decoding: try encoder.encode(segments), as: UTF8.self)
		let oldArticle = String(decoding: try encoder.encode(["0": "Old incorrect article translation"]), as: UTF8.self)
		let cache = [legacyKey(text: "查看正文", context: "查看正文"): "Old incorrect fragment translation",
			legacyKey(text: "article-v2:article", context: fingerprint): oldArticle,
			legacyKey(text: "查看正文", context: "查看正文", version: "text-nodes-v1"): "Old context-contaminated fragment",
			legacyKey(text: "article-v3:article", context: fingerprint, version: "text-nodes-v1"): oldArticle]
		fixture.defaults.set(try encoder.encode(cache), forKey: "ArticleTranslationFragmentCache")
		let service = fixture.service()
		let cached = try await service.cachedTranslations(for: segments, articleID: "article", configuration: configuration)
		XCTAssertNil(cached)
		try await service.translate(segments, articleID: "article", configuration: configuration) { _, _, _ in }
		XCTAssertEqual(fixture.requestCount, 1)
		let newCache = try await fixture.service().cachedTranslations(for: segments, articleID: "article", configuration: configuration)
		XCTAssertEqual(newCache, [ArticleTranslationSegment(id: "0", text: "译:查看正文")])
	}

	func testCompletedPrefetchIsReusedAfterRecreatingService() async throws {
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let segments = [ArticleTranslationSegment(id: "0", text: "First paragraph"), ArticleTranslationSegment(id: "1", text: "Second paragraph")]
		try await service.translate(segments, articleID: "article", configuration: fixture.configuration(), priority: .background) { _, _, _ in }
		let count = fixture.requestCount
		let restored = fixture.service()
		let output = TranslationOutput()
		try await restored.translate(segments, articleID: "article", configuration: fixture.configuration()) { values, _, _ in await output.append(values) }
		XCTAssertEqual(fixture.requestCount, count)
		let translated = await output.values
		XCTAssertEqual(Set(translated.map(\.text)), ["译:First paragraph", "译:Second paragraph"])
	}

	func testCompleteCacheSnapshotRestoresCurrentIDsFromFragmentsWithoutRequests() async throws {
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let configuration = try fixture.configuration()
		let original = [ArticleTranslationSegment(id: "0", text: "Cached paragraph", context: "Surrounding sentence")]
		let missing = try await service.cachedTranslations(for: original, articleID: "article", configuration: configuration)
		XCTAssertNil(missing)
		try await service.translate(original, articleID: "article", configuration: configuration) { _, _, _ in }
		let count = fixture.requestCount
		let remapped = [ArticleTranslationSegment(id: "new-id", text: "Cached paragraph", context: "Surrounding sentence")]
		let cached = try await service.cachedTranslations(for: remapped, articleID: "another-article", configuration: configuration)
		XCTAssertEqual(cached, [ArticleTranslationSegment(id: "new-id", text: "译:Cached paragraph")])
		XCTAssertEqual(fixture.requestCount, count)
		let changed = try await service.cachedTranslations(for: [ArticleTranslationSegment(id: "new-id", text: "Different paragraph")], articleID: "article", configuration: configuration)
		XCTAssertNil(changed)
		let changedContext = try await service.cachedTranslations(for: [ArticleTranslationSegment(id: "0", text: "Cached paragraph", context: "Different context")], articleID: "article", configuration: configuration)
		XCTAssertNil(changedContext)
		let changedModel = try await service.cachedTranslations(for: original, articleID: "article", configuration: fixture.configuration(model: "other-model"))
		XCTAssertNil(changedModel)
		await service.clearCache()
		let cleared = try await service.cachedTranslations(for: original, articleID: "article", configuration: configuration)
		XCTAssertNil(cleared)
	}

	func testPartialCacheSnapshotDoesNotTreatUntranslatedParagraphsAsComplete() async throws {
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let configuration = try fixture.configuration()
		let first = ArticleTranslationSegment(id: "0", text: "Cached first paragraph")
		try await service.translate([first], configuration: configuration) { _, _, _ in }
		let partial = try await service.cachedTranslations(for: [first, ArticleTranslationSegment(id: "1", text: "Untranslated second paragraph")], configuration: configuration)
		XCTAssertNil(partial)
	}

	func testForegroundJoinsPrefetchAndSurvivesPrefetchCancellation() async throws {
		let fixture = TranslationFixture(hold: true)
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let started = expectation(description: "Prefetch request started")
		let duplicate = expectation(description: "No duplicate foreground request")
		duplicate.isInverted = true
		fixture.onRequest = { count, _ in if count == 1 { started.fulfill() } else { duplicate.fulfill() } }
		let segments = [ArticleTranslationSegment(id: "0", text: "Shared paragraph")]
		let configuration = try fixture.configuration()
		let prefetch = Task { try await service.translate(segments, configuration: configuration, priority: .background) { _, _, _ in } }
		await fulfillment(of: [started], timeout: 3)
		let joined = expectation(description: "Foreground collecting results")
		let foreground = Task {
			try await service.translate(segments, configuration: configuration) { _, done, _ in if done == 0 { joined.fulfill() } }
		}
		await fulfillment(of: [joined], timeout: 3)
		await fulfillment(of: [duplicate], timeout: 0.2)
		prefetch.cancel()
		do { try await prefetch.value; XCTFail("Prefetch should cancel") } catch is CancellationError { }
		fixture.releaseNext()
		try await foreground.value
		XCTAssertEqual(fixture.requestCount, 1)
	}

	func testQueuedForegroundRunsBeforeBackgroundAndSharesConcurrencyLimit() async throws {
		let fixture = TranslationFixture(hold: true)
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let configuration = try fixture.configuration()
		let first = expectation(description: "First background request")
		let second = expectation(description: "Foreground request scheduled next")
		fixture.onRequest = { count, texts in
			if count == 1 { first.fulfill() }
			if count == 2 { XCTAssertEqual(texts, ["Foreground"]); second.fulfill() }
		}
		let backgroundSegments = (0..<6).map { ArticleTranslationSegment(id: String($0), text: String(repeating: String($0), count: 2000)) }
		let background = Task { try await service.translate(backgroundSegments, configuration: configuration, maxConcurrentRequests: 1, priority: .background) { _, _, _ in } }
		await fulfillment(of: [first], timeout: 3)
		let queued = expectation(description: "Foreground queued")
		let foreground = Task {
			try await service.translate([ArticleTranslationSegment(id: "visible", text: "Foreground")], configuration: configuration, maxConcurrentRequests: 1) { _, done, _ in if done == 0 { queued.fulfill() } }
		}
		await fulfillment(of: [queued], timeout: 3)
		// The first batch is held until the foreground subscriber has entered the actor.
		let noEarlyRequest = expectation(description: "Only one active request")
		noEarlyRequest.isInverted = true
		await fulfillment(of: [noEarlyRequest], timeout: 0.1)
		fixture.releaseNext()
		await fulfillment(of: [second], timeout: 3)
		XCTAssertEqual(fixture.maximumActiveRequests, 1)
		background.cancel()
		fixture.releaseNext()
		try await foreground.value
		do { try await background.value; XCTFail("Background should cancel") } catch is CancellationError { }
	}

	func testChangedTextContextAndConfigurationDoNotReuseArticleCache() async throws {
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		for (text, context, model) in [("Old body", nil, "model"), ("New body", nil, "model"), ("New body", "Surrounding sentence", "model"), ("New body", "Surrounding sentence", "other-model")] {
			let configuration = try fixture.configuration(model: model)
			let output = TranslationOutput()
			try await service.translate([ArticleTranslationSegment(id: "0", text: text, context: context)], articleID: "same-id", configuration: configuration) { values, _, _ in await output.append(values) }
			let values = await output.values
			XCTAssertEqual(values.first?.text, "译:" + text)
		}
		XCTAssertEqual(fixture.requestCount, 4)
	}

	func testFailureCanBeRetriedAndClearingCacheRequestsAgain() async throws {
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let segments = [ArticleTranslationSegment(id: "0", text: "Retry paragraph")]
		fixture.failNextRequest = true
		do {
			try await service.translate(segments, articleID: "retry", configuration: fixture.configuration()) { _, _, _ in }
			XCTFail("First request should fail")
		} catch ArticleTranslationError.httpStatus(400) { }
		try await service.translate(segments, articleID: "retry", configuration: fixture.configuration()) { _, _, _ in }
		await service.clearCache()
		try await service.translate(segments, articleID: "retry", configuration: fixture.configuration()) { _, _, _ in }
		XCTAssertEqual(fixture.requestCount, 3)
	}

	func testClearCacheCancelsInFlightWorkWithoutRestoringOldResults() async throws {
		let fixture = TranslationFixture(hold: true)
		defer { fixture.cleanUp() }
		let service = fixture.service()
		let started = expectation(description: "Request started")
		fixture.onRequest = { _, _ in started.fulfill() }
		let configuration = try fixture.configuration()
		let task = Task { try await service.translate([ArticleTranslationSegment(id: "0", text: "Clear while running")], articleID: "article", configuration: configuration) { _, _, _ in } }
		await fulfillment(of: [started], timeout: 3)
		await service.clearCache()
		do { try await task.value; XCTFail("Clearing cache should cancel consumers") } catch is CancellationError { }
		fixture.onRequest = nil
		fixture.hold = false
		try await service.translate([ArticleTranslationSegment(id: "0", text: "Clear while running")], articleID: "article", configuration: configuration) { _, _, _ in }
		XCTAssertEqual(fixture.requestCount, 2)
	}

	func testClearingCacheDuringPreparationDoesNotStartStaleRequests() async throws {
		let fixture = TranslationFixture()
		defer { fixture.cleanUp() }
		let service = fixture.service()
		do {
			try await service.translate([ArticleTranslationSegment(id: "0", text: "Not yet registered")], configuration: fixture.configuration()) { _, completed, _ in
				if completed == 0 { await service.clearCache() }
			}
			XCTFail("Cleared operation should cancel")
		} catch is CancellationError { }
		XCTAssertEqual(fixture.requestCount, 0)
	}
}

private actor TranslationOutput {
	var values = [ArticleTranslationSegment]()
	func append(_ values: [ArticleTranslationSegment]) { self.values.append(contentsOf: values) }
}

/// A gated URLSession transport exercises real batching, queueing, cancellation and cache persistence.
final class TranslationFixture: @unchecked Sendable {
	private let lock = NSLock()
	let host = UUID().uuidString.lowercased() + ".invalid"
	let defaults: UserDefaults
	private var pending = [(TranslationTestProtocol, [ArticleTranslationSegment])]()
	private var count = 0
	private var maximum = 0
	private var shouldHold: Bool
	private var shouldFail = false
	private var callback: (@Sendable (Int, [String]) -> Void)?

	init(hold: Bool = false) {
		shouldHold = hold
		defaults = UserDefaults(suiteName: host)!
		TranslationTestProtocol.register(self)
	}

	var requestCount: Int { lock.withLock { count } }
	var maximumActiveRequests: Int { lock.withLock { maximum } }
	var hold: Bool {
		get { lock.withLock { shouldHold } }
		set { lock.withLock { shouldHold = newValue } }
	}
	var failNextRequest: Bool {
		get { lock.withLock { shouldFail } }
		set { lock.withLock { shouldFail = newValue } }
	}
	var onRequest: (@Sendable (Int, [String]) -> Void)? {
		get { lock.withLock { callback } }
		set { lock.withLock { callback = newValue } }
	}

	func service() -> ArticleTranslationService {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [TranslationTestProtocol.self]
		return ArticleTranslationService(session: URLSession(configuration: configuration), defaults: defaults)
	}

	func configuration(model: String = "model") throws -> ArticleTranslationConfiguration {
		try ArticleTranslationConfiguration(baseURL: "https://" + host, apiKey: "test-key", model: model, language: "中文")
	}

	fileprivate func start(_ transport: TranslationTestProtocol, segments: [ArticleTranslationSegment]) {
		let (number, held, callback) = lock.withLock {
			count += 1
			pending.append((transport, segments))
			maximum = max(maximum, pending.count)
			return (count, shouldHold, self.callback)
		}
		callback?(number, segments.map(\.text))
		if !held { releaseNext() }
	}

	fileprivate func stop(_ transport: TranslationTestProtocol) {
		lock.withLock { pending.removeAll { $0.0 === transport } }
	}

	func releaseNext() {
		let next = lock.withLock { () -> (TranslationTestProtocol, [ArticleTranslationSegment], Bool)? in
			guard !pending.isEmpty else { return nil }
			let (transport, segments) = pending.removeFirst()
			let fail = shouldFail
			shouldFail = false
			return (transport, segments, fail)
		}
		guard let (transport, segments, fail) = next else { return }
		transport.complete(segments, status: fail ? 400 : 200)
	}

	func cleanUp() {
		TranslationTestProtocol.unregister(host)
		defaults.removePersistentDomain(forName: host)
	}
}

private final class TranslationTestProtocol: URLProtocol, @unchecked Sendable {
	private static let registryLock = NSLock()
	nonisolated(unsafe) private static var fixtures = [String: TranslationFixture]()
	private var fixture: TranslationFixture?

	static func register(_ fixture: TranslationFixture) { registryLock.withLock { fixtures[fixture.host] = fixture } }
	static func unregister(_ host: String) { registryLock.withLock { _ = fixtures.removeValue(forKey: host) } }
	override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		do {
			guard let host = request.url?.host, let fixture = Self.registryLock.withLock({ Self.fixtures[host] }) else { throw URLError(.badURL) }
			self.fixture = fixture
			var data = request.httpBody ?? Data()
			if let stream = request.httpBodyStream {
				stream.open()
				defer { stream.close() }
				var buffer = [UInt8](repeating: 0, count: 4096)
				while stream.hasBytesAvailable {
					let count = stream.read(&buffer, maxLength: buffer.count)
					if count <= 0 { break }
					data.append(contentsOf: buffer.prefix(count))
				}
			}
			let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
			let input = try XCTUnwrap(body["input"] as? String)
			let segments = try JSONDecoder().decode([ArticleTranslationSegment].self, from: Data(input.utf8))
			fixture.start(self, segments: segments)
		} catch { client?.urlProtocol(self, didFailWithError: error) }
	}

	override func stopLoading() { fixture?.stop(self) }

	func complete(_ segments: [ArticleTranslationSegment], status: Int) {
		do {
			let text = try JSONSerialization.data(withJSONObject: ["translations": segments.map { ["id": $0.id, "text": "译:" + $0.text] }])
			let data = try JSONSerialization.data(withJSONObject: ["status": "completed", "output_text": String(decoding: text, as: UTF8.self)])
			let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		} catch { client?.urlProtocol(self, didFailWithError: error) }
	}
}
