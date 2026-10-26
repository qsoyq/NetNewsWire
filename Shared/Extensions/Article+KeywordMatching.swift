import Foundation
import Articles
import RSCore
import RSParser

extension Article {
	func containsAnyKeyword(_ keywords: [String], ignoresCase: Bool = true, includesAuthors: Bool = false) -> Bool {
		guard !keywords.isEmpty else {
			return false
		}
		let options: String.CompareOptions = ignoresCase ? .caseInsensitive : []
		func containsKeyword(_ text: String?) -> Bool {
			guard let text, !text.isEmpty else {
				return false
			}
			return keywords.contains { !$0.isEmpty && text.range(of: $0, options: options) != nil }
		}

		if containsKeyword(ArticleStringFormatter.sanitizedTitle(title, forHTML: false)?.decodingHTMLEntities()) {
			return true
		}
		if containsKeyword(contentText) {
			return true
		}
		if containsKeyword(contentHTML?.strippingHTML().decodingHTMLEntities()) {
			return true
		}
		if containsKeyword(summary?.strippingHTML().decodingHTMLEntities()) {
			return true
		}
		guard includesAuthors, let authors else {
			return false
		}
		return authors.contains { author in
			if containsKeyword(author.name) {
				return true
			}
			// RSS can store a name and email together, e.g. "john@example.com (John Doe)".
			guard let emailAddress = author.emailAddress, emailAddress.contains(" ") else {
				return false
			}
			return containsKeyword(emailAddress)
		}
	}
}
