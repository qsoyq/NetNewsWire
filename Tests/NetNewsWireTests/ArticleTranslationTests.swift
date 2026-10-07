import XCTest
@testable import NetNewsWire

final class ArticleTranslationTests: XCTestCase {
	func testResponsesEndpointNormalization() throws {
		for address in ["https://example.com/v1", "https://example.com/v1/"] {
			XCTAssertEqual(try configuration(address).endpoint.absoluteString, "https://example.com/v1/responses")
		}
		XCTAssertEqual(try configuration("https://example.com/custom?api-version=2026").endpoint.absoluteString, "https://example.com/custom/responses?api-version=2026")
		let custom = try ArticleTranslationConfiguration(baseURL: "https://example.com", path: "/gateway/v1/responses", apiKey: "test", model: "test", language: "英语")
		XCTAssertEqual(custom.endpoint.absoluteString, "https://example.com/gateway/v1/responses")
		let trailingPath = try ArticleTranslationConfiguration(baseURL: "https://example.com", path: "/custom/responses/?version=1", apiKey: "test", model: "test", language: "英语")
		XCTAssertEqual(trailingPath.endpoint.absoluteString, "https://example.com/custom/responses/?version=1")
		let emptyPath = try ArticleTranslationConfiguration(baseURL: "https://example.com/v1/", path: " ", apiKey: "test", model: "test", language: "英语")
		XCTAssertEqual(emptyPath.endpoint.absoluteString, "https://example.com/v1/responses")
		XCTAssertThrowsError(try ArticleTranslationConfiguration(baseURL: "https://example.com", path: "https://other.com/responses", apiKey: "test", model: "test", language: "英语"))
		XCTAssertThrowsError(try ArticleTranslationConfiguration(baseURL: "https://example.com", path: "//other.com/responses", apiKey: "test", model: "test", language: "英语"))
	}

	func testLegacyPreferencesMigrateWithoutLosingModesOrModel() throws {
		for address in ["https://example.com", "https://example.com/v1", "https://example.com/v1/responses"] {
			let data = try JSONSerialization.data(withJSONObject: ["baseURL": address, "model": "saved-model", "language": "English", "automaticallyTranslate": true, "manuallyTranslate": true])
			let preferences = try JSONDecoder().decode(ArticleTranslationPreferences.self, from: data)
			XCTAssertEqual(preferences.baseURL, "https://example.com/v1")
			XCTAssertEqual(preferences.path, "")
			XCTAssertEqual(preferences.model, "saved-model")
			XCTAssertEqual(preferences.language, .english)
			XCTAssertEqual(preferences.displayMode, .bilingual)
			XCTAssertTrue(preferences.automaticallyTranslate && preferences.manuallyTranslate)
			XCTAssertFalse(preferences.prefetchNextArticleTranslation)
		}
	}

	func testNewPreferencesRoundTripAllLanguagesAndReplacementMode() throws {
		XCTAssertEqual(ArticleTranslationPreferences().language, .simplifiedChinese)
		XCTAssertEqual(ArticleTranslationLanguage.allCases.count, 4)
		for language in ArticleTranslationLanguage.allCases {
			var preferences = ArticleTranslationPreferences()
			preferences.path = "/custom/responses"
			preferences.displayMode = .replaceOriginal
			preferences.prefetchNextArticleTranslation = true
			preferences.language = language
			let encoded = try JSONEncoder().encode(preferences)
			XCTAssertEqual(try JSONDecoder().decode(ArticleTranslationPreferences.self, from: encoded), preferences)
		}
	}

	func testInvalidConfigurationIsRejectedBeforeRequests() {
		XCTAssertThrowsError(try configuration("ftp://example.com"))
		XCTAssertThrowsError(try configuration("https://user:password@example.com"))
		XCTAssertThrowsError(try ArticleTranslationConfiguration(baseURL: "https://example.com", apiKey: " ", model: "test", language: "中文"))
		XCTAssertThrowsError(try ArticleTranslationConfiguration(baseURL: "https://example.com", apiKey: "test", model: " ", language: "中文"))
	}

