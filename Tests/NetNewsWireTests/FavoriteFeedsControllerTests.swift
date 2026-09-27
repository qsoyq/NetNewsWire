import XCTest
import RSCore

@testable import Account
@testable import NetNewsWire

@MainActor final class FavoriteFeedsControllerTests: XCTestCase {
	private var accounts = [Account]()
	private var dataFolder: URL!
	private var defaults: UserDefaults!
	private var defaultsSuite: String!
	private var queue: CoalescingQueue!
	private var controller: FavoriteFeedsController!

	override func setUp() async throws {
		try await super.setUp()
		dataFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
		defaultsSuite = "FavoriteFeedsControllerTests.\(UUID().uuidString)"
		defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
		queue = CoalescingQueue(name: "Favorite Tests", interval: 60, maxInterval: 3600)
		accounts = [try makeAccount()]
		controller = FavoriteFeedsController(defaults: defaults, accountsProvider: { [weak self] in
			self?.accounts ?? []
		}, unreadCountQueue: queue)
	}

	override func tearDown() async throws {
		controller = nil
		queue.cancelPendingCalls()
		queue = nil
		for account in accounts {
			account.prepareForDeletion()
			account.deleteSettings()
		}
		accounts.removeAll()
		defaults.removePersistentDomain(forName: defaultsSuite)
		defaults = nil
		try FileManager.default.removeItem(at: dataFolder)
		try await super.tearDown()
	}

	func testUnreadBurstUpdatesOnlyAffectedFoldersAndDeduplicatesTotal() throws {
		let first = makeFeed("first", name: "First", count: 2)
		let second = makeFeed("second", name: "Second", count: 3)
		let other = makeFeed("other", name: "Other", count: 7)
		let sharedFolder = controller.createFolder(named: "Shared")
		let secondFolder = controller.createFolder(named: "Second")
		let untouchedFolder = controller.createFolder(named: "Untouched")
		controller.add(first, to: sharedFolder)
		controller.add(second, to: sharedFolder)
		controller.add(first, to: secondFolder)
		controller.add(other, to: untouchedFolder)
		let alias = try XCTUnwrap(controller.alias(for: first))
		let recorder = FavoriteUnreadRecorder()

		first.unreadCount = 4
		first.unreadCount = 6
		second.unreadCount = 1

		XCTAssertEqual(alias.unreadCount, 6)
		XCTAssertEqual(sharedFolder.unreadCount, 5)
		XCTAssertEqual(controller.allFeed.unreadCount, 12)
		XCTAssertEqual(recorder.count(for: sharedFolder), 0)

		queue.performCallsImmediately()

		XCTAssertEqual(sharedFolder.unreadCount, 7)
		XCTAssertEqual(secondFolder.unreadCount, 6)
		XCTAssertEqual(untouchedFolder.unreadCount, 7)
		XCTAssertEqual(controller.allFeed.unreadCount, 14)
		XCTAssertEqual(recorder.count(for: sharedFolder), 1)
		XCTAssertEqual(recorder.count(for: secondFolder), 1)
		XCTAssertEqual(recorder.count(for: untouchedFolder), 0)
		XCTAssertEqual(recorder.count(for: controller.allFeed), 1)
	}

	func testUnrelatedAndPseudoFeedNotificationsDoNotUpdateFavoriteCounts() throws {
		let favorite = makeFeed("favorite", name: "Favorite", count: 3)
		let unrelated = makeFeed("unrelated", name: "Unrelated", count: 8)
		controller.add(favorite)
		let alias = try XCTUnwrap(controller.alias(for: favorite))
		let recorder = FavoriteUnreadRecorder()

		unrelated.unreadCount = 2
		for source in [alias, controller.ungroupedFolder, controller.allFeed, accounts[0]] as [AnyObject] {
			NotificationCenter.default.post(name: .UnreadCountDidChange, object: source)
		}
		NotificationCenter.default.post(name: .UnreadCountDidChange, object: nil)
		queue.performCallsImmediately()

		XCTAssertEqual(alias.unreadCount, 3)
		XCTAssertEqual(controller.ungroupedFolder.unreadCount, 3)
		XCTAssertEqual(controller.allFeed.unreadCount, 3)
		XCTAssertEqual(recorder.count(for: controller.ungroupedFolder), 1)
		XCTAssertEqual(recorder.count(for: controller.allFeed), 1)
	}

	func testMovingFeedBeforeQueuedUpdateKeepsCountsAndAliasIdentity() throws {
		let feed = makeFeed("feed", name: "Feed", count: 2)
		controller.add(feed)
		let alias = try XCTUnwrap(controller.alias(for: feed))
		let folder = controller.createFolder(named: "Destination")

		feed.unreadCount = 9
		controller.move(alias, to: folder)
		queue.performCallsImmediately()

		XCTAssertTrue(controller.alias(for: feed) === alias)
		XCTAssertEqual(folder.unreadCount, 9)
		XCTAssertEqual(controller.ungroupedFolder.unreadCount, 0)
		XCTAssertEqual(controller.allFeed.unreadCount, 9)
	}

