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
	private var unsortedAliases: [FavoriteFeedAlias] = []
	private var sortedAliases: [FavoriteFeedAlias]?
	private var aliasKeys = Set<FavoriteFeedKey>()

	var aliases: [FavoriteFeedAlias] {
		if let sortedAliases {
			return sortedAliases
		}
		let sorted = unsortedAliases.sorted {
			$0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending
		}
		sortedAliases = sorted
		return sorted
	}

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

	@discardableResult
	func updateName(_ name: String, notify: Bool = true) -> Bool {
		guard self.name != name else {
			return false
		}
		self.name = name
		if notify {
			postDisplayNameDidChangeNotification()
		}
		return true
	}

	func replaceAliases(_ aliases: [FavoriteFeedAlias], updateUnreadCount: Bool = true) {
		self.unsortedAliases = aliases
		invalidateAliasSort()
		self.aliasKeys = Set(aliases.map(\.key))
		if updateUnreadCount {
			syncUnreadCount()
		}
	}

	func invalidateAliasSort() {
		sortedAliases = nil
	}

	func syncUnreadCount() {
		unreadCount = unsortedAliases.reduce(0) { $0 + $1.unreadCount }
	}

	func contains(_ feed: Feed) -> Bool {
		aliasKeys.contains(FavoriteFeedKey(feed: feed))
	}

	func contains(_ alias: FavoriteFeedAlias) -> Bool {
		aliasKeys.contains(alias.key)
	}

	func contains(_ key: FavoriteFeedKey) -> Bool {
		aliasKeys.contains(key)
	}
}

extension FavoriteFeedsFolder: ArticleFetcher {

	func fetchArticles() throws -> Set<Article> {
		try FavoriteFeedsController.shared.fetchArticles(for: aliases)
	}

	func fetchArticlesAsync() async throws -> Set<Article> {
		try await FavoriteFeedsController.shared.fetchArticlesAsync(for: aliases)
	}

	func fetchUnreadArticles() throws -> Set<Article> {
		try fetchArticles().unreadArticles()
	}

	func fetchUnreadArticlesAsync() async throws -> Set<Article> {
		try await FavoriteFeedsController.shared.fetchUnreadArticlesAsync(for: aliases)
	}
}
