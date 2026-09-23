//
//  TimelineRefreshReason.swift
//  NetNewsWire
//

import Articles

struct TimelineArticleID: Hashable, Sendable {
	let accountID: String
	let articleID: String

	init(_ article: Article) {
		self.accountID = article.accountID
		self.articleID = article.articleID
	}

	init(accountID: String, articleID: String) {
		self.accountID = accountID
		self.articleID = articleID
	}
}

struct TimelineArticleMerger {

	static func merge(fetchedArticles: Set<Article>, existingArticles: [Article], canRetainExistingArticle: (Article) -> Bool) -> Set<Article> {
		let fetchedArticleIDs = Set(fetchedArticles.map(TimelineArticleID.init))
		var mergedArticles = fetchedArticles

		for article in existingArticles where !fetchedArticleIDs.contains(TimelineArticleID(article)) && canRetainExistingArticle(article) {
			mergedArticles.insert(article)
		}

		return mergedArticles
	}
}

// Serializes UI commits while retaining only the latest model when interaction defers an update.
struct TimelineSnapshotState {
	private(set) var identifiers = [TimelineArticleID]()
	private(set) var isApplying = false
	private(set) var needsUpdate = false
	private var hasSnapshot = false

	mutating func requestUpdate(isInteracting: Bool) -> Bool {
		needsUpdate = true
		guard !isInteracting, !isApplying else { return false }
		needsUpdate = false
		return true
	}

	func requiresSnapshot(_ identifiers: [TimelineArticleID]) -> Bool {
		!hasSnapshot || self.identifiers != identifiers
	}

	mutating func beginApply(_ identifiers: [TimelineArticleID]) {
		self.identifiers = identifiers
		hasSnapshot = true
		isApplying = true
	}

	mutating func finishApply() {
		isApplying = false
	}
}

enum TimelineRefreshReason: Equatable {
	case foreground
	case feedSelection

	var fetchMode: TimelineFetchMode {
		switch self {
		case .foreground:
			return .merge
		case .feedSelection:
			return .replace
		}
	}

	var emptiesTimelineBeforeFetch: Bool {
		switch self {
		case .foreground:
			return false
		case .feedSelection:
			return true
		}
	}

	var performanceName: String {
		switch self {
		case .foreground:
			return "foreground"
		case .feedSelection:
			return "feed-selection"
		}
	}
}

enum TimelineFetchMode: Equatable {
	case merge
	case replace

	var performanceName: String {
		switch self {
		case .merge:
			return "merge"
		case .replace:
			return "replace"
		}
	}
}
