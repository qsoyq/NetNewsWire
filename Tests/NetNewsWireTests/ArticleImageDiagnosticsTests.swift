//
//  ArticleImageDiagnosticsTests.swift
//  NetNewsWire
//
//  Created by qsoyq on 9/19/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import XCTest
@testable import NetNewsWire

final class ArticleImageDiagnosticsTests: XCTestCase {

	func testExtractsHttpImageSourcesAndSkipsDataAndIconURLs() {
		let html = """
		<img src="https://rssapi.example/api/rss/telegram/media/botmzt/22400/0" alt="">
		<img src='https://cdn5.telesco.pe/file/token.jpg'>
		<img src="data:image/png;base64,abc">
		<img id="nnwImageIcon" src="nnwImageIcon://feed">
		<img src="https://rssapi.example/api/rss/telegram/media/botmzt/22400/0" alt="duplicate">
		"""
		XCTAssertEqual(
			ArticleImageDiagnostics.imageSources(inHTML: html),
			[
				"https://rssapi.example/api/rss/telegram/media/botmzt/22400/0",
				"https://cdn5.telesco.pe/file/token.jpg"
			]
		)
	}

	func testUnwrapsVideoCacheSources() {
		let original = "https://rssapi.example/api/rss/telegram/media/botmzt/22400/1"
		var components = URLComponents()
		components.scheme = VideoCacheSchemeHandler.scheme
		components.host = "cache"
		components.queryItems = [URLQueryItem(name: "url", value: original)]
		let cached = components.string ?? ""
		let html = "<img src=\"\(cached)\">"
		XCTAssertEqual(ArticleImageDiagnostics.imageSources(inHTML: html), [original])
	}

	func testRenderMessageIncludesLoadBaseAndImageCount() {
		let message = ArticleImageDiagnostics.renderMessage(
			articleID: "tag:google.com,2005:reader/item/abc",
			link: "https://t.me/botmzt/22400",
			loadBaseURL: "file:///page.html",
			htmlBaseURL: "https://t.me/botmzt/22400",
			imageSources: ["https://rssapi.example/media/0", "https://rssapi.example/media/1"]
		)
		XCTAssertTrue(message.contains("loadBaseURL=file:///page.html"))
		XCTAssertTrue(message.contains("htmlBaseURL=https://t.me/botmzt/22400"))
		XCTAssertTrue(message.contains("images=2"))
		XCTAssertTrue(message.contains("https://rssapi.example/media/0"))
	}

	func testImageLoadEventTreatsZeroSizeCompleteImageAsFailure() {
		let event = ArticleImageDiagnostics.imageLoadEvent(from: [
			"status": "load",
			"src": "https://rssapi.example/media/0",
			"width": 0,
			"height": 0,
			"complete": true
		])
		XCTAssertEqual(event?.source, "https://rssapi.example/media/0")
		XCTAssertEqual(true, event?.isFailure)
	}

	func testImageLoadEventIgnoresFeedIcon() {
		XCTAssertNil(ArticleImageDiagnostics.imageLoadEvent(from: [
			"status": "error",
			"src": "nnwImageIcon://feed",
			"width": 0,
			"height": 0,
			"complete": true
		]))
	}

	func testImageLoadEventIncludesDocumentURLAndBaseURI() {
		let event = ArticleImageDiagnostics.imageLoadEvent(from: [
			"status": "error",
			"src": "https://rssapi.example/media/0",
			"width": 0,
			"height": 0,
			"complete": true,
			"documentURL": "file:///page.html",
			"baseURI": "https://t.me/botmzt/22400"
		])
		XCTAssertEqual(event?.documentURL, "file:///page.html")
		XCTAssertEqual(event?.baseURI, "https://t.me/botmzt/22400")
		XCTAssertTrue(ArticleImageDiagnostics.imageLoadMessage(event!).contains("https://rssapi.example/media/0"))
		XCTAssertTrue(ArticleImageDiagnostics.imageLoadMessage(event!).contains("baseURI=https://t.me/botmzt/22400"))
	}

	func testLoadSummaryOnlyWhenImagesFail() {
		let success = ArticleImageDiagnostics.ImageLoadEvent(status: "load", source: "https://example/a.jpg", width: 10, height: 10, complete: true)
		let failure = ArticleImageDiagnostics.ImageLoadEvent(status: "error", source: "https://rssapi.example/media/0", width: 0, height: 0, complete: true)
		XCTAssertFalse(ArticleImageDiagnostics.shouldLogLoadSummary(expectedCount: 1, events: [success]))
		XCTAssertTrue(ArticleImageDiagnostics.shouldLogLoadSummary(expectedCount: 1, events: [failure]))
		XCTAssertTrue(ArticleImageDiagnostics.shouldLogLoadSummary(expectedCount: 2, events: []))
		XCTAssertFalse(ArticleImageDiagnostics.shouldLogLoadSummary(expectedCount: 0, events: []))
	}
}
