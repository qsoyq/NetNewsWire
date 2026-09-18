//
//  ArticleContentCacheRebuilder.swift
//  Account
//
//  Created by qsoyq on 9/19/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import Articles
import RSCore

/// Rebuilds locally cached article HTML for FreshRSS accounts without touching
/// feeds, folders, or favorite-feed bookmarks.
///
/// Only unread and starred article rows are deleted. Read articles keep their
/// cached HTML so a rebuild does not re-download the entire 90-day window.
public struct ArticleContentCacheRebuildSummary: Equatable, Sendable {
	public let accountID: String
	public let accountName: String
	public let unreadCount: Int
	public let starredCount: Int
	public let rebuiltCount: Int
	public let downloadedCount: Int
}

public enum ArticleContentCacheRebuilder {

	/// FreshRSS `stream/items/contents` accepts many `i=` ids. Stay under the
	/// common `max_input_vars=1000` cap while cutting round-trips.
	public static let contentsBatchSize = 400

	/// Dedicated rebuild session uses this many connections per host. Ordinary
	/// refresh stays serial so a rebuild cannot change everyday sync behavior.
	public static let maxConcurrentContentRequests = 4

	public static func supports(_ type: AccountType) -> Bool {
		type == .freshRSS
	}

	public static func articleIDsToRebuild(unreadIDs: Set<String>, starredIDs: Set<String>) -> Set<String> {
		unreadIDs.union(starredIDs)
	}

	public static func contentRequestChunks(articleIDs: [String]) -> [[String]] {
		articleIDs.chunked(into: contentsBatchSize)
	}

	/// Deletes local HTML for unread and starred articles, then downloads that
	/// content again. Statuses, feeds, and folders stay in place.
	@MainActor
	public static func rebuildUnreadAndStarredContent(
		in accounts: [Account],
		progress: (@MainActor (String) -> Void)? = nil
	) async throws -> [ArticleContentCacheRebuildSummary] {
		var summaries = [ArticleContentCacheRebuildSummary]()
		for account in accounts where supports(account.type) && account.isActive {
			let unreadIDs = try await account.fetchUnreadArticleIDsAsync()
			let starredIDs = try await account.fetchStarredArticleIDsAsync()
			let articleIDs = articleIDsToRebuild(unreadIDs: unreadIDs, starredIDs: starredIDs)
			progress?("\(account.nameForDisplay): clearing \(articleIDs.count) cached articles…")
			try await account.delete(articleIDs: articleIDs)
			var downloadedCount = 0
			if !articleIDs.isEmpty {
				downloadedCount = try await account.rebuildArticleContent(articleIDs: articleIDs) { completed, total in
					progress?("\(account.nameForDisplay): downloading batch \(completed)/\(total)…")
				}
			}
			summaries.append(ArticleContentCacheRebuildSummary(
				accountID: account.accountID,
				accountName: account.nameForDisplay,
				unreadCount: unreadIDs.count,
				starredCount: starredIDs.count,
				rebuiltCount: articleIDs.count,
				downloadedCount: downloadedCount
			))
		}
		return summaries
	}
}
