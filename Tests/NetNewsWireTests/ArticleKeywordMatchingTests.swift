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

	func testAuthorMatchingIsOptInAndDoesNotReplaceContentMatching() throws {
		let author = try makeAuthor(name: "Jane Doe")
		let item = article(authors: [author])
		XCTAssertFalse(item.containsAnyKeyword(["Jane"]))
		XCTAssertFalse(item.containsAnyKeyword(["Jane"], includesAuthors: false))
		XCTAssertTrue(item.containsAnyKeyword(["Jane"], includesAuthors: true))
		for item in [article(title: "Swift"), article(text: "Swift"), article(html: "<b>Swift</b>"), article(summary: "Swift")] {
			XCTAssertTrue(item.containsAnyKeyword(["Swift"], includesAuthors: true))
		}
	}

	func testAuthorNamesAndRSSCombinedNamesRespectCaseSensitivity() throws {
		let named = try makeAuthor(name: "JOHN DOE")
		let combined = try makeAuthor(email: "john@example.com (JOHN DOE)")
		for author in [named, combined] {
			let item = article(authors: [author])
			XCTAssertFalse(item.containsAnyKeyword(["John Doe"]))
			XCTAssertTrue(item.containsAnyKeyword(["John Doe"], ignoresCase: true, includesAuthors: true))
			XCTAssertFalse(item.containsAnyKeyword(["John Doe"], ignoresCase: false, includesAuthors: true))
			XCTAssertTrue(item.containsAnyKeyword(["JOHN DOE"], ignoresCase: false, includesAuthors: true))
		}
		let chinese = try makeAuthor(name: "中文作者")
		XCTAssertTrue(article(authors: [chinese]).containsAnyKeyword(["作者"], ignoresCase: false, includesAuthors: true))
	}

	func testAuthorMatchingIgnoresBareEmailsURLsAndMissingNames() throws {
		let email = try makeAuthor(email: "john@example.com")
		let url = try makeAuthor(url: "https://example.com/john")
		let empty = try makeAuthor(name: "")
		for authors: Set<Author>? in [nil, [], [email], [url], [empty]] {
			let item = article(authors: authors)
			XCTAssertFalse(item.containsAnyKeyword(["john"], includesAuthors: true))
			XCTAssertFalse(item.containsAnyKeyword([""], includesAuthors: true))
			XCTAssertFalse(item.containsAnyKeyword([], includesAuthors: true))
		}
	}

	func testMultipleAuthorsAreMatchedIndividually() throws {
		let jane = try makeAuthor(name: "Jane")
		let john = try makeAuthor(name: "John")
		let item = article(authors: [jane, john])
		XCTAssertTrue(item.containsAnyKeyword(["Not present", "John"], includesAuthors: true))
		XCTAssertTrue(item.containsAnyKeyword(["Jane"], includesAuthors: true))
		XCTAssertFalse(item.containsAnyKeyword(["Jane John", "John Jane", "Jane, John", "John, Jane", "JaneJohn", "JohnJane"], includesAuthors: true))
	}

	private func makeAuthor(name: String? = nil, email: String? = nil, url: String? = nil) throws -> Author {
		try XCTUnwrap(Author(authorID: nil, name: name, url: url, avatarURL: nil, emailAddress: email))
	}

	private func article(title: String? = nil, html: String? = nil, text: String? = nil, summary: String? = nil, authors: Set<Author>? = nil) -> Article {
		Article(accountID: "account", articleID: "article", feedID: "feed", uniqueID: "article", title: title, contentHTML: html, contentText: text, markdown: nil, url: nil, externalURL: nil, summary: summary, imageURL: nil, datePublished: nil, dateModified: nil, authors: authors, status: ArticleStatus(articleID: "article", read: false, dateArrived: Date()))
	}
}
