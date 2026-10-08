import XCTest
import WebKit
@testable import NetNewsWire

@MainActor final class ArticleTranslationDOMTests: XCTestCase {
	func testBackgroundDocumentCollectsTheSameDOMUnitsInBothDisplayModes() async throws {
		for mode in ArticleTranslationDisplayMode.allCases {
			var preferences = ArticleTranslationPreferences()
			preferences.automaticallyTranslate = true
			preferences.displayMode = mode
			let foreground = try await makeWebView(contentJavaScript: false)
			try await configure(foreground, document: "foreground", replacement: mode == .replaceOriginal)
			let snapshot = try await evaluate("return window.nnwTranslation.collect();", in: foreground)
			let json = try XCTUnwrap(snapshot as? String)
			let expected = try JSONDecoder().decode([ArticleTranslationSegment].self, from: Data(json.utf8))
			let background = try await ArticleTranslationDocument().segments(html: Self.html, baseURL: nil, preferences: preferences, size: CGSize(width: 375, height: 800))
			XCTAssertEqual(background, expected)
		}
	}

	func testBackgroundDocumentDoesNotRunPageScripts() async throws {
		var preferences = ArticleTranslationPreferences()
		preferences.automaticallyTranslate = true
		let html = "<div class='articleBody'><p>Original paragraph</p></div><script>document.querySelector('p').textContent='Page script ran';</script>"
		let segments = try await ArticleTranslationDocument().segments(html: html, baseURL: nil, preferences: preferences, size: CGSize(width: 375, height: 800))
		XCTAssertEqual(segments.map(\.text), ["Original paragraph"])
	}

