//
//  FavoriteFeedsController.swift
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

struct FavoriteFeedKey: Codable, Hashable, Sendable {
	let accountID: String
	let feedID: String

	init(accountID: String, feedID: String) {
		self.accountID = accountID
		self.feedID = feedID
	}

	init(feed: Feed) {
		self.accountID = feed.accountID
		self.feedID = feed.feedID
	}
}

struct BatchFavoriteResult: Sendable, Equatable {
	let addedCount: Int
	let skippedCount: Int
	let failedCount: Int
}

@MainActor final class FavoriteFeedsAllFeed: PseudoFeed {

	var account: Account?

	var defaultReadFilterType: ReadFilterType {
		.none
	}

	var sidebarItemID: SidebarItemIdentifier? {
		SidebarItemIdentifier.smartFeed(String(describing: FavoriteFeedsAllFeed.self))
	}

	let nameForDisplay = NSLocalizedString("All", comment: "All favorite feeds pseudo-feed title")

	var unreadCount = 0 {
		didSet {
			if unreadCount != oldValue {
				postUnreadCountDidChangeNotification()
			}
		}
	}

	var smallIcon: IconImage? {
		Assets.Images.favoriteFeed
	}

#if os(macOS)
	var pasteboardWriter: NSPasteboardWriting {
		SmartFeedPasteboardWriter(smartFeed: self)
	}
#endif
}

extension FavoriteFeedsAllFeed: ArticleFetcher {

	func fetchArticles() throws -> Set<Article> {
		try FavoriteFeedsController.shared.fetchArticles()
	}

	func fetchArticlesAsync() async throws -> Set<Article> {
		try await FavoriteFeedsController.shared.fetchArticlesAsync()
	}

	func fetchUnreadArticles() throws -> Set<Article> {
		try fetchArticles().unreadArticles()
	}

	func fetchUnreadArticlesAsync() async throws -> Set<Article> {
		let articles = try await fetchArticlesAsync()
		return articles.unreadArticles()
	}
}

@MainActor final class FavoriteFeedsController: DisplayNameProvider, ContainerIdentifiable {

	static let shared = FavoriteFeedsController()
	static let sectionID = "__favoriteFeeds"

	nonisolated let containerID: ContainerIdentifier? = ContainerIdentifier.favoriteFeedsController
	let nameForDisplay = NSLocalizedString("Favorites", comment: "Favorites group title")
	let allFeed = FavoriteFeedsAllFeed()
	let ungroupedFolder = FavoriteFeedsFolder.ungrouped()

	private let defaults: UserDefaults
	private let storageKey = "favoriteFeedKeys"
	private let foldersStorageKey = "favoriteFeedFolders"
	private var keys = Set<FavoriteFeedKey>()
	private var folderRecords = [FavoriteFolderRecord]()
	private var aliasesByKey = [FavoriteFeedKey: FavoriteFeedAlias]()
	private var userFoldersByID = [UUID: FavoriteFeedsFolder]()

	var hasFavorites: Bool {
		pruneInvalidKeys()
		return !keys.isEmpty
	}

	var aliases: [FavoriteFeedAlias] {
		rebuildFolders()
		return aliasesByKey.values.sorted {
			$0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending
		}
	}

	var userFolders: [FavoriteFeedsFolder] {
		rebuildFolders()
		return sortedUserFolders()
	}

	var sidebarItems: [SidebarItem] {
		rebuildFolders()
		var items: [SidebarItem] = [allFeed]
		if !ungroupedFolder.aliases.isEmpty {
			items.append(ungroupedFolder)
		}
		items.append(contentsOf: sortedUserFolders())
		return items
	}

