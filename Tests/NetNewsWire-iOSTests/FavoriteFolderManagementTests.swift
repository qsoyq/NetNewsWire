#if os(iOS)
import XCTest
import UIKit
import RSCore
import RSTree
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

	func testFavoriteFolderMatchesOriginalSpacingThroughDisclosureAndReuse() throws {
		let animationsWereEnabled = UIView.areAnimationsEnabled
		UIView.setAnimationsEnabled(false)
		defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
		let fixture = try FavoriteManagementFixture()
		defer { fixture.close() }
		let sceneDelegate = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let scene = try XCTUnwrap(sceneDelegate.window?.windowScene)
		let feeds = try XCTUnwrap(UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "MainFeedCollectionViewController") as? MainFeedCollectionViewController)
		feeds.loadViewIfNeeded()
		let collection = try XCTUnwrap(feeds.collectionView)
		feeds.coordinator = try XCTUnwrap(sceneDelegate.coordinator)
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
		let original = try XCTUnwrap(fixture.account.ensureFolder(with: "Beauty"))
		let originalNode = SidebarItemNode(Node(representedObject: original, parent: nil))
		let favoriteNode = SidebarItemNode(Node(representedObject: fixture.source, parent: nil))
		for width in [375.0, 430.0] {
			collection.frame.size.width = width
			layout.itemSize.width = width
			layout.invalidateLayout()
			collection.layoutIfNeeded()
			for count in [0, 52, 5727, 15271] {
				for expanded in [false, true] {
					func configure(_ node: SidebarItemNode) {
						feeds.configure(cell, sidebarItemNode: node)
						cell.unreadCount = count
						cell.setDisclosure(isExpanded: expanded, animated: false)
						cell.layoutIfNeeded()
					}
					configure(originalNode)
					let originalCountRight = cell.unreadCountLabel.frame.maxX
					let originalDisclosureX = cell.disclosureButton.center.x
					let originalGap = cell.disclosureButton.frame.minX - originalCountRight
					XCTAssertEqual(originalGap, 0, accuracy: 0.5)
					var originalImage: UIImage?
					if width == 430, count == 15271, !expanded {
						originalImage = UIGraphicsImageRenderer(bounds: cell.bounds).image { _ in
							cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true)
						}
					}

					configure(favoriteNode)
					XCTAssertEqual(cell.unreadCountLabel.frame.maxX, originalCountRight, accuracy: 0.5, "Favorite count must align with original folder at width \(width)")
					XCTAssertEqual(cell.disclosureButton.center.x, originalDisclosureX, accuracy: 0.5)
					XCTAssertEqual(cell.disclosureButton.frame.minX - cell.unreadCountLabel.frame.maxX, originalGap, accuracy: 0.5, "Favorite actions must not reserve space between count and disclosure")
					XCTAssertEqual(cell.unreadCountLabel.alpha, expanded || count == 0 ? 0 : 1)
					XCTAssertEqual(cell.accessibilityCustomActions?.count, 2)
					XCTAssertNotNil(cell.manageFeeds)
					if let originalImage {
						let favoriteImage = UIGraphicsImageRenderer(bounds: cell.bounds).image { _ in
							cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true)
						}
						let pair = UIGraphicsImageRenderer(size: CGSize(width: width, height: cell.bounds.height * 2)).image { _ in
							favoriteImage.draw(at: .zero)
							originalImage.draw(at: CGPoint(x: 0, y: cell.bounds.height))
						}
						let attachment = XCTAttachment(image: pair)
						attachment.name = "favorite-vs-original-folder-spacing"
						attachment.lifetime = .keepAlways
						add(attachment)
					}

					configure(originalNode)
					XCTAssertEqual(cell.unreadCountLabel.frame.maxX, originalCountRight, accuracy: 0.5)
					XCTAssertEqual(cell.accessibilityCustomActions?.count, 1)
					XCTAssertNil(cell.manageFeeds)
				}
			}
		}
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
