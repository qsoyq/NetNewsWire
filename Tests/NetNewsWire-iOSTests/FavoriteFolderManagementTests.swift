#if os(iOS)
import XCTest
import UIKit
import RSCore
@testable import Account
@testable import NetNewsWire

@MainActor final class FavoriteFolderManagementTests: XCTestCase {
	func testSelectingFilteredResultsPreservesHiddenSelection() {
		let first = FavoriteFeedKey(accountID: "a", feedID: "one")
		let second = FavoriteFeedKey(accountID: "a", feedID: "two")
		let third = FavoriteFeedKey(accountID: "b", feedID: "two")
		var selection = FavoriteFolderSelection()
		selection.toggle(first)
		selection.toggleAll(in: [second, third])
		XCTAssertEqual(selection.selectedKeys, [first, second, third])
		selection.toggleAll(in: [second, third])
		XCTAssertEqual(selection.selectedKeys, [first])
		selection.toggleAll(in: [])
		XCTAssertEqual(selection.selectedKeys, [first])
		selection.retain([second])
		XCTAssertTrue(selection.selectedKeys.isEmpty)
	}

	func testManagerSearchMoveUndoAndRemovalOnRealUIKitViews() async throws {
		let fixture = try FavoriteManagementFixture()
		defer { fixture.close() }
		let manager = fixture.manager
		let table = manager.tableView
		XCTAssertEqual(table?.numberOfRows(inSection: 0), 3)
		XCTAssertTrue(manager.toolbarItems?.first?.isEnabled == false)

		// Select one row, then all matches for Beta. The hidden selection is kept.
		manager.tableView(manager.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
		let search = try XCTUnwrap(manager.navigationItem.searchController)
		search.searchBar.text = "Beta"
		manager.updateSearchResults(for: search)
		XCTAssertEqual(table?.numberOfRows(inSection: 0), 1)
		try tap(manager.navigationItem.rightBarButtonItem)
		search.searchBar.text = ""
		manager.updateSearchResults(for: search)
		XCTAssertEqual(manager.navigationItem.prompt, String.localizedStringWithFormat(NSLocalizedString("%ld selected", comment: ""), 2))
		try tap(manager.toolbarItems?.first)
		let picker = try XCTUnwrap(fixture.navigation.topViewController as? UITableViewController)
		XCTAssertFalse(picker === manager)
		picker.loadViewIfNeeded()
		XCTAssertEqual(picker.tableView.numberOfRows(inSection: 0), 1)
		XCTAssertTrue(picker.navigationItem.rightBarButtonItem?.isEnabled == false)
		picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
		try tap(picker.navigationItem.rightBarButtonItem)
		try await Task.sleep(for: .milliseconds(500))

		XCTAssertEqual(fixture.source.aliases.count, 1)
		XCTAssertEqual(fixture.destination.aliases.count, 2)
		XCTAssertEqual(manager.tableView.numberOfRows(inSection: 0), 1)
		let undo = try XCTUnwrap(manager.navigationItem.leftBarButtonItems?.last)
		XCTAssertEqual(undo.title, NSLocalizedString("Undo", comment: ""))
		try tap(undo)
		XCTAssertEqual(fixture.source.aliases.count, 3)
		XCTAssertTrue(fixture.destination.aliases.isEmpty)

		try tap(manager.navigationItem.rightBarButtonItem)
		try tap(manager.toolbarItems?.last)
		let confirmation = try XCTUnwrap(manager.presentedViewController as? UIAlertController)
		XCTAssertEqual(confirmation.actions.count, 2)
		// Cancel leaves all memberships and selections intact.
		manager.dismiss(animated: false)
		XCTAssertEqual(fixture.source.aliases.count, 3)
		XCTAssertTrue(manager.toolbarItems?.first?.isEnabled == true)
	}

	func testFolderMenuUsesReservedSpaceAndResetsForReusedCells() throws {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
		let feeds = try XCTUnwrap(UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "MainFeedCollectionViewController") as? MainFeedCollectionViewController)
		feeds.loadViewIfNeeded()
		let collection = try XCTUnwrap(feeds.collectionView)
		let window = UIWindow(windowScene: scene)
		let host = UIViewController()
		window.rootViewController = host
		window.makeKeyAndVisible()
		host.view.addSubview(collection)
		collection.frame = CGRect(x: 0, y: 0, width: 375, height: 600)
		collection.delegate = nil
		defer {
			window.isHidden = true
			window.rootViewController = nil
		}
		let dataSource = FavoriteFolderCellTestDataSource()
		let layout = UICollectionViewFlowLayout()
		layout.itemSize = CGSize(width: 375, height: 60)
		collection.dataSource = dataSource
		collection.setCollectionViewLayout(layout, animated: false)
		collection.reloadData()
		collection.layoutIfNeeded()
		collection.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
		collection.layoutIfNeeded()
		let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? MainFeedCollectionViewFolderCell)
		cell.folderTitle.text = "Post"
		cell.unreadCount = 12345
		cell.setDisclosure(isExpanded: false, animated: false)
		cell.folderMenu = UIMenu(children: [UIAction(title: "Manage Feeds") { _ in }])
		cell.manageFeeds = {}
		cell.layoutIfNeeded()
		let menu = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIButton }.first { $0 !== cell.disclosureButton })
		XCTAssertFalse(menu.isHidden)
		XCTAssertLessThanOrEqual(cell.unreadCountLabel.frame.maxX, menu.frame.minX + 0.5)
		XCTAssertEqual(menu.frame.width, 44)
		XCTAssertEqual(cell.accessibilityCustomActions?.count, 2)
		cell.folderMenu = nil
		cell.manageFeeds = nil
		cell.layoutIfNeeded()
		XCTAssertTrue(menu.isHidden)
		XCTAssertEqual(cell.accessibilityCustomActions?.count, 1)
	}

	func testCompactAndLargeTypeManagementScreens() throws {
		let fixture = try FavoriteManagementFixture()
		defer { fixture.close() }
		let normal = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
			fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
		}
		let normalAttachment = XCTAttachment(image: normal)
		normalAttachment.name = "favorite-management-standard"
		normalAttachment.lifetime = .keepAlways
		add(normalAttachment)
		for width in [375.0, 820.0] {
			fixture.window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
			fixture.navigation.view.frame = fixture.window.bounds
			fixture.manager.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
			fixture.manager.view.setNeedsLayout()
			fixture.window.layoutIfNeeded()
			try tap(fixture.manager.navigationItem.rightBarButtonItem)
			for button in fixture.navigation.toolbar.items ?? [] where button.customView != nil {
				XCTAssertTrue(button.customView?.hasAmbiguousLayout == false)
			}
			let screenshot = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
				fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
			}
			let attachment = XCTAttachment(image: screenshot)
			attachment.name = "favorite-management-large-type-\(Int(width))"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
	}

	private func tap(_ item: UIBarButtonItem?) throws {
		let item = try XCTUnwrap(item)
		let action = try XCTUnwrap(item.action)
		XCTAssertTrue(item.isEnabled)
		XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
	}
}

