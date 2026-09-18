//
//  FavoriteFeedsFolder.swift
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

struct FavoriteFolderRecord: Codable, Equatable, Sendable {
	var id: UUID
	var name: String
	var feedKeys: Set<FavoriteFeedKey>
}

@MainActor final class FavoriteFeedsFolder: PseudoFeed, ContainerIdentifiable {

	static let ungroupedFolderID = "__ungrouped"

	let folderID: String
	nonisolated let containerID: ContainerIdentifier?

	private(set) var isUserFolder: Bool
	private(set) var name: String
	private(set) var aliases: [FavoriteFeedAlias] = []

	var account: Account? {
		nil
	}

	var defaultReadFilterType: ReadFilterType {
		.none
	}

	var sidebarItemID: SidebarItemIdentifier? {
		SidebarItemIdentifier.smartFeed("FavoriteFeedsFolder.\(folderID)")
	}

	var nameForDisplay: String {
		name
	}

	var unreadCount = 0 {
		didSet {
			if unreadCount != oldValue {
				postUnreadCountDidChangeNotification()
			}
		}
	}

	var smallIcon: IconImage? {
		Assets.Images.mainFolder
	}

	var userID: UUID? {
		guard isUserFolder else {
			return nil
		}
		return UUID(uuidString: folderID)
	}

#if os(macOS)
	var pasteboardWriter: NSPasteboardWriting {
		SmartFeedPasteboardWriter(smartFeed: self)
	}
#endif

	static func ungrouped() -> FavoriteFeedsFolder {
		FavoriteFeedsFolder(
			folderID: ungroupedFolderID,
			name: NSLocalizedString("Feeds", comment: "Default favorite feeds folder title"),
			isUserFolder: false
		)
	}

	static func user(id: UUID, name: String) -> FavoriteFeedsFolder {
		FavoriteFeedsFolder(folderID: id.uuidString, name: name, isUserFolder: true)
	}

	private init(folderID: String, name: String, isUserFolder: Bool) {
		self.folderID = folderID
		self.name = name
		self.isUserFolder = isUserFolder
		self.containerID = ContainerIdentifier.favoriteFeedsFolder(folderID)
	}

	func updateName(_ name: String) {
		guard self.name != name else {
			return
		}
		self.name = name
		postDisplayNameDidChangeNotification()
	}

	func replaceAliases(_ aliases: [FavoriteFeedAlias]) {
		self.aliases = aliases
		syncUnreadCount()
	}

	func syncUnreadCount() {
		unreadCount = aliases.reduce(0) { $0 + $1.unreadCount }
	}

	func contains(_ feed: Feed) -> Bool {
		aliases.contains { $0.key == FavoriteFeedKey(feed: feed) }
	}

	func contains(_ alias: FavoriteFeedAlias) -> Bool {
		aliases.contains { $0.key == alias.key }
	}

	func contains(_ key: FavoriteFeedKey) -> Bool {
		aliases.contains { $0.key == key }
	}
}

extension FavoriteFeedsFolder: ArticleFetcher {

	func fetchArticles() throws -> Set<Article> {
		var articles = Set<Article>()
		for alias in aliases {
			articles.formUnion(try alias.fetchArticles())
		}
		return articles
	}

	func fetchArticlesAsync() async throws -> Set<Article> {
		var articles = Set<Article>()
		for alias in aliases {
			articles.formUnion(try await alias.fetchArticlesAsync())
		}
		return articles
	}

	func fetchUnreadArticles() throws -> Set<Article> {
		try fetchArticles().unreadArticles()
	}

	func fetchUnreadArticlesAsync() async throws -> Set<Article> {
		let articles = try await fetchArticlesAsync()
		return articles.unreadArticles()
	}
}