	private init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		self.keys = Self.loadKeys(from: defaults, storageKey: storageKey)
		self.folderRecords = Self.loadFolders(from: defaults, storageKey: foldersStorageKey)

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange(_:)), name: .DisplayNameDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(containerChildrenDidChange(_:)), name: .ChildrenDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(userDidDeleteAccount(_:)), name: .UserDidDeleteAccount, object: nil)

		rebuildFolders()
		updateAllUnreadCount()
	}

	func find(by identifier: SidebarItemIdentifier) -> PseudoFeed? {
		rebuildFolders()
		if allFeed.sidebarItemID == identifier {
			return allFeed
		}
		if ungroupedFolder.sidebarItemID == identifier {
			return ungroupedFolder
		}
		if let folder = userFoldersByID.values.first(where: { $0.sidebarItemID == identifier }) {
			return folder
		}
		return aliasesByKey.values.first { $0.sidebarItemID == identifier }
	}

	func folder(containing alias: FavoriteFeedAlias) -> FavoriteFeedsFolder? {
		rebuildFolders()
		if let folder = sortedUserFolders().first(where: { $0.contains(alias) }) {
			return folder
		}
		if ungroupedFolder.contains(alias) {
			return ungroupedFolder
		}
		return nil
	}

	func alias(for feed: Feed) -> FavoriteFeedAlias? {
		rebuildFolders()
		return aliasesByKey[FavoriteFeedKey(feed: feed)]
	}

	func isFavorite(_ feed: Feed) -> Bool {
		keys.contains(FavoriteFeedKey(feed: feed))
	}

	func add(_ feed: Feed, to folder: FavoriteFeedsFolder? = nil) {
		let key = FavoriteFeedKey(feed: feed)
		if keys.insert(key).inserted {
			saveKeys()
		}
		if let folder, folder.isUserFolder {
			add(key, to: folder)
		}
		rebuildFolders()
		updateAllUnreadCount()
		NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
	}

	@discardableResult
	func add(_ feeds: [Feed], to folder: FavoriteFeedsFolder? = nil) -> BatchFavoriteResult {
		var seenKeys = Set<FavoriteFeedKey>()
		var addedCount = 0
		var skippedCount = 0
		var failedCount = 0
		var keysChanged = false
		var foldersChanged = false

		for feed in feeds {
			let key = FavoriteFeedKey(feed: feed)
			guard seenKeys.insert(key).inserted else {
				skippedCount += 1
				continue
			}

			if let folder {
				guard folder.isUserFolder else {
					failedCount += 1
					continue
				}
				if folder.contains(key) {
					skippedCount += 1
					continue
				}

				if keys.insert(key).inserted {
					keysChanged = true
				}
				add(key, to: folder, save: false)
				foldersChanged = true
				addedCount += 1
			} else {
				guard !keys.contains(key) else {
					skippedCount += 1
					continue
				}
				keys.insert(key)
				keysChanged = true
				addedCount += 1
			}
		}

		if keysChanged {
			saveKeys()
		}
		if foldersChanged {
			saveFolders()
		}
		if keysChanged || foldersChanged {
			rebuildFolders()
			updateAllUnreadCount()
			NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
		}

		return BatchFavoriteResult(addedCount: addedCount, skippedCount: skippedCount, failedCount: failedCount)
	}

	func toggle(_ feed: Feed, in folder: FavoriteFeedsFolder) {
		guard folder.isUserFolder else {
			return
		}
		let key = FavoriteFeedKey(feed: feed)
		if folder.contains(feed) || folderRecords.contains(where: { $0.id == folder.userID && $0.feedKeys.contains(key) }) {
			remove(key, from: folder)
		} else {
			if keys.insert(key).inserted {
				saveKeys()
			}
			add(key, to: folder)
		}
		rebuildFolders()
		updateAllUnreadCount()
		NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
	}

	func foldersContaining(_ feed: Feed) -> [FavoriteFeedsFolder] {
		rebuildFolders()
		return foldersContaining(FavoriteFeedKey(feed: feed))
	}

	func foldersContaining(_ alias: FavoriteFeedAlias) -> [FavoriteFeedsFolder] {
		rebuildFolders()
		return foldersContaining(alias.key)
	}

	func remove(_ feed: Feed) {
		remove(FavoriteFeedKey(feed: feed))
	}

	func remove(_ alias: FavoriteFeedAlias) {
		remove(alias.key)
	}

	func toggle(_ feed: Feed) {
		if isFavorite(feed) {
			remove(feed)
		} else {
			add(feed)
		}
	}

	@discardableResult
	func createFolder(named name: String) -> FavoriteFeedsFolder {
		let record = FavoriteFolderRecord(id: UUID(), name: uniqueFolderName(from: name), feedKeys: [])
		folderRecords.append(record)
		saveFolders()
		rebuildFolders()
		NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
		return userFoldersByID[record.id] ?? FavoriteFeedsFolder.user(id: record.id, name: record.name)
	}

	func rename(_ folder: FavoriteFeedsFolder, to name: String) {
		guard let id = folder.userID,
			  let index = folderRecords.firstIndex(where: { $0.id == id }) else {
			return
		}
		folderRecords[index].name = uniqueFolderName(from: name, excluding: id)
		saveFolders()
		rebuildFolders()
		NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
	}

	func deleteFolder(_ folder: FavoriteFeedsFolder) {
		guard let id = folder.userID else {
			return
		}
		folderRecords.removeAll { $0.id == id }
		userFoldersByID[id] = nil
		saveFolders()
		rebuildFolders()
		updateAllUnreadCount()
		NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
	}

	func move(_ alias: FavoriteFeedAlias, to folder: FavoriteFeedsFolder?) {
		if let folder, folder.isUserFolder {
			if keys.insert(alias.key).inserted {
				saveKeys()
			}
			add(alias.key, to: folder)
		} else {
			removeFromAllFolders(alias.key)
		}
		rebuildFolders()
		NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
	}

	func resolvedFeeds() -> [Feed] {
		rebuildFolders()
		return aliases.compactMap { $0.feed }
	}

	func fetchArticles() throws -> Set<Article> {
		var articles = Set<Article>()
		for feed in resolvedFeeds() {
			articles.formUnion(try feed.fetchArticles())
		}
		return articles
	}

	func fetchArticlesAsync() async throws -> Set<Article> {
		var articles = Set<Article>()
		for feed in resolvedFeeds() {
			articles.formUnion(try await feed.fetchArticlesAsync())
		}
		return articles
	}

	@objc func unreadCountDidChange(_ note: Notification) {
		if let feed = note.object as? Feed {
			let key = FavoriteFeedKey(feed: feed)
			aliasesByKey[key]?.syncUnreadCount()
		}
		updateFolderUnreadCounts()
		updateAllUnreadCount()
	}

	@objc func displayNameDidChange(_ note: Notification) {
		guard let feed = note.object as? Feed else {
			return
		}
		let key = FavoriteFeedKey(feed: feed)
		guard let alias = aliasesByKey[key] else {
			return
		}
		alias.postDisplayNameDidChangeNotification()
	}

	@objc func containerChildrenDidChange(_ note: Notification) {
		let oldKeys = keys
		pruneInvalidKeys()
		if oldKeys != keys {
			rebuildFolders()
			updateAllUnreadCount()
			NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
		} else {
			rebuildFolders()
			updateAllUnreadCount()
		}
	}

	@objc func userDidDeleteAccount(_ note: Notification) {
		containerChildrenDidChange(note)
	}
}

