import Foundation
import Articles

struct TimelineArticleSortKey: Sendable {
	let article: Article
	let date: Date
	let group: String

	init(article: Article, feedName: String) {
		self.article = article
		self.date = article.datePublished ?? article.dateModified ?? article.status.dateArrived
		self.group = "\(feedName.lowercased())-\(article.feedID)"
	}
}

struct TimelinePreparedArticles: Sendable {
	let articles: [Article]
	let identifiers: [TimelineArticleID]
	let articlesByID: [TimelineArticleID: Article]

	static func map(_ articles: [Article]) throws -> TimelinePreparedArticles {
		var identifiers = [TimelineArticleID]()
		var uniqueArticles = [Article]()
		var articlesByID = [TimelineArticleID: Article](minimumCapacity: articles.count)
		identifiers.reserveCapacity(articles.count)
		uniqueArticles.reserveCapacity(articles.count)
		for (index, article) in articles.enumerated() {
			if index.isMultiple(of: 1024) { try Task.checkCancellation() }
			let id = TimelineArticleID(article)
			guard articlesByID[id] == nil else { continue }
			identifiers.append(id)
			uniqueArticles.append(article)
			articlesByID[id] = article
		}
		return TimelinePreparedArticles(articles: uniqueArticles, identifiers: identifiers, articlesByID: articlesByID)
	}

	static func sort(_ keys: [TimelineArticleSortKey], direction: ComparisonResult, groupByFeed: Bool) throws -> TimelinePreparedArticles {
		try Task.checkCancellation()
		var comparisons = 0
		let sorted = try keys.sorted { first, second in
			comparisons += 1
			if comparisons.isMultiple(of: 1024) { try Task.checkCancellation() }
			if groupByFeed && first.group != second.group { return first.group < second.group }
			if first.date != second.date {
				return direction == .orderedDescending ? first.date > second.date : first.date < second.date
			}
			if first.article.articleID != second.article.articleID { return first.article.articleID < second.article.articleID }
			return first.article.accountID < second.article.accountID
		}
		return try map(sorted.map(\.article))
	}
}

struct TimelinePreparationState {
	private(set) var generation = 0

	@discardableResult mutating func invalidate() -> Int {
		generation += 1
		return generation
	}

	func isCurrent(_ generation: Int) -> Bool { self.generation == generation }
}
