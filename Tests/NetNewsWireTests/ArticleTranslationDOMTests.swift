import XCTest
import WebKit

@MainActor final class ArticleTranslationDOMTests: XCTestCase {
	func testBilingualTranslationPreservesContentAndRestoresOriginalHTML() async throws {
		let webView = try await makeWebView()
		let original = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		try await configure(webView, document: "first")
		let snapshot = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		let json = try XCTUnwrap(snapshot as? String)
		let segments = try JSONDecoder().decode([Segment].self, from: Data(json.utf8))
		XCTAssertFalse(segments.contains { $0.text == "Article title" })
		XCTAssertTrue(segments.contains { $0.text == "Hello world and friends." })
		XCTAssertTrue(segments.contains { $0.text == "Bare text before the paragraph." })
		XCTAssertTrue(segments.contains { $0.text == "A nested quote." })
		XCTAssertTrue(segments.contains { $0.text == "A list item." })
		XCTAssertTrue(segments.contains { $0.text == "Table cell." })
		XCTAssertFalse(segments.contains { $0.text.contains("Do not translate") })
		let translations = segments.map { ["id": $0.id, "text": "译文 <img src=x onerror=alert(1)> & \"quoted\"\n下一行"] }
		_ = try await evaluate("window.nnwTranslation.apply('first', translations);", arguments: ["translations": translations], in: webView)
		let count = try await evaluate("return document.querySelectorAll('.nnw-translation-text').length;", in: webView) as? Int
		XCTAssertEqual(count, segments.count)
		let inlineImages = try await evaluate("return document.querySelectorAll('.nnw-translation-text img').length;", in: webView) as? Int
		XCTAssertEqual(inlineImages, 0)
		let link = try await evaluate("return document.getElementById('original-link').getAttribute('href');", in: webView) as? String
		XCTAssertEqual(link, "https://example.com/path")
		let image = try await evaluate("return document.getElementById('original-image').getAttribute('src');", in: webView) as? String
		XCTAssertEqual(image, "https://example.com/image.png")
		let repeatedSnapshot = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		let repeated = try XCTUnwrap(repeatedSnapshot as? String)
		XCTAssertEqual(try JSONDecoder().decode([Segment].self, from: Data(repeated.utf8)), segments)
		_ = try await evaluate("window.nnwTranslation.restore('first');", in: webView)
		let restored = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		XCTAssertEqual(restored, original)
	}

	func testReplacementTranslatesTextInPlacePreservesMarkupAndCanRetryAndRestore() async throws {
		let webView = try await makeWebView()
		let original = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		try await configure(webView, document: "replacement", replacement: true)
		let snapshot = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		let segments = try JSONDecoder().decode([Segment].self, from: Data(try XCTUnwrap(snapshot as? String).utf8))
		XCTAssertFalse(segments.contains { $0.text == "Article title" })
		XCTAssertTrue(segments.contains { $0.text == "world" && $0.context?.contains("Hello world and friends.") == true })
		let translations = segments.map { ["id": $0.id, "text": "译文 <img src=x onerror=alert(1)>"] }
		_ = try await evaluate("window.nnwTranslation.apply('replacement', translations);", arguments: ["translations": translations], in: webView)
		let originalNodes = try await evaluate("return document.querySelector('.articleBody p').textContent.includes('Hello');", in: webView) as? Bool
		XCTAssertEqual(originalNodes, false)
		let title = try await evaluate("return document.querySelector('.articleTitle').textContent;", in: webView) as? String
		XCTAssertEqual(title, "Article title")
		let link = try await evaluate("return document.getElementById('original-link').getAttribute('href');", in: webView) as? String
		XCTAssertEqual(link, "https://example.com/path")
		let translatedLink = try await evaluate("return document.getElementById('original-link').textContent;", in: webView) as? String
		XCTAssertEqual(translatedLink, "译文 <img src=x onerror=alert(1)>")
		let injectedImages = try await evaluate("return document.querySelectorAll('.articleBody img').length;", in: webView) as? Int
		XCTAssertEqual(injectedImages, 1)
		let repeated = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		XCTAssertEqual(try JSONDecoder().decode([Segment].self, from: Data(try XCTUnwrap(repeated as? String).utf8)), segments)
		_ = try await evaluate("window.nnwTranslation.restore('replacement');", in: webView)
		let restored = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		XCTAssertEqual(restored, original)
	}

	func testStaleDocumentResultsAndDisabledModesDoNotChangeThePage() async throws {
		let webView = try await makeWebView(contentJavaScript: false)
		try await configure(webView, document: "old")
		_ = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		try await configure(webView, document: "new", manual: false)
		_ = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		_ = try await evaluate("window.nnwTranslation.apply('old', [{id:'0',text:'Wrong article'}]);", in: webView)
		let count = try await evaluate("return document.querySelectorAll('.nnw-translation-text').length;", in: webView) as? Int
		XCTAssertEqual(count, 0)
		let manualHidden = try await evaluate("return document.querySelector('.nnw-translation-controls button').hidden;", in: webView) as? Bool
		XCTAssertEqual(manualHidden, true)
		try await configure(webView, document: "off", enabled: false)
		let controls = try await evaluate("return document.querySelectorAll('.nnw-translation-controls').length;", in: webView) as? Int
		XCTAssertEqual(controls, 0)
	}