private extension FavoriteFeedsController {

	static func loadKeys(from defaults: UserDefaults, storageKey: String) -> Set<FavoriteFeedKey> {
		guard let data = defaults.data(forKey: storageKey) else {
			return Set<FavoriteFeedKey>()
		}
		return (try? JSONDecoder().decode(Set<FavoriteFeedKey>.self, from: data)) ?? Set<FavoriteFeedKey>()
	}

	static func loadFolders(from defaults: UserDefaults, storageKey: String) -> [FavoriteFolderRecord] {
		guard let data = defaults.data(forKey: storageKey) else {
			return [FavoriteFolderRecord]()
		}
		return (try? JSONDecoder().decode([FavoriteFolderRecord].self, from: data)) ?? [FavoriteFolderRecord]()
	}

	func saveKeys() {
		guard let data = try? JSONEncoder().encode(keys) else {
			return
		}
		defaults.set(data, forKey: storageKey)
	}

	func saveFolders() {
		guard let data = try? JSONEncoder().encode(folderRecords) else {
			return
		}
		defaults.set(data, forKey: foldersStorageKey)
	}

	func remove(_ key: FavoriteFeedKey) {
		guard keys.remove(key) != nil else {
			return
		}
		aliasesByKey[key] = nil
		folderRecords = folderRecords.map { record in
			var next = record
			next.feedKeys.remove(key)
			return next
		}
		saveKeys()
		saveFolders()
		rebuildFolders()
		updateAllUnreadCount()
		NotificationCenter.default.post(name: .FavoriteFeedsDidChange, object: self)
	}

	func pruneInvalidKeys() {
		guard !AccountManager.shared.accounts.isEmpty else {
			return
		}

		let validKeys = keys.filter { key in
			guard let account = AccountManager.shared.existingAccount(accountID: key.accountID) else {
				return false
			}
			return account.existingFeed(withFeedID: key.feedID) != nil
		}

		if validKeys != keys {
			keys = validKeys
			saveKeys()
		}

		let prunedFolders = folderRecords.map { record -> FavoriteFolderRecord in
			var next = record
			next.feedKeys = record.feedKeys.filter { keys.contains($0) }
			return next
		}
		if prunedFolders != folderRecords {
			folderRecords = prunedFolders
			saveFolders()
		}
	}