@MainActor private final class FavoriteFolderCellTestDataSource: NSObject, UICollectionViewDataSource {
	func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 1 }

	func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
		collectionView.dequeueReusableCell(withReuseIdentifier: "Folder", for: indexPath)
	}
}

@MainActor private final class FavoriteManagementFixture {
	let account: Account
	let folderURL: URL
	let suite: String
	let defaults: UserDefaults
	let queue: CoalescingQueue
	let favorites: FavoriteFeedsController
	let source: FavoriteFeedsFolder
	let destination: FavoriteFeedsFolder
	let manager: FavoriteFolderManagementViewController
	let navigation: UINavigationController
	let window: UIWindow

	init() throws {
		folderURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
		suite = "FavoriteManagementTests.\(UUID().uuidString)"
		defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
		account = Account(dataFolder: folderURL.path, type: .onMyMac, accountID: UUID().uuidString)
		queue = CoalescingQueue(name: "Management tests", interval: 60, maxInterval: 3600)
		favorites = FavoriteFeedsController(defaults: defaults, accountsProvider: { [account] in [account] }, unreadCountQueue: queue)
		source = favorites.createFolder(named: "Post")
		destination = favorites.createFolder(named: "Reading")
		for (id, name) in ["Alpha", "Beta", "非常长的中文 Feed 名称，用于检查多行排版和辅助信息"].enumerated() {
			let feed = account.createFeed(with: name, url: "https://example.com/\(id)", feedID: "\(id)", homePageURL: nil)
			account.addFeedToTreeAtTopLevel(feed)
			favorites.add(feed, to: source)
		}
		manager = FavoriteFolderManagementViewController(folder: source, favorites: favorites)
		navigation = UINavigationController(rootViewController: manager)
		if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
			window = UIWindow(windowScene: scene)
		} else {
			window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
		}
		window.rootViewController = navigation
		window.makeKeyAndVisible()
		manager.loadViewIfNeeded()
		window.layoutIfNeeded()
	}

	func close() {
		window.isHidden = true
		window.rootViewController = nil
		queue.cancelPendingCalls()
		account.prepareForDeletion()
		account.deleteSettings()
		defaults.removePersistentDomain(forName: suite)
		try? FileManager.default.removeItem(at: folderURL)
	}
}
#endif
