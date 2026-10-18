import Foundation
import Articles
import RSCore
import RSParser

extension Article {
	func containsAnyKeyword(_ keywords: [String], ignoresCase: Bool = true) -> Bool {
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
		return containsKeyword(summary?.strippingHTML().decodingHTMLEntities())
	}
}