	func rebuildAliases() {
		pruneInvalidKeys()

		var nextAliases = [FavoriteFeedKey: FavoriteFeedAlias]()
		for key in keys {
			let feed = AccountManager.shared.existingAccount(accountID: key.accountID)?.existingFeed(withFeedID: key.feedID)
			if let existing = aliasesByKey[key] {
				existing.syncUnreadCount()
				nextAliases[key] = existing
			} else {
				nextAliases[key] = FavoriteFeedAlias(key: key, feed: feed)
			}
		}
		aliasesByKey = nextAliases
	}

	func rebuildFolders() {
		rebuildAliases()

		var groupedKeys = Set<FavoriteFeedKey>()
		var nextFolders = [UUID: FavoriteFeedsFolder]()
		var normalizedRecords = [FavoriteFolderRecord]()
		for record in folderRecords {
			var normalized = record
			normalized.feedKeys = record.feedKeys.filter { keys.contains($0) }
			groupedKeys.formUnion(normalized.feedKeys)
			normalizedRecords.append(normalized)
			let folderAliases = normalized.feedKeys.compactMap { aliasesByKey[$0] }.sorted {
				$0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending
			}
			if let existing = userFoldersByID[record.id] {
				existing.updateName(normalized.name)
				existing.replaceAliases(folderAliases)
				nextFolders[record.id] = existing
			} else {
				let folder = FavoriteFeedsFolder.user(id: record.id, name: normalized.name)
				folder.replaceAliases(folderAliases)
				nextFolders[record.id] = folder
			}
		}
		userFoldersByID = nextFolders
		if normalizedRecords != folderRecords {
			folderRecords = normalizedRecords
			saveFolders()
		}

		let ungroupedAliases = aliasesByKey.values.filter { !groupedKeys.contains($0.key) }.sorted {
			$0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending
		}
		ungroupedFolder.replaceAliases(ungroupedAliases)
	}

	func add(_ key: FavoriteFeedKey, to folder: FavoriteFeedsFolder, save: Bool = true) {
		guard let id = folder.userID,
			  let index = folderRecords.firstIndex(where: { $0.id == id }) else {
			return
		}
		folderRecords[index].feedKeys.insert(key)
		if save {
			saveFolders()
		}
	}

	func remove(_ key: FavoriteFeedKey, from folder: FavoriteFeedsFolder) {
		guard let id = folder.userID,
			  let index = folderRecords.firstIndex(where: { $0.id == id }) else {
			return
		}
		folderRecords[index].feedKeys.remove(key)
		saveFolders()
	}

	func removeFromAllFolders(_ key: FavoriteFeedKey) {
		folderRecords = folderRecords.map { record in
			var next = record
			next.feedKeys.remove(key)
			return next
		}
		saveFolders()
	}

	func foldersContaining(_ key: FavoriteFeedKey) -> [FavoriteFeedsFolder] {
		sortedUserFolders().filter { $0.contains(key) }
	}

	func sortedUserFolders() -> [FavoriteFeedsFolder] {
		folderRecords.compactMap { userFoldersByID[$0.id] }.sorted {
			$0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending
		}
	}

	func updateFolderUnreadCounts() {
		ungroupedFolder.syncUnreadCount()
		for folder in userFoldersByID.values {
			folder.syncUnreadCount()
		}
	}

	func updateAllUnreadCount() {
		allFeed.unreadCount = aliasesByKey.values.reduce(0) { $0 + $1.unreadCount }
	}

	func uniqueFolderName(from proposed: String, excluding excludedID: UUID? = nil) -> String {
		let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
		let base = trimmed.isEmpty ? NSLocalizedString("New Folder", comment: "Default favorite folder name") : trimmed
		var usedNames = folderRecords.compactMap { record -> String? in
			if record.id == excludedID {
				return nil
			}
			return record.name
		}
		usedNames.append(ungroupedFolder.name)

		if !usedNames.contains(where: { $0.caseInsensitiveCompare(base) == .orderedSame }) {
			return base
		}

		var suffix = 2
		while usedNames.contains(where: { $0.caseInsensitiveCompare("\(base) \(suffix)") == .orderedSame }) {
			suffix += 1
		}
		return "\(base) \(suffix)"
	}
}