	func testBilingualTranslationPreservesContentAndRestoresOriginalHTML() async throws {
		let webView = try await makeWebView()
		let original = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		try await configure(webView, document: "first")
		let snapshot = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		let json = try XCTUnwrap(snapshot as? String)
		let segments = try JSONDecoder().decode([Segment].self, from: Data(json.utf8))
		XCTAssertFalse(segments.contains { $0.text == "Article title" })
		XCTAssertTrue(segments.contains { $0.text == "world" && $0.context == "Hello world and friends." })
		XCTAssertTrue(segments.contains { $0.text == "Bare text before the paragraph." })
		XCTAssertTrue(segments.contains { $0.text == "A nested quote." })
		XCTAssertTrue(segments.contains { $0.text == "A list item." })
		XCTAssertTrue(segments.contains { $0.text == "Table cell." })
		XCTAssertFalse(segments.contains { $0.text.contains("Do not translate") })
		let translations = segments.map { ["id": $0.id, "text": "译文 <img src=x onerror=alert(1)> & \"quoted\"\n下一行"] }
		_ = try await evaluate("window.nnwTranslation.apply('first', translations);", arguments: ["translations": translations], in: webView)
		let count = try await evaluate("return document.querySelectorAll('.nnw-translation-text').length;", in: webView) as? Int
		XCTAssertEqual(count, 5)
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
		let controls = try await evaluate("return document.querySelectorAll('.nnw-translation-controls').length;", in: webView) as? Int
		XCTAssertEqual(controls, 0)
		try await configure(webView, document: "off", enabled: false)
		let disabledControls = try await evaluate("return document.querySelectorAll('.nnw-translation-controls').length;", in: webView) as? Int
		XCTAssertEqual(disabledControls, 0)
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

	func testFoldedArticleKeepsSummaryBodyAndExternalLinkSeparateInBothModes() async throws {
		for replacement in [false, true] {
			let webView = try await makeWebView(contentJavaScript: false, html: Self.foldedArticleHTML)
			let original = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
			try await configure(webView, document: "folded", replacement: replacement)
			let segments = try await collect(webView)
			XCTAssertEqual(segments.count, 5)
			XCTAssertEqual(segments.first?.text, "查看正文")
			XCTAssertEqual(segments.first?.context, "查看正文")
			XCTAssertEqual(segments.last?.context, "查看原贴")
			XCTAssertTrue(segments.dropFirst().dropLast().allSatisfy { $0.context == $0.text })
			_ = try await evaluate("document.querySelector('details').open = true; window.nnwTranslation.apply('folded', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "译:" + $0.text] }], in: webView)
			let summary = try await evaluate("return document.querySelector('summary').textContent;", in: webView) as? String
			XCTAssertEqual(summary, replacement ? "译:查看正文" : "查看正文译:查看正文")
			let paragraphs = try await evaluate("return document.querySelectorAll('details p').length;", in: webView) as? Int
			XCTAssertEqual(paragraphs, 3)
			let outsideLink = try await evaluate("return !document.querySelector('a').closest('details');", in: webView) as? Bool
			XCTAssertEqual(outsideLink, true)
			let repeated = try await collect(webView)
			XCTAssertEqual(repeated, segments)
			_ = try await evaluate("window.nnwTranslation.restore('folded'); document.querySelector('details').open = false;", in: webView)
			let restored = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
			XCTAssertEqual(restored, original)
		}
	}

	func testCollectorCoversBareTextAndUsesIdenticalNodeUnitsInBothModes() async throws {
		let html = "<div class='articleBody'>Before <em>emphasis</em> after<p>Paragraph <a href='/path'>link</a> end<br>Next line</p>Between<ul><li>Outer<ul><li>Inner</li></ul>Tail</li></ul><table><tr><td>Cell</td></tr></table>Last</div>"
		var snapshots = [[Segment]]()
		for replacement in [false, true] {
			let webView = try await makeWebView(html: html)
			try await configure(webView, document: "nodes", replacement: replacement)
			let segments = try await collect(webView)
			snapshots.append(segments)
			XCTAssertEqual(segments.map(\.text), ["Before", "emphasis", "after", "Paragraph", "link", "end", "Next line", "Between", "Outer", "Inner", "Tail", "Cell", "Last"])
			XCTAssertEqual(segments.first?.context, "Before emphasis after")
			XCTAssertEqual(segments.first { $0.text == "Next line" }?.context, "Paragraph link end\nNext line")
			XCTAssertEqual(segments.first { $0.text == "Outer" }?.context, "Outer")
			XCTAssertEqual(segments.last?.context, "Last")
		}
		XCTAssertEqual(snapshots.first, snapshots.last)
	}

	func testBilingualGroupsOutOfOrderNodeResultsWithoutLosingSpacesOrBreaks() async throws {
		let webView = try await makeWebView(html: "<div class='articleBody'><p>Hello <a href='/world'>world</a>!<br> Next line </p></div>")
		let original = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		try await configure(webView, document: "group")
		let segments = try await collect(webView)
		XCTAssertEqual(segments.map(\.text), ["Hello", "world", "!", "Next line"])
		for segment in segments.reversed().dropLast() {
			_ = try await evaluate("window.nnwTranslation.apply('group', translations);", arguments: ["translations": [["id": segment.id, "text": segment.text.uppercased()]]], in: webView)
		}
		let partialCount = try await evaluate("return document.querySelectorAll('[data-nnw-translation]').length;", in: webView) as? Int
		XCTAssertEqual(partialCount, 0)
		let first = try XCTUnwrap(segments.first)
		_ = try await evaluate("window.nnwTranslation.apply('group', translations);", arguments: ["translations": [["id": first.id, "text": first.text.uppercased()]]], in: webView)
		let translated = try await evaluate("return document.querySelector('.nnw-translation-text').textContent;", in: webView) as? String
		XCTAssertEqual(translated, "HELLO WORLD!\n NEXT LINE")
		let linkOutput = try await evaluate("return document.querySelector('a .nnw-translation-text') === null;", in: webView) as? Bool
		XCTAssertEqual(linkOutput, true)
		let repeated = try await collect(webView)
		XCTAssertEqual(repeated, segments)
		_ = try await evaluate("window.nnwTranslation.restore('group');", in: webView)
		let restored = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		XCTAssertEqual(restored, original)
	}

	func testNodeReferencesSurviveSiblingInsertionWithoutUsingShiftedPaths() async throws {
		for replacement in [false, true] {
			let webView = try await makeWebView(html: "<div class='articleBody'><p id='target'>Original</p></div>")
			try await configure(webView, document: "insertion", replacement: replacement)
			let segments = try await collect(webView)
			_ = try await evaluate("document.querySelector('.articleBody').insertAdjacentHTML('afterbegin', '<p id=inserted>New sibling</p>'); window.nnwTranslation.apply('insertion', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "Translated"] }], in: webView)
			let target = try await evaluate("return document.getElementById('target').textContent;", in: webView) as? String
			XCTAssertEqual(target, replacement ? "Translated" : "OriginalTranslated")
			let inserted = try await evaluate("return document.getElementById('inserted').textContent;", in: webView) as? String
			XCTAssertEqual(inserted, "New sibling")
			let recollected = try await collect(webView)
			XCTAssertEqual(recollected.first { $0.text == "Original" }?.id, segments.first?.id)
		}
	}

	func testInlineWrapperContainingBlocksKeepsBilingualOutputInSourceOrder() async throws {
		let webView = try await makeWebView(html: "<div class='articleBody'><span>before<div>nested</div>after</span></div>")
		let original = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		try await configure(webView, document: "wrapper")
		let segments = try await collect(webView)
		XCTAssertEqual(segments.map(\.text), ["before", "nested", "after"])
		XCTAssertEqual(segments.map(\.context), ["before", "nested", "after"])
		_ = try await evaluate("window.nnwTranslation.apply('wrapper', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "译:" + $0.text] }], in: webView)
		let text = try await evaluate("return document.querySelector('.articleBody').textContent;", in: webView) as? String
		XCTAssertEqual(text, "before译:beforenested译:nestedafter译:after")
		let repeated = try await collect(webView)
		XCTAssertEqual(repeated, segments)
		_ = try await evaluate("window.nnwTranslation.restore('wrapper');", in: webView)
		let restored = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
		XCTAssertEqual(restored, original)
	}

	func testDetachedMovedChangedAndReplacedNodesRejectLateResults() async throws {
		for replacement in [false, true] {
			for mutation in [
				"target.remove();",
				"document.getElementById('outside').appendChild(target);",
				"target.firstChild.data = '  Original';",
				"target.innerHTML = 'Original';"
			] {
				let webView = try await makeWebView(html: "<div class='articleBody'><p id='target'>Original</p></div><div id='outside'></div>")
				try await configure(webView, document: "late", replacement: replacement)
				let segments = try await collect(webView)
				_ = try await evaluate("const target = document.getElementById('target'); " + mutation + " window.nnwTranslation.apply('late', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "WRONG RESULT"] }], in: webView)
				let wrong = try await evaluate("return document.body.textContent.includes('WRONG RESULT');", in: webView) as? Bool
				XCTAssertEqual(wrong, false, mutation)
			}
		}
	}

	func testRecollectingChangedTextDoesNotRetargetOldResults() async throws {
		for replacement in [false, true] {
			let webView = try await makeWebView(html: "<div class='articleBody'><p id='target'>Original</p><p>Unchanged</p></div>")
			try await configure(webView, document: "recollect", replacement: replacement)
			let old = try await collect(webView)
			_ = try await evaluate("document.getElementById('target').firstChild.data = 'Updated';", in: webView)
			let current = try await collect(webView)
			XCTAssertNotEqual(current.first?.id, old.first?.id)
			XCTAssertEqual(current.last?.id, old.last?.id)
			_ = try await evaluate("window.nnwTranslation.apply('recollect', translations);", arguments: ["translations": [["id": try XCTUnwrap(old.first?.id), "text": "STALE RESULT"]]], in: webView)
			let afterOldResult = try await evaluate("return document.getElementById('target').textContent;", in: webView) as? String
			XCTAssertEqual(afterOldResult, "Updated")
			_ = try await evaluate("window.nnwTranslation.apply('recollect', translations);", arguments: ["translations": [["id": try XCTUnwrap(current.first?.id), "text": "Current translation"]]], in: webView)
			let afterCurrentResult = try await evaluate("return document.getElementById('target').textContent;", in: webView) as? String
			XCTAssertEqual(afterCurrentResult, replacement ? "Current translation" : "UpdatedCurrent translation")
			_ = try await evaluate("window.nnwTranslation.restore('recollect');", in: webView)
			let restored = try await evaluate("return document.getElementById('target').textContent;", in: webView) as? String
			XCTAssertEqual(restored, "Updated")
		}
	}

	func testRecollectingChangedGroupRemovesOldBilingualOutputAndRejectsStaleContext() async throws {
		let webView = try await makeWebView(html: "<div class='articleBody'><p>Hello <b>world</b></p></div>")
		try await configure(webView, document: "context")
		let old = try await collect(webView)
		_ = try await evaluate("window.nnwTranslation.apply('context', translations);", arguments: ["translations": old.map { ["id": $0.id, "text": "OLD TRANSLATION"] }], in: webView)
		_ = try await evaluate("document.querySelector('b').firstChild.data = 'friends';", in: webView)
		let current = try await collect(webView)
		XCTAssertEqual(current.map(\.text), ["Hello", "friends"])
		XCTAssertNotEqual(current.first?.id, old.first?.id)
		_ = try await evaluate("window.nnwTranslation.apply('context', translations);", arguments: ["translations": old.map { ["id": $0.id, "text": "STALE RESULT"] }], in: webView)
		let pendingText = try await evaluate("return document.querySelector('p').textContent;", in: webView) as? String
		XCTAssertEqual(pendingText, "Hello friends")
		_ = try await evaluate("window.nnwTranslation.apply('context', translations);", arguments: ["translations": current.map { ["id": $0.id, "text": $0.text.uppercased()] }], in: webView)
		let completedText = try await evaluate("return document.querySelector('p').textContent;", in: webView) as? String
		XCTAssertEqual(completedText, "Hello friendsHELLO FRIENDS")
	}

	func testSummaryBoundaryOverridesInlineStylesAndContextLimitPreservesUnicode() async throws {
		let longText = String(repeating: "🙂", count: 610)
		let webView = try await makeWebView(html: "<div class='articleBody'><details><summary style='display:inline'>Label</summary>Body outside paragraphs</details><p>\(longText)</p></div>")
		try await configure(webView, document: "boundaries", replacement: true)
		let segments = try await collect(webView)
		XCTAssertEqual(segments.map(\.context), ["Label", "Body outside paragraphs", String(repeating: "🙂", count: 600)])
		XCTAssertEqual(segments.last?.text, longText)
	}

	func testV2EXURLLabelsArePreservedInBothModesAndNotSentForTranslation() async throws {
		for replacement in [false, true] {
			let webView = try await makeWebView(html: "<div class='articleBody'>" + Self.v2exURLArticleContent + "</div>")
			let original = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
			try await configure(webView, document: "v2ex", replacement: replacement)
			let segments = try await collect(webView)
			XCTAssertEqual(segments.count, 4)
			XCTAssertFalse(segments.contains { $0.text.hasPrefix("https://") })
			XCTAssertEqual(segments.last?.text, "查看原贴")
			XCTAssertTrue(segments.first?.context?.contains("https://www.v2ex.com/t/1003989") == true)
			_ = try await evaluate("window.nnwTranslation.apply('v2ex', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "译:" + $0.text] }], in: webView)
			let labels = try await evaluate("return Array.from(document.querySelectorAll('a'), a => a.textContent);", in: webView) as? [String]
			XCTAssertEqual(labels, ["https://www.v2ex.com/t/1003989", "https://easyalarm.pages.dev", replacement ? "译:查看原贴" : "查看原贴"])
			let hrefs = try await evaluate("return Array.from(document.querySelectorAll('a'), a => a.getAttribute('href'));", in: webView) as? [String]
			XCTAssertEqual(hrefs, ["https://www.v2ex.com/t/1003989", "https://easyalarm.pages.dev/", "https://www.v2ex.com/t/1246886"])
			if !replacement {
				let translated = try await evaluate("return document.querySelector('.nnw-translation-text').textContent;", in: webView) as? String
				XCTAssertTrue(translated?.contains("（ https://www.v2ex.com/t/1003989 ") == true)
				XCTAssertTrue(translated?.contains("（ https://easyalarm.pages.dev ") == true)
			}
			let repeated = try await collect(webView)
			XCTAssertEqual(repeated, segments)
			_ = try await evaluate("window.nnwTranslation.restore('v2ex');", in: webView)
			let restored = try await evaluate("return document.querySelector('.articleBody').innerHTML;", in: webView) as? String
			XCTAssertEqual(restored, original)
		}
	}

	func testCollectorPreservesBareAndSplitURLsWhileTranslatingDescriptiveLinks() async throws {
		let html = "<div class='articleBody'><p>https://example.com/bare</p><p><a href='https://example.com/split'><span>https://</span><b>example.com</b><span>/split</span></a></p><p><a href='https://example.com'>Example website</a> and visit https://example.com today</p></div>"
		for replacement in [false, true] {
			let webView = try await makeWebView(html: html)
			try await configure(webView, document: "url-labels", replacement: replacement)
			let segments = try await collect(webView)
			XCTAssertEqual(segments.map(\.text), ["Example website", "and visit https://example.com today"])
			_ = try await evaluate("window.nnwTranslation.apply('url-labels', translations);", arguments: ["translations": segments.map { ["id": $0.id, "text": "译:" + $0.text] }], in: webView)
			let bareURL = try await evaluate("return document.querySelector('p').textContent;", in: webView) as? String
			XCTAssertEqual(bareURL, "https://example.com/bare")
			let splitURL = try await evaluate("return document.querySelector('a').innerHTML;", in: webView) as? String
			XCTAssertEqual(splitURL, "<span>https://</span><b>example.com</b><span>/split</span>")
		}
	}

	func testReplacementDescriptiveLinkRetainsItsSnapshotWhenOutputLooksLikeURL() async throws {
		let webView = try await makeWebView(html: "<div class='articleBody'><a href='https://example.com'>Example website</a></div>")
		try await configure(webView, document: "link-retry", replacement: true)
		let original = try await collect(webView)
		let id = try XCTUnwrap(original.first?.id)
		_ = try await evaluate("window.nnwTranslation.apply('link-retry', translations);", arguments: ["translations": [["id": id, "text": "https://example.com"]]], in: webView)
		let repeated = try await collect(webView)
		XCTAssertEqual(repeated, original)
		_ = try await evaluate("window.nnwTranslation.apply('link-retry', translations);", arguments: ["translations": [["id": id, "text": "Example translated"]]], in: webView)
		let retried = try await evaluate("return document.querySelector('a').textContent;", in: webView) as? String
		XCTAssertEqual(retried, "Example translated")
		_ = try await evaluate("window.nnwTranslation.restore('link-retry');", in: webView)
		let restored = try await evaluate("return document.querySelector('a').textContent;", in: webView) as? String
		XCTAssertEqual(restored, "Example website")
	}

	private func collect(_ webView: WKWebView) async throws -> [Segment] {
		let result = try await evaluate("return window.nnwTranslation.collect();", in: webView)
		return try JSONDecoder().decode([Segment].self, from: Data(try XCTUnwrap(result as? String).utf8))
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

	private func makeWebView(contentJavaScript: Bool = true, recorder: MessageRecorder? = nil, html: String? = nil) async throws -> WKWebView {
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
			webView.loadHTMLString(html ?? Self.html, baseURL: nil)
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

	static let v2exURLArticleContent = """
	我在三年前发了一个提问（ <a href="https://www.v2ex.com/t/1003989">https://www.v2ex.com/t/1003989</a> ），问未来国内安卓系统是否会允许 app 长期在后台运行，那时候大部分机型都不支持，app 在运行一段时间后，特别是在锁屏一段时间后，就被系统杀掉，停止运行了。最近一段时间观察下来，好像真的不杀后台程序了，我的红米 9 都不杀了,这样我几年前创建的 app （ <a href="https://easyalarm.pages.dev/">https://easyalarm.pages.dev</a> ），就有了很好的用户体验。有感兴趣的朋友可以去试试。<p><a href="https://www.v2ex.com/t/1246886">查看原贴</a></p>
	"""

	private static let foldedArticleHTML = """
	<div class="articleBody"><details><summary>查看正文</summary><p>10月6日，有网友发视频称，2026出现一个新词“怨气产品”。视频中指出，当一线基层员工的待遇被压榨到极限时，产品的品质和服务概率会大幅下降，消费者购买到的可能只是一盒包装精美的“怨气盲盒”。</p>
	<p>视频播出后，网友纷纷在弹幕上打出“比亚迪”、“奇瑞”、“东航”等企业名称。</p>
	<p>评论区中多名网民分享了自己在餐饮、工厂及物流等行业工作时的类似见闻：在厨房工作时曾向食物中加入下水道水和地沟油；有人称在工厂或流水线上班时，曾将排泄物或口水弄到产品及罐头里，或者在心情不爽时故意少拧螺丝等。</p></details><p><a href="https://x.com/whyyoutouzhele/status/2107682327098957974">查看原贴</a></p></div>
	"""

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