	func testReplacementHandlesRepeatedSpacesAndTabsAndRestoresExactly() async throws {
		let webView = try await makeWebView()
		for (index, original) in ["Hello  world", "Hello\tworld", "  Hello  \tworld  "].enumerated() {
			let document = "whitespace-\(index)"
			try await configure(webView, document: document, replacement: true)
			_ = try await evaluate("document.querySelector('.articleBody p').textContent = original;", arguments: ["original": original], in: webView)
			let snapshot = try await evaluate("return window.nnwTranslation.collect();", in: webView)
			let segments = try JSONDecoder().decode([Segment].self, from: Data(try XCTUnwrap(snapshot as? String).utf8))
			let segment = try XCTUnwrap(segments.first { $0.text == original.trimmingCharacters(in: .whitespacesAndNewlines) })
			_ = try await evaluate("window.nnwTranslation.apply(documentID, [{id: segmentID, text: '你好世界'}]);", arguments: ["documentID": document, "segmentID": segment.id], in: webView)
			let translated = try await evaluate("return document.querySelector('.articleBody p').textContent;", in: webView) as? String
			XCTAssertEqual(translated?.trimmingCharacters(in: .whitespacesAndNewlines), "你好世界")
			_ = try await evaluate("window.nnwTranslation.restore(documentID);", arguments: ["documentID": document], in: webView)
			let restored = try await evaluate("return document.querySelector('.articleBody p').textContent;", in: webView) as? String
			XCTAssertEqual(restored, original)
		}
	}

	func testPageScriptsCannotTriggerTranslationOrRestoreThroughSyntheticClicks() async throws {
		let recorder = MessageRecorder()
		let webView = try await makeWebView(recorder: recorder)
		try await configure(webView, document: "synthetic")
		_ = try await webView.evaluateJavaScript("document.querySelectorAll('.nnw-translation-controls button').forEach(button => button.click());")
		try await Task.sleep(for: .milliseconds(150))
		XCTAssertTrue(recorder.actions.isEmpty)
	}

	private struct Segment: Decodable, Equatable {
		let id: String
		let text: String
		let context: String?
	}

	private func configure(_ webView: WKWebView, document: String, manual: Bool = true, enabled: Bool = true, replacement: Bool = false) async throws {
		_ = try await evaluate("window.nnwTranslation.configure(configuration);", arguments: ["configuration": [
			"documentID": document, "enabled": enabled, "manualEnabled": manual,
			"displayMode": replacement ? "replaceOriginal" : "bilingual",
			"labels": ["title": "翻译", "translate": "翻译", "retry": "重试翻译", "stop": "停止", "restore": "恢复原文", "working": "翻译中", "done": "已翻译", "paused": "已暂停", "failed": "翻译失败", "original": "原文"]
		]], in: webView)
	}

	private func evaluate(_ script: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> Any? {
		try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: WKContentWorld.world(name: "TranslationDOMTests"))
	}

	private func makeWebView(contentJavaScript: Bool = true, recorder: MessageRecorder? = nil) async throws -> WKWebView {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let source = try String(contentsOf: root.appendingPathComponent("Shared/Article Translation/translation.js"), encoding: .utf8)
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = contentJavaScript
		if let recorder {
			configuration.userContentController.add(recorder, contentWorld: WKContentWorld.world(name: "TranslationDOMTests"), name: "articleTranslation")
		}
		configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: WKContentWorld.world(name: "TranslationDOMTests")))
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 800), configuration: configuration)
		let loader = Loader()
		webView.navigationDelegate = loader
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			loader.continuation = continuation
			webView.loadHTMLString(Self.html, baseURL: nil)
		}
		webView.navigationDelegate = nil
		return webView
	}

	private final class MessageRecorder: NSObject, WKScriptMessageHandler {
		var actions = [String]()
		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			if let body = message.body as? [String: String], let action = body["action"] {
				actions.append(action)
			}
		}
	}

	private final class Loader: NSObject, WKNavigationDelegate {
		var continuation: CheckedContinuation<Void, Error>?
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			continuation?.resume()
			continuation = nil
		}
		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
			continuation?.resume(throwing: error)
			continuation = nil
		}
		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			continuation?.resume(throwing: error)
			continuation = nil
		}
	}

	private static let html = """
	<html><head><meta name="viewport" content="width=device-width"></head><body>
	<div class="articleTitle"><h1><a href="https://example.com">Article title</a></h1></div>
	<div class="articleBody">Bare text before the paragraph.
	<p>Hello <a id="original-link" href="https://example.com/path">world</a> and <b>friends</b>.</p>
	<blockquote><p>A nested quote.</p></blockquote><ul><li>A list item.</li></ul>
	<table><tr><td>Table cell.</td></tr></table>
	<pre>Do not translate code.</pre><p hidden>Do not translate hidden text.</p>
	<p style="display:none">Do not translate invisible text.</p><p translate="no">Do not translate excluded text.</p>
	<img id="original-image" src="https://example.com/image.png">
	</div></body></html>
	"""
}
