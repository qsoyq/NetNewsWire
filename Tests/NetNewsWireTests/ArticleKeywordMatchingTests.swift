import XCTest
import Articles
@testable import NetNewsWire

final class ArticleKeywordMatchingTests: XCTestCase {
	func testKeywordsMatchTitlePlainTextAndFullHTMLBody() {
		let keywords = ["Swift", "人工智能", "Tom & Jerry"]
		XCTAssertTrue(article(title: "New SWIFT release").containsAnyKeyword(keywords))
		XCTAssertTrue(article(text: "关于人工智能的新文章").containsAnyKeyword(keywords))
		XCTAssertTrue(article(html: "<p>" + String(repeating: "x", count: 1500) + "<b>Swift</b></p>").containsAnyKeyword(keywords))
		XCTAssertTrue(article(html: "<p>Tom &amp; Jerry</p>").containsAnyKeyword(keywords))
		XCTAssertTrue(article(title: "Tom &amp; Jerry").containsAnyKeyword(keywords))
		XCTAssertTrue(article(title: "<16s in Swift").containsAnyKeyword(keywords))
		XCTAssertTrue(article(summary: "Swift summary").containsAnyKeyword(keywords))
		XCTAssertTrue(article(html: "<p>ordinary</p>", text: "Swift").containsAnyKeyword(keywords))
	}

	func testEmptyAndMarkupOnlyKeywordsDoNotMatch() {
		XCTAssertFalse(article(title: "Anything").containsAnyKeyword([]))
		XCTAssertFalse(article(title: "Anything").containsAnyKeyword([""]))
		XCTAssertFalse(article().containsAnyKeyword(["Swift"]))
		XCTAssertFalse(article(html: #"<img src="https://example.com/Swift.jpg"><script>Swift</script><style>.Swift {}</style><p>Ordinary text</p>"#).containsAnyKeyword(["Swift"]))
	}

	func testCaseSensitivityAppliesToTitleTextHTMLAndSummary() {
		for item in [article(title: "SWIFT"), article(text: "SWIFT"), article(html: "<b>SWIFT</b>"), article(summary: "SWIFT")] {
			XCTAssertTrue(item.containsAnyKeyword(["Swift"], ignoresCase: true))
			XCTAssertFalse(item.containsAnyKeyword(["Swift"], ignoresCase: false))
			XCTAssertTrue(item.containsAnyKeyword(["SWIFT"], ignoresCase: false))
		}
		XCTAssertTrue(article(title: "中文关键词").containsAnyKeyword(["关键词"], ignoresCase: false))
	}

	private func article(title: String? = nil, html: String? = nil, text: String? = nil, summary: String? = nil) -> Article {
		Article(accountID: "account", articleID: "article", feedID: "feed", uniqueID: "article", title: title, contentHTML: html, contentText: text, markdown: nil, url: nil, externalURL: nil, summary: summary, imageURL: nil, datePublished: nil, dateModified: nil, authors: nil, status: ArticleStatus(articleID: "article", read: false, dateArrived: Date()))
	}
}
