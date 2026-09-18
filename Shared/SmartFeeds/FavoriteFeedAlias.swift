//
//  FavoriteFeedAlias.swift
//  NetNewsWire
//
//  Created by qsoyq on 9/18/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

#if os(macOS)
import AppKit
#endif
import Foundation
import RSCore
import Articles
import Account

@MainActor final class FavoriteFeedAlias: PseudoFeed {

	let key: FavoriteFeedKey

	var feed: Feed? {
		AccountManager.shared.existingAccount(accountID: key.accountID)?.existingFeed(withFeedID: key.feedID)
	}

	var account: Account? {
		feed?.account
	}

	var defaultReadFilterType: ReadFilterType {
		feed?.defaultReadFilterType ?? .none
	}

	var sidebarItemID: SidebarItemIdentifier? {
		SidebarItemIdentifier.smartFeed("FavoriteFeedAlias.\(key.accountID).\(key.feedID)")
	}

	var nameForDisplay: String {
		feed?.nameForDisplay ?? NSLocalizedString("Untitled", comment: "Untitled favorite feed")
	}

	var unreadCount = 0 {
		didSet {
			if unreadCount != oldValue {
				postUnreadCountDidChangeNotification()
			}
		}
	}

	var smallIcon: IconImage? {
		if let feed {
			return IconImageCache.shared.imageForFeed(feed)
		}
		return Assets.Images.favoriteFeed
	}

#if os(macOS)
	var pasteboardWriter: NSPasteboardWriting {
		SmartFeedPasteboardWriter(smartFeed: self)
	}
#endif

	init(key: FavoriteFeedKey, feed: Feed?) {
		self.key = key
		self.unreadCount = feed?.unreadCount ?? 0
	}

	func syncUnreadCount() {
		unreadCount = feed?.unreadCount ?? 0
	}
}

extension FavoriteFeedAlias: ArticleFetcher {

	func fetchArticles() throws -> Set<Article> {
		try feed?.fetchArticles() ?? Set<Article>()
	}

	func fetchArticlesAsync() async throws -> Set<Article> {
		guard let feed else {
			return Set<Article>()
		}
		return try await feed.fetchArticlesAsync()
	}

	func fetchUnreadArticles() throws -> Set<Article> {
		try feed?.fetchUnreadArticles() ?? Set<Article>()
	}

	func fetchUnreadArticlesAsync() async throws -> Set<Article> {
		guard let feed else {
			return Set<Article>()
		}
		return try await feed.fetchUnreadArticlesAsync()
	}
}
