import Foundation
import JavaScriptCore
import XCTest

final class ArticleImageNavigationTests: XCTestCase {

	func testSecondImageClickAfterBackNavigationDoesNotOpenViewer() throws {
		let context = try makeContext()
		context.evaluateScript("clickImage(); advanceTo(120); leaveArticle(); advanceTo(125); clickImage(); advanceTo(700);")
		XCTAssertEqual(messageCount(context), 0)
	}

	func testSingleImageClickStillOpensViewerAfterDelay() throws {
		let context = try makeContext()
		context.evaluateScript("clickImage(); advanceTo(279);")
		XCTAssertEqual(messageCount(context), 0)
		context.evaluateScript("advanceTo(280);")
		XCTAssertEqual(messageCount(context), 1)
	}

	func testDoubleImageClickWithoutNavigationStillCancelsViewer() throws {
		let context = try makeContext()
		context.evaluateScript("clickImage(); advanceTo(125); clickImage(); advanceTo(700);")
		XCTAssertEqual(messageCount(context), 0)
	}

	func testReturningToArticleRestoresImageClicks() throws {
		let context = try makeContext()
		context.evaluateScript("leaveArticle(); clickImage(); advanceTo(300);")
		XCTAssertEqual(messageCount(context), 0)
		context.evaluateScript("returnToArticle(); clickImage(); advanceTo(580);")
		XCTAssertEqual(messageCount(context), 1)
	}

	func testLeavingArticleCancelsImageLoadingRetry() throws {
		let context = try makeContext()
		context.evaluateScript("imageLoaded = false; clickImage(); advanceTo(280); leaveArticle(); imageLoaded = true; advanceTo(700);")
		XCTAssertEqual(messageCount(context), 0)
	}

	func testReturningFromViewerRestoresHiddenImageAndAllowsReopening() throws {
		let context = try makeContext()
		context.evaluateScript("clickImage(); advanceTo(280); hideClickedImage(); leaveArticle(); returnToArticle();")
		XCTAssertEqual(context.evaluateScript("testImage.style.opacity")?.toInt32(), 1)
		context.evaluateScript("clickImage(); advanceTo(560);")
		XCTAssertEqual(messageCount(context), 2)
	}

	private func messageCount(_ context: JSContext) -> Int32 {
		context.evaluateScript("imageMessages.length")?.toInt32() ?? -1
	}

	private func makeContext() throws -> JSContext {
		let context = try XCTUnwrap(JSContext())
		context.exceptionHandler = { _, exception in
			XCTFail("JavaScript exception: \(exception?.toString() ?? "unknown")")
		}
		context.evaluateScript(Self.fixture)
		let root = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let source = try String(contentsOf: root.appendingPathComponent("iOS/Resources/main_ios.js"), encoding: .utf8)
		context.evaluateScript(source)
		context.evaluateScript("ImageViewer.prototype.showLoadingIndicator = function() {}; ImageViewer.prototype.hideLoadingIndicator = function() {}; ImageViewer.init();")
		return context
	}

	private static let fixture = """
	var clock = 0, nextTimer = 1, timers = new Map(), imageMessages = [], imageLoaded = true;
	function setTimeout(callback, delay) {
		var id = nextTimer++;
		timers.set(id, {callback: callback, due: clock + delay, interval: 0});
		return id;
	}
	function clearTimeout(id) { timers.delete(id); }
	function setInterval(callback, delay) {
		var id = setTimeout(callback, delay);
		timers.get(id).interval = delay;
		return id;
	}
	function clearInterval(id) { clearTimeout(id); }
	function advanceTo(time) {
		while (true) {
			var entries = Array.from(timers.entries()).sort((a, b) => a[1].due - b[1].due);
			if (!entries.length || entries[0][1].due > time) break;
			var id = entries[0][0], timer = entries[0][1];
			clock = timer.due;
			if (timer.interval) timer.due += timer.interval;
			else timers.delete(id);
			timer.callback();
		}
		clock = time;
	}
	var window = {
		addEventListener: function() {},
		webkit: {messageHandlers: {
			imageWasClicked: {postMessage: function(message) { imageMessages.push(message); }},
			imageWasShown: {postMessage: function() {}}
		}}
	};
	var document = {querySelectorAll: function() { return []; }};
	var testImage = {
		src: "https://example.test/image.jpg", title: "Image", style: {opacity: 1},
		get complete() { return imageLoaded; },
		classList: {contains: function(name) { return name === "nnwLoaded" && imageLoaded; }},
		matches: function(selector) { return selector === "img"; },
		closest: function() { return null; },
		getBoundingClientRect: function() { return {x: 0, y: 0, width: 100, height: 100}; }
	};
	function clickImage() { window.onclick({target: testImage}); }
	function leaveArticle() {
		// The old page-exit path only cleared the timer; it allowed the late second click to rearm it.
		if (typeof suspendImageViewer === "function") suspendImageViewer();
		else cancelImageLoad();
	}
	function returnToArticle() {
		if (typeof resumeImageViewer === "function") resumeImageViewer();
	}
	"""
}