	func testRemovingFeedBeforeQueuedUpdateClearsCountsAndIndex() throws {
		let feed = makeFeed("feed", name: "Feed", count: 2)
		let folder = controller.createFolder(named: "Folder")
		controller.add(feed, to: folder)
		let alias = try XCTUnwrap(controller.alias(for: feed))
		let identifier = try XCTUnwrap(alias.sidebarItemID)

		feed.unreadCount = 9
		controller.remove(feed)
		queue.performCallsImmediately()

		XCTAssertNil(controller.find(by: identifier))
		XCTAssertNil(controller.alias(for: feed))
		XCTAssertEqual(folder.unreadCount, 0)
		XCTAssertEqual(controller.allFeed.unreadCount, 0)
	}

	func testFeedRenameInvalidatesGlobalAndEveryContainingFolderSort() throws {
		let first = makeFeed("first", name: "Alpha", count: 2)
		let second = makeFeed("second", name: "Zulu", count: 3)
		let firstFolder = controller.createFolder(named: "First")
		let secondFolder = controller.createFolder(named: "Second")
		controller.add([first, second], to: firstFolder)
		controller.add([first, second], to: secondFolder)
		let alias = try XCTUnwrap(controller.alias(for: first))
		XCTAssertEqual(controller.aliases.map(\.key.feedID), ["first", "second"])
		XCTAssertEqual(firstFolder.aliases.map(\.key.feedID), ["first", "second"])
		XCTAssertEqual(secondFolder.aliases.map(\.key.feedID), ["first", "second"])

		first.name = "Zzz"

		XCTAssertEqual(controller.aliases.map(\.key.feedID), ["second", "first"])
		XCTAssertEqual(firstFolder.aliases.map(\.key.feedID), ["second", "first"])
		XCTAssertEqual(secondFolder.aliases.map(\.key.feedID), ["second", "first"])
		XCTAssertTrue(controller.find(by: try XCTUnwrap(alias.sidebarItemID)) === alias)
		XCTAssertEqual(controller.allFeed.unreadCount, 5)
	}

	func testFolderRenameAndDeletionInvalidateOrderMembershipAndNodeIndex() throws {
		let feed = makeFeed("feed", name: "Feed", count: 4)
		let first = controller.createFolder(named: "Alpha")
		let second = controller.createFolder(named: "Zulu")
		controller.add(feed, to: first)
		controller.add(feed, to: second)
		let alias = try XCTUnwrap(controller.alias(for: feed))
		let secondID = try XCTUnwrap(second.sidebarItemID)
		XCTAssertTrue(controller.folder(containing: alias) === first)

		controller.rename(second, to: "Aardvark")

		XCTAssertEqual(controller.userFolders.map(\.folderID), [second.folderID, first.folderID])
		XCTAssertEqual(controller.foldersContaining(feed).map(\.folderID), [second.folderID, first.folderID])
		XCTAssertTrue(controller.folder(containing: alias) === second)
		XCTAssertTrue(controller.find(by: secondID) === second)

		controller.deleteFolder(second)

		XCTAssertNil(controller.find(by: secondID))
		XCTAssertTrue(controller.folder(containing: alias) === first)
		XCTAssertEqual(controller.allFeed.unreadCount, 4)
	}

	func testMatchingFeedIDsInDifferentAccountsKeepSeparateAliasesAndCounts() throws {
		accounts.append(try makeAccount())
		let first = makeFeed("same", name: "First", count: 2, account: accounts[0])
		let second = makeFeed("same", name: "Second", count: 3, account: accounts[1])
		controller.add([first, second])
		let firstAlias = try XCTUnwrap(controller.alias(for: first))
		let secondAlias = try XCTUnwrap(controller.alias(for: second))

		second.unreadCount = 8
		queue.performCallsImmediately()

		XCTAssertFalse(firstAlias === secondAlias)
		XCTAssertEqual(firstAlias.unreadCount, 2)
		XCTAssertEqual(secondAlias.unreadCount, 8)
		XCTAssertEqual(controller.ungroupedFolder.unreadCount, 10)
		XCTAssertEqual(controller.allFeed.unreadCount, 10)
		XCTAssertTrue(controller.find(by: try XCTUnwrap(firstAlias.sidebarItemID)) === firstAlias)
		XCTAssertTrue(controller.find(by: try XCTUnwrap(secondAlias.sidebarItemID)) === secondAlias)
	}