	func testRequestUsesResponsesProtocolAndKeepsSegmentIDs() throws {
		let segments = [ArticleTranslationSegment(id: "title:0", text: "A title"), ArticleTranslationSegment(id: "body:0", text: "Quote: \"hello\"\nNext line")]
		let request = try configuration().request(for: segments)
		XCTAssertEqual(request.httpMethod, "POST")
		XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
		let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
		XCTAssertEqual(body["model"] as? String, "test-model")
		XCTAssertEqual(body["store"] as? Bool, false)
		XCTAssertEqual(body["stream"] as? Bool, false)
		XCTAssertNil(body["messages"])
		let input = try XCTUnwrap(body["input"] as? String)
		XCTAssertEqual(try JSONDecoder().decode([ArticleTranslationSegment].self, from: Data(input.utf8)), segments)
	}

	func testResponseReadsMessageTextAndSkipsReasoning() throws {
		let data = Data(#"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"{\"translations\":["}]},{"type":"message","content":[{"type":"output_text","text":"{\"id\":\"a\",\"text\":\"你好\"}]}"}]}]}"#.utf8)
		XCTAssertEqual(try ArticleTranslationResponse.translations(from: data, expected: expected), [ArticleTranslationSegment(id: "a", text: "你好")])
	}

	func testCompatibleOutputTextAndMarkdownFences() throws {
		let text = "```json\n{\"translations\":[{\"id\":\"a\",\"text\":\"你好\"}]}\n```"
		let data = try JSONSerialization.data(withJSONObject: ["output_text": text])
		XCTAssertEqual(try ArticleTranslationResponse.translations(from: data, expected: expected).first?.text, "你好")
	}

	func testIncompleteRefusedOrMissingTranslationsAreRejected() throws {
		for json in [
			#"{"status":"incomplete","output_text":"{\"translations\":[{\"id\":\"a\",\"text\":\"partial\"}]}"}"#,
			#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"declined"}]}]}"#,
			#"{"output_text":"{\"translations\":[]}"}"#,
			#"{"output_text":"{\"translations\":[{\"id\":\"wrong\",\"text\":\"wrong paragraph\"}]}"}"#,
			#"{"output_text":"{\"translations\":[{\"id\":\"a\",\"text\":\"\"}]}"}"#
		] {
			XCTAssertThrowsError(try ArticleTranslationResponse.translations(from: Data(json.utf8), expected: expected))
		}
	}

	func testDuplicateIDsCannotReplaceMissingParagraphs() throws {
		let data = Data(#"{"output_text":"{\"translations\":[{\"id\":\"a\",\"text\":\"one\"},{\"id\":\"a\",\"text\":\"two\"}]}"}"#.utf8)
		XCTAssertThrowsError(try ArticleTranslationResponse.translations(from: data, expected: expected + [ArticleTranslationSegment(id: "b", text: "Second")]))
	}

	func testLongTextSplittingPreservesAllUnicodeText() {
		let source = String(repeating: "Hello world. 中文段落 👨‍👩‍👧‍👦 and café!\n", count: 400)
		let chunks = ArticleTranslationService.chunks(of: source)
		XCTAssertGreaterThan(source.count, 4000)
		XCTAssertGreaterThan(chunks.count, 1)
		XCTAssertEqual(chunks.joined(), source)
		XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 2000 })
	}

	func testCacheSeparatesProviderModelAndLanguage() throws {
		let first = try configuration().cacheKey(for: "Hello")
		let alternate = try ArticleTranslationConfiguration(baseURL: "https://example.com", apiKey: "test-key", model: "other-model", language: "日本語")
		XCTAssertNotEqual(first, alternate.cacheKey(for: "Hello"))
		XCTAssertNotEqual(first, try configuration("https://other.example.com").cacheKey(for: "Hello"))
		XCTAssertEqual(first.count, 64)
		XCTAssertFalse(first.contains("test-key"))
		XCTAssertNotEqual(first, try configuration().cacheKey(for: "Hello", context: "A different sentence."))
	}

	private var expected: [ArticleTranslationSegment] { [ArticleTranslationSegment(id: "a", text: "Hello")] }
	private func configuration(_ baseURL: String = "https://example.com") throws -> ArticleTranslationConfiguration {
		try ArticleTranslationConfiguration(baseURL: baseURL, apiKey: "test-key", model: "test-model", language: "简体中文")
	}
}