	func testReentrantMoveDuringAliasNotificationDoesNotApplyCountTwice() throws {
		let feed = makeFeed("feed", name: "Feed", count: 2)
		controller.add(feed)
		let alias = try XCTUnwrap(controller.alias(for: feed))
		let folder = controller.createFolder(named: "Destination")
		let recorder = FavoriteUnreadRecorder()
		var moved = false
		recorder.onNotification = { [controller] source in
			if source === alias, !moved {
				moved = true
				controller?.move(alias, to: folder)
			}
		}

		feed.unreadCount = 7
		queue.performCallsImmediately()

		XCTAssertTrue(moved)
		XCTAssertEqual(folder.unreadCount, 7)
		XCTAssertEqual(controller.ungroupedFolder.unreadCount, 0)
		XCTAssertEqual(controller.allFeed.unreadCount, 7)
	}

	func testReentrantRemovalDuringFolderNotificationLeavesNoStaleTotal() {
		let feed = makeFeed("feed", name: "Feed", count: 2)
		let folder = controller.createFolder(named: "Folder")
		controller.add(feed, to: folder)
		let recorder = FavoriteUnreadRecorder()
		var removed = false
		recorder.onNotification = { [controller] source in
			if source === folder, !removed {
				removed = true
				controller?.remove(feed)
			}
		}

		feed.unreadCount = 7
		queue.performCallsImmediately()

		XCTAssertTrue(removed)
		XCTAssertEqual(folder.unreadCount, 0)
		XCTAssertEqual(controller.allFeed.unreadCount, 0)
		XCTAssertFalse(controller.hasFavorites)
	}

	func testControllerIsReleasedWithQueuedUnreadUpdate() {
		let feed = makeFeed("feed", name: "Feed", count: 2)
		controller.add(feed)
		feed.unreadCount = 7
		let weakControllers = NSHashTable<FavoriteFeedsController>.weakObjects()
		weakControllers.add(controller)

		controller = nil

		XCTAssertNil(weakControllers.anyObject)
		queue.performCallsImmediately()
	}

	func testSubscriptionRemovalPrunesAliasMembershipAndNodeIndex() throws {
		let removed = makeFeed("removed", name: "Removed", count: 2)
		let kept = makeFeed("kept", name: "Kept", count: 3)
		let folder = controller.createFolder(named: "Folder")
		controller.add([removed, kept], to: folder)
		let aliasID = try XCTUnwrap(controller.alias(for: removed)?.sidebarItemID)
		removed.unreadCount = 7

		accounts[0].removeFeedFromTreeAtTopLevel(removed)
		queue.performCallsImmediately()

		XCTAssertNil(controller.find(by: aliasID))
		XCTAssertFalse(controller.isFavorite(removed))
		XCTAssertEqual(folder.aliases.map(\.key.feedID), ["kept"])
		XCTAssertEqual(folder.unreadCount, 3)
		XCTAssertEqual(controller.allFeed.unreadCount, 3)
	}

	func testReloadRestoresSharedMembershipSortAndIdentifierIndex() throws {
		let feed = makeFeed("feed", name: "Feed", count: 4)
		let first = controller.createFolder(named: "Zulu")
		let second = controller.createFolder(named: "Alpha")
		controller.add(feed, to: first)
		controller.add(feed, to: second)
		let aliasID = try XCTUnwrap(controller.alias(for: feed)?.sidebarItemID)
		let firstID = try XCTUnwrap(first.sidebarItemID)
		let reloaded = FavoriteFeedsController(defaults: defaults, accountsProvider: { [accounts] in accounts }, unreadCountQueue: queue)

		XCTAssertEqual(reloaded.userFolders.map(\.folderID), [second.folderID, first.folderID])
		XCTAssertEqual(reloaded.foldersContaining(feed).count, 2)
		XCTAssertEqual(reloaded.aliases.count, 1)
		XCTAssertEqual(reloaded.allFeed.unreadCount, 4)
		XCTAssertNotNil(reloaded.find(by: aliasID))
		XCTAssertNotNil(reloaded.find(by: firstID))
		XCTAssertTrue(reloaded.userFolders.allSatisfy { $0.unreadCount == 4 })
	}

	private func makeAccount() throws -> Account {
		let id = UUID().uuidString
		let folder = dataFolder.appendingPathComponent(id, isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return Account(dataFolder: folder.path, type: .onMyMac, accountID: id)
	}

	private func makeFeed(_ id: String, name: String, count: Int, account: Account? = nil) -> Feed {
		let account = account ?? accounts[0]
		let feed = account.createFeed(with: name, url: "https://example.com/\(id)", feedID: id, homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		feed.unreadCount = count
		return feed
	}
}

@MainActor private final class FavoriteUnreadRecorder: NSObject {
	private var counts = [ObjectIdentifier: Int]()
	var onNotification: ((AnyObject) -> Void)?

	override init() {
		super.init()
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	func count(for source: AnyObject) -> Int {
		counts[ObjectIdentifier(source)] ?? 0
	}

	@objc private func unreadCountDidChange(_ note: Notification) {
		guard let source = note.object as AnyObject? else { return }
		counts[ObjectIdentifier(source), default: 0] += 1
		onNotification?(source)
	}
}
