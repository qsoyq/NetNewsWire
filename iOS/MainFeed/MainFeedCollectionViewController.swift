//
//  MainFeedCollectionViewController.swift
//  NetNewsWire-iOS
//
//  Created by Stuart Breckenridge on 23/06/2025.
//  Copyright © 2025 Ranchero Software. All rights reserved.
//

import UIKit
import os
import SafariServices
import UniformTypeIdentifiers
import WebKit
import RSCore
import RSTree
import RSWeb
import Account
import Articles

private let reuseIdentifier = "FeedCell"
private let folderIdentifier = "Folder"
private let containerReuseIdentifier = "Container"

final class MainFeedCollectionViewController: UICollectionViewController, UndoableCommandRunner {
	private static let favoriteFoldersMenuIdentifier = UIMenu.Identifier("netnewswire.favorite-folders")
	private static let favoriteFoldersMenuTitle = NSLocalizedString("Add to Folder", comment: "Add to Folder")

	@IBOutlet var filterButton: UIBarButtonItem!
	@IBOutlet var addNewItemButton: UIBarButtonItem! {
		didSet {
			addNewItemButton.target = self
			addNewItemButton.action = #selector(MainFeedCollectionViewController.add(_:))
		}
	}

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MainFeedCollectionViewController")

	private let keyboardManager = KeyboardManager(type: .sidebar)
	override var keyCommands: [UIKeyCommand]? {

		// If the first responder is the WKWebView (PreloadedWebView) we don't want to supply any keyboard
		// commands that the system is looking for by going up the responder chain. They will interfere with
		// the WKWebViews built in hardware keyboard shortcuts, specifically the up and down arrow keys.
		guard let current = UIResponder.currentFirstResponder, !(current is PreloadedWebView) else {
			return nil
		}

		return keyboardManager.keyCommands
	}

	override var canBecomeFirstResponder: Bool {
		return true
	}

	private let refreshProgressView = RefreshProgressView(frame: .zero)

	var undoableCommands = [UndoableCommand]()
	weak var coordinator: SceneCoordinator!

	/// On iPhone, this property is used to prevent the user from selecting a new feed while the current feed is being deselected.
	/// While `isAnimating` is `true`, `shouldSelectItemAt()` will not allow new selection.
	/// The value is set to `true` in `viewWillAppear(_:)` if a feed is selected, and reset to `false` in
	/// `viewDidAppear(_:)` after a delay to allow the deselection animation to complete.
	private var isAnimating: Bool = false
	private var isToolbarConfigured: Bool = false

	var dataSource: UICollectionViewDiffableDataSource<String, SidebarItemNode>!

	override func viewDidLoad() {
		super.viewDidLoad()
		registerForNotifications()
		configureCollectionView()
		configureDiffableDataSource()
		collectionView.dragDelegate = self
		collectionView.dropDelegate = self
		becomeFirstResponder()
    }

	override func viewWillAppear(_ animated: Bool) {
		Self.logger.debug("MainFeedCollectionViewController: viewWillAppear")
		navigationController?.isToolbarHidden = false
		configureToolbarWithProgressView()
		updateUI()
		super.viewWillAppear(animated)

		if traitCollection.userInterfaceIdiom == .phone {
			self.navigationController?.navigationBar.prefersLargeTitles = true
			self.navigationItem.largeTitleDisplayMode = .always
			DispatchQueue.main.async {
				/// This sizes the navigation bar to large.
				self.navigationController?.navigationBar.sizeToFit()
			}

			/// On iPhone, we want to deselect the feed when the user navigates
			/// back to the feeds view. To prevent the user from selecting a new feed while
			/// the current feed is being deselected, set `isAnimating` to true.
			///
			/// `shouldSelectItemAt()` will not allow selection when `isAnimating`
			/// is `true.`
			if collectionView.indexPathsForSelectedItems != nil {
				isAnimating = true
			}
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		self.deselectIfNeccessary()
	}

	func deselectIfNeccessary() {
		guard traitCollection.userInterfaceIdiom == .phone else {
			return
		}

		defer {
			self.isAnimating = false
		}

		// Pro Max may have split view in landscape — give the device some
		// time to change its size class and then decide to deselect
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5043>
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
			// If the iPhone is in portrait, deselect.
			if UIDevice.current.orientation.isPortrait {
				if self.collectionView.indexPathsForSelectedItems != nil {
					self.coordinator.selectSidebarItem(indexPath: nil, animations: [.select])
				}
				return
			}

			// If the iPhone is in landscape, and the horizontal
			// size class is compact, deselect.
			if self.view.window?.traitCollection.horizontalSizeClass == .compact {
				if self.collectionView.indexPathsForSelectedItems != nil { self.coordinator.selectSidebarItem(indexPath: nil, animations: [.select])
				}
				return
			}
		})
	}

	func registerForNotifications() {
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .FaviconDidBecomeAvailable, object: nil)
		// TODO: fix this temporary hack, which will probably require refactoring image handling.
		// We want to know when to possibly reconfigure our cells with a new image, and we don’t
		// always know when an image is available — but watching the .htmlMetadataAvailable Notification
		// lets us know that it’s time to request an image.
		NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .htmlMetadataAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(feedIconDidBecomeAvailable(_:)), name: .feedIconDidBecomeAvailable, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(feedSettingDidChange(_:)), name: .feedSettingDidChange, object: nil)

		registerForTraitChanges([UITraitPreferredContentSizeCategory.self], target: self, action: #selector(preferredContentSizeCategoryDidChange))
	}

	// MARK: - Collection View Configuration
	func configureCollectionView() {
		let standardCellLeadingOffSet = 48.0
		let indentedCellLeadingOffSet = 64.0
		let useSidebarAppearance = traitCollection.userInterfaceIdiom == .pad
		var config = UICollectionLayoutListConfiguration(appearance: useSidebarAppearance ? .sidebar : .insetGrouped)
		config.headerMode = .supplementary

		config.leadingSwipeActionsConfigurationProvider = { [unowned self] indexPath in
			guard self.isAccountSection(indexPath),
				  let feed = self.feed(at: indexPath) else {
				return UISwipeActionsConfiguration(actions: [])
			}
			return UISwipeActionsConfiguration(actions: [self.favoriteSwipeAction(for: feed)])
		}

		config.trailingSwipeActionsConfigurationProvider = { [unowned self] indexPath in
			if self.isSmartFeedsSection(indexPath) {
				return UISwipeActionsConfiguration(actions: [])
			}
			if self.isFavoriteFeedsSection(indexPath) {
				if let alias = self.favoriteAlias(at: indexPath) {
					let config = UISwipeActionsConfiguration(actions: [self.unfavoriteSwipeAction(for: alias)])
					config.performsFirstActionWithFullSwipe = false
					return config
				}
				if let folder = self.favoriteFolder(at: indexPath), folder.isUserFolder {
					let config = UISwipeActionsConfiguration(actions: [self.deleteFavoriteFolderSwipeAction(for: folder)])
					config.performsFirstActionWithFullSwipe = false
					return config
				}
				return UISwipeActionsConfiguration(actions: [])
			}
			var actions = [UIContextualAction]()

			// Set up the delete action
			let deleteTitle = NSLocalizedString("Delete", comment: "Delete")
			let deleteAction = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
				self?.delete(indexPath: indexPath)
				completion(true)
			}
			deleteAction.image = UIImage(systemName: "trash")
			deleteAction.accessibilityLabel = deleteTitle
			deleteAction.backgroundColor = UIColor.systemRed
			actions.append(deleteAction)

			// Set up the rename action
			let renameTitle = NSLocalizedString("Rename", comment: "Rename")
			let renameAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
				self?.rename(indexPath: indexPath)
				completion(true)
			}
			renameAction.backgroundColor = UIColor.systemOrange
			renameAction.image = UIImage(systemName: "pencil")
			renameAction.accessibilityLabel = renameTitle
			actions.append(renameAction)

			if let feed = feed(at: indexPath) {
				let moreTitle = NSLocalizedString("More", comment: "More")
				let moreAction = UIContextualAction(style: .normal, title: nil) { [weak self] (action, view, completion) in

					if let self = self {

						let alert = UIAlertController(title: feed.nameForDisplay, message: nil, preferredStyle: .actionSheet)
						if let popoverController = alert.popoverPresentationController {
							popoverController.sourceView = view
							popoverController.sourceRect = CGRect(x: view.frame.size.width/2, y: view.frame.size.height/2, width: 1, height: 1)
						}

						if let action = self.getInfoAlertAction(indexPath: indexPath, completion: completion) {
							alert.addAction(action)
						}

						if let action = self.homePageAlertAction(indexPath: indexPath, completion: completion) {
							alert.addAction(action)
						}

						if let action = self.copyFeedPageAlertAction(indexPath: indexPath, completion: completion) {
							alert.addAction(action)
						}

						if let action = self.copyHomePageAlertAction(indexPath: indexPath, completion: completion) {
							alert.addAction(action)
						}

						if let action = self.markAllAsReadAlertAction(indexPath: indexPath, completion: completion) {
							alert.addAction(action)
						}

						let cancelTitle = NSLocalizedString("Cancel", comment: "Cancel")
						alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
							completion(true)
						})

						self.present(alert, animated: true)

					}

				}

				moreAction.backgroundColor = UIColor.systemGray
				moreAction.image = UIImage(systemName: "ellipsis")
				moreAction.accessibilityLabel = moreTitle
				actions.append(moreAction)
			}

			let config = UISwipeActionsConfiguration(actions: actions)
			config.performsFirstActionWithFullSwipe = false

			return config
		}

		config.itemSeparatorHandler = { (indexPath, sectionSeparatorConfiguration) in
			var configuration = sectionSeparatorConfiguration

			// Sidebar appearance: no separators
			if useSidebarAppearance {
				configuration.topSeparatorVisibility = .hidden
				configuration.bottomSeparatorVisibility = .hidden
				return configuration
			}

			// insetGrouped appearance: separators with proper insets
			configuration.bottomSeparatorVisibility = .hidden
			configuration.topSeparatorVisibility = indexPath.row == 0 ? .hidden : .visible

			if let cell = self.collectionView.cellForItem(at: indexPath) as? MainFeedCollectionViewCell {
				if cell.indentationLevel == 1 {
					configuration.topSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: indentedCellLeadingOffSet, bottom: 0, trailing: 0)
				} else {
					configuration.topSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: standardCellLeadingOffSet, bottom: 0, trailing: 0)
				}
			}
			if self.collectionView.cellForItem(at: indexPath) is MainFeedCollectionViewFolderCell {
				configuration.topSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: standardCellLeadingOffSet, bottom: 0, trailing: 0)
			}
			return configuration
		}

		let layout = UICollectionViewCompositionalLayout.list(using: config)
		collectionView.setCollectionViewLayout(layout, animated: false)
		collectionView.refreshControl = UIRefreshControl()
		collectionView.refreshControl!.addTarget(self, action: #selector(refreshAccounts(_:)), for: .valueChanged)

		if config.appearance == .sidebar {
			// This defrosts the glass.
			collectionView.backgroundColor = .clear
		}
	}

	func configureDiffableDataSource() {
		dataSource = UICollectionViewDiffableDataSource<String, SidebarItemNode>(
			collectionView: collectionView
		) { [weak self] collectionView, indexPath, sidebarItemNode -> UICollectionViewCell? in
			guard let self else {
				return nil
			}

			if sidebarItemNode.node.representedObject is Folder || sidebarItemNode.node.representedObject is FavoriteFeedsFolder {
				let cell = collectionView.dequeueReusableCell(
					withReuseIdentifier: folderIdentifier,
					for: indexPath
				) as! MainFeedCollectionViewFolderCell
				self.configure(cell, sidebarItemNode: sidebarItemNode)
				cell.delegate = self
				return cell
			} else {
				let cell = collectionView.dequeueReusableCell(
					withReuseIdentifier: reuseIdentifier,
					for: indexPath
				) as! MainFeedCollectionViewCell
				self.configure(cell, sidebarItemNode: sidebarItemNode)
				return cell
			}
		}

		dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
			guard let self else {
				return nil
			}
			guard kind == UICollectionView.elementKindSectionHeader else {
				return UICollectionReusableView()
			}

			let headerView = collectionView.dequeueReusableSupplementaryView(
				ofKind: kind,
				withReuseIdentifier: containerReuseIdentifier,
				for: indexPath
			) as! MainFeedCollectionHeaderReusableView

			headerView.delegate = self

			let sectionID = self.dataSource.snapshot().sectionIdentifiers[indexPath.section]

			// Smart feeds section
			if sectionID.isEmpty {
				headerView.sectionHeaderType = .smartFeeds
				headerView.headerTitle.text = SmartFeedsController.shared.nameForDisplay
				headerView.unreadCount = 0
				headerView.disclosureExpanded = self.coordinator.isExpanded(SmartFeedsController.shared)
				return headerView
			}

			if sectionID == FavoriteFeedsController.sectionID {
				headerView.sectionHeaderType = .favoriteFeeds
				headerView.headerTitle.text = FavoriteFeedsController.shared.nameForDisplay
				headerView.unreadCount = FavoriteFeedsController.shared.allFeed.unreadCount
				headerView.disclosureExpanded = self.coordinator.isExpanded(FavoriteFeedsController.shared)
				headerView.addInteraction(UIContextMenuInteraction(delegate: self))
				return headerView
			}

			// Accounts
			guard let account = AccountManager.shared.existingAccount(accountID: sectionID) else {
				return headerView
			}

			headerView.sectionHeaderType = .account(sectionID)
			headerView.headerTitle.text = account.nameForDisplay
			headerView.unreadCount = account.unreadCount
			headerView.disclosureExpanded = self.coordinator.isExpanded(account)
			headerView.addInteraction(UIContextMenuInteraction(delegate: self))

			return headerView
		}
	}

	func applySnapshot(_ snapshot: NSDiffableDataSourceSnapshot<String, SidebarItemNode>, animatingDifferences: Bool, completion: (() -> Void)? = nil) {
		dataSource.apply(snapshot, animatingDifferences: animatingDifferences) {
			completion?()
		}
	}

	@IBAction func settings(_ sender: UIBarButtonItem) {
		coordinator.showSettings()
	}

    // MARK: UICollectionViewDelegate

	override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		becomeFirstResponder()
		coordinator.selectSidebarItem(indexPath: indexPath, animations: [.navigation, .select, .scroll])
	}

    // MARK: UICollectionViewDelegate

    /*
    // Uncomment this method to specify if the specified item should be highlighted during tracking
    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        return true
    }
    */

    // Uncomment this method to specify if the specified item should be selected
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
		if traitCollection.userInterfaceIdiom == .pad { return true }
		return !isAnimating
    }

	override func collectionView(_ collectionView: UICollectionView, shouldShowMenuForItemAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func collectionView(_ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, performAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) {

    }

	override func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
		coordinator.beginSidebarContextMenu()
	}

	override func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
		if let animator {
			animator.addCompletion { [weak self] in
				self?.coordinator.endSidebarContextMenu()
			}
		} else {
			coordinator.endSidebarContextMenu()
		}
	}

	override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
		guard let sidebarItem = dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? SidebarItem else {
			return nil
		}
		if sidebarItem is FavoriteFeedAlias {
			return makeFavoriteAliasContextMenu(indexPath: indexPath)
		} else if sidebarItem is FavoriteFeedsFolder {
			return makeFavoriteFolderContextMenu(indexPath: indexPath)
		} else if sidebarItem is Feed {
			return makeFeedContextMenu(indexPath: indexPath, includeDeleteRename: true)
		} else if sidebarItem is Folder {
			return makeFolderContextMenu(indexPath: indexPath)
		} else if sidebarItem is PseudoFeed {
			return makePseudoFeedContextMenu(indexPath: indexPath)
		} else {
			return nil
		}
	}

	// MARK: - Key Commands

	// MARK: - Keyboard shortcuts

	@objc func collapseAllExceptForGroupItems(_ sender: Any?) {
		coordinator.collapseAllFolders()
		for case let folderCell as MainFeedCollectionViewFolderCell in collectionView.visibleCells {
			folderCell.disclosureExpanded = false
		}
	}

	@objc func collapseSelectedRows(_ sender: Any?) {
		if let indexPath = coordinator.currentFeedIndexPath, let node = coordinator.nodeFor(indexPath) {
			coordinator.collapse(node)
			if let folder = collectionView.cellForItem(at: indexPath) as? MainFeedCollectionViewFolderCell {
				folder.disclosureExpanded = false
			}
		}
	}

	@objc override func delete(_ sender: Any?) {
		if let indexPath = coordinator.currentFeedIndexPath {
			delete(indexPath: indexPath)
		}
	}

	@objc func expandAll(_ sender: Any?) {
		coordinator.expandAllSectionsAndFolders()
	}

	@objc func expandSelectedRows(_ sender: Any?) {
		if let indexPath = coordinator.currentFeedIndexPath, let node = coordinator.nodeFor(indexPath) {
			coordinator.expand(node)
			if let folder = collectionView.cellForItem(at: indexPath) as? MainFeedCollectionViewFolderCell {
				folder.disclosureExpanded = true
			}
		}
	}

	@objc func markAllAsRead(_ sender: Any) {
		guard let indexPath = collectionView.indexPathsForSelectedItems?.first, let contentView = collectionView.cellForItem(at: indexPath)?.contentView else {
			return
		}

		let title = NSLocalizedString("Mark All as Read", comment: "Mark All as Read")
		MarkAsReadAlertController.confirm(self, coordinator: coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
			self?.coordinator.markAllAsReadInTimeline()
		}
	}

	@objc func navigateToTimeline(_ sender: Any?) {
		coordinator.navigateToTimeline()
	}

	@objc func openInBrowser(_ sender: Any?) {
		coordinator.showBrowserForCurrentFeed()
	}

	@objc func selectNextDown(_ sender: Any?) {
		coordinator.selectNextFeed()
	}

	@objc func selectNextUp(_ sender: Any?) {
		coordinator.selectPrevFeed()
	}

	@objc func showFeedInspector(_ sender: Any?) {
		coordinator.showFeedInspector()
	}

	// MARK: - API

	func focus() {
		becomeFirstResponder()
	}

	func updateUI() {
		if coordinator.isReadFeedsFiltered {
			setFilterButtonToActive()
		} else {
			setFilterButtonToInactive()
		}
		addNewItemButton?.isEnabled = !AccountManager.shared.activeAccounts.isEmpty

		configureContextMenu()
	}

	func updateFeedSelection(animations: Animations) {
		if let indexPath = coordinator.currentFeedIndexPath {
			collectionView.selectItemAndScrollIfNotVisible(at: indexPath, animations: animations)
		} else {
			if let indexPath = collectionView.indexPathsForSelectedItems?.first {
				if animations.contains(.select) {
					collectionView.deselectItem(at: indexPath, animated: true)
				} else {
					collectionView.deselectItem(at: indexPath, animated: false)
				}
			}
		}
	}

	func openInAppBrowser() {
		if let indexPath = coordinator.currentFeedIndexPath,
			let url = coordinator.homePageURLForFeed(indexPath) {
			let vc = SFSafariViewController(url: url)
			vc.modalPresentationStyle = .overFullScreen
			present(vc, animated: true)
		}
	}

	func applyToAvailableCells(_ completion: (MainFeedCollectionViewCell, IndexPath) -> Void) {
		for cell in collectionView.visibleCells {
			guard let indexPath = collectionView.indexPath(for: cell) else {
				continue
			}
			if let cell = collectionView.cellForItem(at: indexPath) as? MainFeedCollectionViewCell {
				completion(cell, indexPath)
			}
		}
	}

	func configureIcon(_ cell: MainFeedCollectionViewCell, sidebarItem: SidebarItem) {
		guard let sidebarItemID = sidebarItem.sidebarItemID else {
			return
		}
		cell.iconImage = IconImageCache.shared.imageFor(sidebarItemID)
	}

	func configureIcon(_ cell: MainFeedCollectionViewFolderCell, sidebarItem: SidebarItem) {
		guard let sidebarItemID = sidebarItem.sidebarItemID else {
			return
		}
		cell.iconImage = IconImageCache.shared.imageFor(sidebarItemID)
	}

	func configureIcon(_ cell: MainFeedCollectionViewCell, _ indexPath: IndexPath) {
		guard let sidebarItemNode = dataSource.itemIdentifier(for: indexPath),
			  let sidebarItem = sidebarItemNode.node.representedObject as? SidebarItem,
			  let sidebarItemID = sidebarItem.sidebarItemID else {
			return
		}
		cell.iconImage = IconImageCache.shared.imageFor(sidebarItemID)
	}

	func configureIcon(_ cell: MainFeedCollectionViewFolderCell, _ indexPath: IndexPath) {
		guard let sidebarItemNode = dataSource.itemIdentifier(for: indexPath),
			  let sidebarItem = sidebarItemNode.node.representedObject as? SidebarItem,
			  let sidebarItemID = sidebarItem.sidebarItemID else {
			return
		}
		cell.iconImage = IconImageCache.shared.imageFor(sidebarItemID)
	}

	func configureCellsForRepresentedObject(_ representedObject: AnyObject) {
//		applyToCellsForRepresentedObject(representedObject, configure)
	}

	func applyToCellsForRepresentedObject(_ representedObject: AnyObject, _ completion: (MainFeedCollectionViewCell, IndexPath) -> Void) {
		applyToAvailableCells { (cell, indexPath) in
			guard let sidebarItemNode = dataSource.itemIdentifier(for: indexPath),
				  let representedSidebarItem = representedObject as? SidebarItem,
				  let candidateSidebarItem = sidebarItemNode.node.representedObject as? SidebarItem,
				  representedSidebarItem.sidebarItemID == candidateSidebarItem.sidebarItemID else {
				return
			}
			completion(cell, indexPath)
		}
	}

	func restoreSelectionIfNecessary(adjustScroll: Bool) {
		if let indexPath = coordinator.mainFeedIndexPathForCurrentTimeline() {
			if adjustScroll {
				collectionView.selectItemAndScrollIfNotVisible(at: indexPath, animations: [])
			} else {
				collectionView.selectItem(at: indexPath, animated: false, scrollPosition: .centeredVertically)
			}
		}
	}

	// MARK: - Private

	func configureToolbarWithProgressView() {
		if #available(iOS 26, *) {
			return
		}

		guard !isToolbarConfigured else {
			return
		}

		// Expect four items: settings, collapse-all, flex space, add.
		let expectedItemCount = 4
		guard var items = toolbarItems, items.count == expectedItemCount else {
			return
		}

		// Replace the middle flex space with: flex, progress, flex
		// to center the progress view between the left and right button groups.
		let middleIndex = 2
		isToolbarConfigured = true
		let refreshBarItem = UIBarButtonItem(customView: refreshProgressView)
		items[middleIndex] = UIBarButtonItem.flexibleSpace()
		items.insert(refreshBarItem, at: middleIndex + 1)
		items.insert(UIBarButtonItem.flexibleSpace(), at: middleIndex + 2)
		toolbarItems = items
	}

	/// Configure feed cell.
	func configure(_ cell: MainFeedCollectionViewCell, sidebarItemNode: SidebarItemNode) {
		let node = sidebarItemNode.node
		var indentationLevel = 0
		if node.parent?.representedObject is Folder || node.parent?.representedObject is FavoriteFeedsFolder {
			indentationLevel = 1
		}

		if let sidebarItem = node.representedObject as? SidebarItem {
			cell.feedTitle.text = sidebarItem.nameForDisplay
			cell.unreadCount = sidebarItem.unreadCount
			cell.indentationLevel = indentationLevel
			configureIcon(cell, sidebarItem: sidebarItem)
		}
	}

	/// Configure folder cell.
	func configure(_ cell: MainFeedCollectionViewFolderCell, sidebarItemNode: SidebarItemNode) {
		let node = sidebarItemNode.node

		if let folder = node.representedObject as? Folder {
			cell.folderTitle.text = folder.nameForDisplay
			cell.unreadCount = folder.unreadCount
			configureIcon(cell, sidebarItem: folder)
		} else if let folder = node.representedObject as? FavoriteFeedsFolder {
			cell.folderTitle.text = folder.nameForDisplay

			cell.unreadCount = folder.unreadCount
			configureIcon(cell, sidebarItem: folder)
		}

		if let containerID = (node.representedObject as? ContainerIdentifiable)?.containerID {
			cell.setDisclosure(isExpanded: coordinator.isExpanded(containerID), animated: false)
		}
	}

	private func findHeaderViewForAccount(_ account: Account) -> MainFeedCollectionHeaderReusableView? {
		guard let sectionIndex = dataSource.snapshot().sectionIdentifiers.firstIndex(of: account.accountID) else {
			return nil
		}
		guard sectionIndex > 0 else { // Skip smart feeds.
			return nil
		}

		return collectionView.supplementaryView(
			forElementKind: UICollectionView.elementKindSectionHeader,
			at: IndexPath(item: 0, section: sectionIndex))
		as? MainFeedCollectionHeaderReusableView
	}

	private func reloadAllVisibleCells() {
		let visibleIndexPaths = collectionView.indexPathsForVisibleItems
		let itemIdentifiers = visibleIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
		reloadCells(itemIdentifiers) { [weak self] in
			self?.restoreSelectionIfNecessary(adjustScroll: false)
		}
	}

	private func reloadCells(_ items: [SidebarItemNode], completion: (() -> Void)? = nil) {
		guard !items.isEmpty else {
			completion?()
			return
		}

		var snapshot = dataSource.snapshot()
		snapshot.reloadItems(items)
		dataSource.apply(snapshot, animatingDifferences: false) {
			completion?()
		}
	}

	func setFilterButtonToActive() {
		filterButton.tintColor = Assets.Colors.primaryAccent
		filterButton?.accLabelText = NSLocalizedString("Selected - Filter Read Feeds", comment: "Selected - Filter Read Feeds")
	}

	func setFilterButtonToInactive() {
		filterButton.tintColor = .label
		filterButton?.accLabelText = NSLocalizedString("Filter Read Feeds", comment: "Filter Read Feeds")
	}

	// MARK: - Notifications

	@objc func preferredContentSizeCategoryDidChange() {
		IconImageCache.shared.emptyCache()
		reloadAllVisibleCells()
	}

	@objc func unreadCountDidChange(_ note: Notification) {
		updateUI()

		guard let unreadCountProvider = note.object as? UnreadCountProvider else {
			return
		}

		if let account = unreadCountProvider as? Account {
			if let headerView = findHeaderViewForAccount(account) {
				headerView.unreadCount = account.unreadCount
			}
			return
		}

		if unreadCountProvider as AnyObject === FavoriteFeedsController.shared.allFeed {
			if let headerView = findHeaderViewForFavoriteFeeds() {
				headerView.unreadCount = FavoriteFeedsController.shared.allFeed.unreadCount
			}
		}

		for cell in collectionView.visibleCells {
			guard let indexPath = collectionView.indexPath(for: cell),
				  let sidebarItemNode = dataSource.itemIdentifier(for: indexPath),
				  sidebarItemNode.node.representedObject === unreadCountProvider as AnyObject else {
				continue
			}
			if let feedCell = cell as? MainFeedCollectionViewCell {
				feedCell.unreadCount = unreadCountProvider.unreadCount
			}
			if let folderCell = cell as? MainFeedCollectionViewFolderCell {
				folderCell.unreadCount = unreadCountProvider.unreadCount
			}
		}
	}

	@objc func feedSettingDidChange(_ note: Notification) {
		guard let feed = note.object as? Feed, let key = note.userInfo?[Feed.SettingUserInfoKey] as? Feed.SettingKey else {
			return
		}
		if key == .homePageURL || key == .faviconURL {
			configureCellsForRepresentedObject(feed)
		}
	}

	@objc func faviconDidBecomeAvailable(_ note: Notification) {
		applyToAvailableCells(configureIcon)
	}

	@objc func feedIconDidBecomeAvailable(_ note: Notification) {
		guard let feed = note.userInfo?[UserInfoKey.feed] as? Feed else {
			return
		}
		applyToAvailableCells { cell, indexPath in
			let representedObject = self.dataSource.itemIdentifier(for: indexPath)?.node.representedObject
			if representedObject as AnyObject === feed {
				self.configureIcon(cell, indexPath)
				return
			}
			if let alias = representedObject as? FavoriteFeedAlias, alias.key == FavoriteFeedKey(feed: feed) {
				self.configureIcon(cell, indexPath)
			}
		}
	}

	// MARK: - Actions

	@objc func configureContextMenu(_: Any? = nil) {
		/*
			Context Menu Order:
			1. Add Feed
			2. Add Folder
		*/

		var menuItems: [UIAction] = []

		let addFeedActionTitle = NSLocalizedString("Add Feed", comment: "Add Feed")
		let addFeedAction = UIAction(title: addFeedActionTitle, image: Assets.Images.plus) { _ in
			self.coordinator.showAddFeed()
		}
		menuItems.append(addFeedAction)

		let addFolderActionTitle = NSLocalizedString("Add Folder", comment: "Add Folder")
		let addFolderAction = UIAction(title: addFolderActionTitle, image: Assets.Images.folderOutlinePlus) { _ in
			self.coordinator.showAddFolder()
		}

		menuItems.append(addFolderAction)

		if FavoriteFeedsController.shared.hasFavorites {
			let addFavoriteFolderTitle = NSLocalizedString("New Favorite Folder", comment: "New Favorite Folder")
			let addFavoriteFolderAction = UIAction(title: addFavoriteFolderTitle, image: Assets.Images.folderOutlinePlus) { _ in
				self.promptForNewFavoriteFolder()
			}
			menuItems.append(addFavoriteFolderAction)
		}

		let contextMenu = UIMenu(title: "", image: nil, identifier: nil, options: [], children: menuItems.reversed())

		self.addNewItemButton.menu = contextMenu
	}

	@objc func refreshAccounts(_ sender: Any) {
		collectionView.refreshControl?.endRefreshing()

		// This is a hack to make sure that an error dialog doesn't interfere with dismissing the refreshControl.
		// If the error dialog appears too closely to the call to endRefreshing, then the refreshControl never disappears.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			appDelegate.manualRefresh(errorHandler: ErrorHandler.present(self))
		}
	}

	@IBAction func add(_ sender: UIBarButtonItem) {
		let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

		let cancelTitle = NSLocalizedString("Cancel", comment: "Cancel")
		let cancelAction = UIAlertAction(title: cancelTitle, style: .cancel)

		let addFeedActionTitle = NSLocalizedString("Add Feed", comment: "Add Feed")
		let addFeedAction = UIAlertAction(title: addFeedActionTitle, style: .default) { _ in
			self.coordinator.showAddFeed()
		}

		alertController.addAction(addFeedAction)

		let anyActiveAccountSupportsFolders: Bool = {
			for account in AccountManager.shared.activeAccounts {
				if !account.behaviors.contains(.disallowFolderManagement) {
					return true
				}
			}
			return false
		}()
		if anyActiveAccountSupportsFolders {
			let addFolderActionTitle = NSLocalizedString("Add Folder", comment: "Add Folder")
			let addFolderAction = UIAlertAction(title: addFolderActionTitle, style: .default) { _ in
				self.coordinator.showAddFolder()
			}
			alertController.addAction(addFolderAction)
		}

		if FavoriteFeedsController.shared.hasFavorites {
			let addFavoriteFolderTitle = NSLocalizedString("New Favorite Folder", comment: "New Favorite Folder")
			let addFavoriteFolderAction = UIAlertAction(title: addFavoriteFolderTitle, style: .default) { _ in
				self.promptForNewFavoriteFolder()
			}
			alertController.addAction(addFavoriteFolderAction)
		}

		alertController.addAction(cancelAction)

		alertController.popoverPresentationController?.barButtonItem = sender

		present(alertController, animated: true)
	}

	@IBAction func toggleFilter(_ sender: Any) {
		coordinator.toggleReadFeedsFilter()
	}

	func toggle(_ headerView: MainFeedCollectionHeaderReusableView) {
		guard let sectionHeaderType = headerView.sectionHeaderType else {
			return
		}

		let containerID: ContainerIdentifier
		switch sectionHeaderType {
		case .smartFeeds:
			guard let id = SmartFeedsController.shared.containerID else {
				return
			}
			containerID = id
		case .favoriteFeeds:
			guard let id = FavoriteFeedsController.shared.containerID else {
				return
			}
			containerID = id
		case .account(let accountID):
			guard let account = AccountManager.shared.existingAccount(accountID: accountID),
				  let id = account.containerID else {
				return
			}
			containerID = id
		}

		if coordinator.isExpanded(containerID) {
			headerView.disclosureExpanded = false
			coordinator.collapse(containerID)
		} else {
			headerView.disclosureExpanded = true
			coordinator.expand(containerID)
		}
	}
}

@MainActor enum BatchFavoriteFeedsMode {
	case addToFavorites
	case addToFolder(FavoriteFeedsFolder)

	var actionTitle: String {
		switch self {
		case .addToFavorites:
			return NSLocalizedString("Add to Favorites", comment: "Batch add to Favorites action")
		case .addToFolder:
			return NSLocalizedString("Add to Folder", comment: "Batch add to favorite folder action")
		}
	}
}

@MainActor final class BatchFavoriteFeedsViewController: UITableViewController {
	private let feeds: [Feed]
	private let mode: BatchFavoriteFeedsMode
	private var selectedKeys = Set<FavoriteFeedKey>()
	private var actionButton: UIBarButtonItem!
	private var selectAllButton: UIBarButtonItem!

	var completion: ((BatchFavoriteResult) -> Void)?

	init(feeds: [Feed], mode: BatchFavoriteFeedsMode) {
		var uniqueFeeds = [FavoriteFeedKey: Feed]()
		for feed in feeds {
			uniqueFeeds[FavoriteFeedKey(feed: feed)] = feed
		}
		self.feeds = uniqueFeeds.values.sorted {
			$0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending
		}
		self.mode = mode
		super.init(style: .insetGrouped)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		title = NSLocalizedString("Select Feeds", comment: "Batch feed selection title")
		tableView.allowsMultipleSelection = false
		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 56

		navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
		selectAllButton = UIBarButtonItem(title: NSLocalizedString("Select All", comment: "Select all batch feeds"), style: .plain, target: self, action: #selector(toggleSelectAll))
		navigationItem.rightBarButtonItem = selectAllButton

		actionButton = UIBarButtonItem(title: mode.actionTitle, style: .done, target: self, action: #selector(applySelection))
		toolbarItems = [UIBarButtonItem.flexibleSpace(), actionButton]
		updateActionState()
		updateEmptyState()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		navigationController?.isToolbarHidden = false
	}

	override func viewWillDisappear(_ animated: Bool) {
		navigationController?.isToolbarHidden = true
		super.viewWillDisappear(animated)
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		feeds.count
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
		let feed = feeds[indexPath.row]
		let key = FavoriteFeedKey(feed: feed)
		let isEligible = isEligible(feed)
		let isSelected = selectedKeys.contains(key)

		cell.textLabel?.text = feed.nameForDisplay
		cell.detailTextLabel?.text = feed.account?.nameForDisplay
		cell.imageView?.image = IconImageCache.shared.imageForFeed(feed)?.image
		cell.imageView?.tintColor = Assets.Colors.secondaryAccent
		cell.accessoryType = isSelected ? .checkmark : .none
		cell.accessoryView = isEligible ? nil : disabledAccessoryView()
		cell.textLabel?.textColor = isEligible ? .label : .secondaryLabel
		cell.detailTextLabel?.textColor = isEligible ? .secondaryLabel : .tertiaryLabel
		cell.selectionStyle = isEligible ? .default : .none
		cell.isUserInteractionEnabled = isEligible

		var accessibilityValue = isEligible ? (isSelected ? NSLocalizedString("Selected", comment: "Selected batch feed") : NSLocalizedString("Not selected", comment: "Not selected batch feed")) : disabledStateText
		if !isEligible {
			accessibilityValue = disabledStateText
		}
		cell.accessibilityLabel = feed.nameForDisplay
		cell.accessibilityValue = accessibilityValue
		cell.accessibilityTraits = isEligible ? (isSelected ? [.button, .selected] : [.button]) : [.staticText]
		return cell
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		let feed = feeds[indexPath.row]
		guard isEligible(feed) else {
			tableView.deselectRow(at: indexPath, animated: false)
			return
		}

		let key = FavoriteFeedKey(feed: feed)
		if selectedKeys.contains(key) {
			selectedKeys.remove(key)
		} else {
			selectedKeys.insert(key)
		}
		tableView.deselectRow(at: indexPath, animated: false)
		tableView.reloadRows(at: [indexPath], with: .none)
		updateActionState()
	}

	@objc private func cancel() {
		dismiss(animated: true)
	}

	@objc private func toggleSelectAll() {
		let eligibleKeys = Set(feeds.filter(isEligible).map { FavoriteFeedKey(feed: $0) })
		if selectedKeys == eligibleKeys {
			selectedKeys.removeAll()
		} else {
			selectedKeys = eligibleKeys
		}
		tableView.reloadData()
		updateActionState()
	}

	@objc private func applySelection() {
		guard !selectedKeys.isEmpty else {
			return
		}

		let selectedFeeds = feeds.filter { selectedKeys.contains(FavoriteFeedKey(feed: $0)) }
		let destination: FavoriteFeedsFolder?
		switch mode {
		case .addToFavorites:
			destination = nil
		case .addToFolder(let folder):
			destination = folder
		}

		let result = FavoriteFeedsController.shared.add(selectedFeeds, to: destination)
		completion?(result)
	}

	private func isEligible(_ feed: Feed) -> Bool {
		switch mode {
		case .addToFavorites:
			return !FavoriteFeedsController.shared.isFavorite(feed)
		case .addToFolder(let folder):
			return !folder.contains(feed)
		}
	}

	private var disabledStateText: String {
		switch mode {
		case .addToFavorites:
			return NSLocalizedString("Already in Favorites", comment: "Already favorited batch feed")
		case .addToFolder:
			return NSLocalizedString("Already in this folder", comment: "Already in target favorite folder")
		}
	}

	private func disabledAccessoryView() -> UIView {
		let imageView = UIImageView(image: UIImage(systemName: "bookmark.fill"))
		imageView.tintColor = .systemOrange
		imageView.accessibilityLabel = disabledStateText
		return imageView
	}

	private func updateActionState() {
		let selectedCount = selectedKeys.count
		actionButton.title = selectedCount == 0 ? mode.actionTitle : "\(mode.actionTitle) (\(selectedCount))"
		actionButton.isEnabled = selectedCount > 0

		let eligibleCount = feeds.filter(isEligible).count
		selectAllButton.title = eligibleCount > 0 && selectedCount == eligibleCount
			? NSLocalizedString("Deselect All", comment: "Deselect all batch feeds")
			: NSLocalizedString("Select All", comment: "Select all batch feeds")
	}

	private func updateEmptyState() {
		guard feeds.isEmpty || feeds.allSatisfy({ !isEligible($0) }) else {
			tableView.backgroundView = nil
			return
		}

		let label = UILabel()
		label.text = feeds.isEmpty
			? NSLocalizedString("No feeds available", comment: "No feeds available for batch operation")
			: NSLocalizedString("All feeds have already been handled", comment: "All feeds already handled for batch operation")
		label.textColor = .secondaryLabel
		label.textAlignment = .center
		label.numberOfLines = 0
		label.adjustsFontForContentSizeCategory = true
		tableView.backgroundView = label
	}
}

extension MainFeedCollectionViewController: MainFeedCollectionHeaderReusableViewDelegate {
	func mainFeedCollectionHeaderReusableViewDidTapDisclosureIndicator(_ view: MainFeedCollectionHeaderReusableView) {
		toggle(view)
	}
}

extension MainFeedCollectionViewController: MainFeedCollectionViewFolderCellDelegate {
	func mainFeedCollectionFolderViewCellDisclosureDidToggle(_ sender: MainFeedCollectionViewFolderCell, expanding: Bool) {
		if expanding {
			expand(sender)
		} else {
			collapse(sender)
		}
	}

	func expand(_ cell: MainFeedCollectionViewFolderCell) {
		guard let indexPath = collectionView.indexPath(for: cell),
			  let node = dataSource.itemIdentifier(for: indexPath)?.node else {
			return
		}
		coordinator.expand(node)
	}

	func collapse(_ cell: MainFeedCollectionViewFolderCell) {
		guard let indexPath = collectionView.indexPath(for: cell),
			  let node = dataSource.itemIdentifier(for: indexPath)?.node else {
			return
		}
		coordinator.collapse(node)
	}
}

extension MainFeedCollectionViewController: UIContextMenuInteractionDelegate {
	func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {

		guard let headerView = interaction.view as? MainFeedCollectionHeaderReusableView else {
			return nil
		}

		if case .favoriteFeeds = headerView.sectionHeaderType {
			return UIContextMenuConfiguration(identifier: FavoriteFeedsController.sectionID as NSCopying, previewProvider: nil) { _ in
				let newFolderTitle = NSLocalizedString("New Folder", comment: "New Folder")
				let newFolderAction = UIAction(title: newFolderTitle, image: Assets.Images.folderOutlinePlus) { _ in
					self.promptForNewFavoriteFolder()
				}
				return UIMenu(title: "", children: [newFolderAction])
			}
		}

		guard case .account(let accountID) = headerView.sectionHeaderType,
			  let account = AccountManager.shared.existingAccount(accountID: accountID) else {
			return nil
		}

		return UIContextMenuConfiguration(identifier: accountID as NSCopying, previewProvider: nil) { _ in

			var menuElements = [UIMenuElement]()
			menuElements.append(UIMenu(title: "", options: .displayInline, children: [self.getAccountInfoAction(account: account)]))

			if let markAllAction = self.markAllAsReadAction(account: account, contentView: interaction.view) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [markAllAction]))
			}

			menuElements.append(UIMenu(title: "", options: .displayInline, children: [self.deactivateAccountAction(account: account)]))

			return UIMenu(title: "", children: menuElements)
		}
	}

	func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {

		guard let accountID = configuration.identifier as? String,
			  let sectionIndex = dataSource.snapshot().sectionIdentifiers.firstIndex(of: accountID),
			  let cell = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: sectionIndex)) as? MainFeedCollectionHeaderReusableView else {
			return nil
		}
		return UITargetedPreview(view: cell, parameters: CroppingPreviewParameters(view: cell))
	}
}

extension MainFeedCollectionViewController {
	func makeFeedContextMenu(indexPath: IndexPath, includeDeleteRename: Bool) -> UIContextMenuConfiguration {
		return UIContextMenuConfiguration(identifier: MainFeedRowIdentifier(indexPath: indexPath), previewProvider: nil, actionProvider: { [ weak self] _ in

			guard let self = self else {
				return nil
			}

			var menuElements = [UIMenuElement]()

			if let inspectorAction = self.getInfoAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [inspectorAction]))
			}

			if let favoriteAction = self.favoriteMenuAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [favoriteAction]))
			}

			if let folderMenu = self.favoriteFoldersMenu(indexPath: indexPath) {
				menuElements.append(folderMenu)
			}

			if let homePageAction = self.homePageAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [homePageAction]))
			}

			var pageActions = [UIAction]()
			if let copyFeedPageAction = self.copyFeedPageAction(indexPath: indexPath) {
				pageActions.append(copyFeedPageAction)
			}
			if let copyHomePageAction = self.copyHomePageAction(indexPath: indexPath) {
				pageActions.append(copyHomePageAction)
			}
			if !pageActions.isEmpty {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: pageActions))
			}

			if let markAllAction = self.markAllAsReadAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [markAllAction]))
			}

			if includeDeleteRename {
				menuElements.append(UIMenu(title: "",
										   options: .displayInline,
										   children: [
											self.renameAction(indexPath: indexPath),
											self.deleteAction(indexPath: indexPath)
										   ]))
			}

			return UIMenu(title: "", children: menuElements)
		})
	}

	func makeFolderContextMenu(indexPath: IndexPath) -> UIContextMenuConfiguration {
		return UIContextMenuConfiguration(identifier: MainFeedRowIdentifier(indexPath: indexPath), previewProvider: nil, actionProvider: { [weak self] _ in

			guard let self = self else {
				return nil
			}

			var menuElements = [UIMenuElement]()

			if let folder = self.dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? Folder {
				let title = NSLocalizedString("Batch Add to Favorites", comment: "Batch add feeds to Favorites")
				let action = UIAction(title: title, image: UIImage(systemName: "bookmark.fill")) { [weak self] _ in
					self?.presentBatchFavoriteSelection(for: folder)
				}
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [action]))
			}

			if let markAllAction = self.markAllAsReadAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [markAllAction]))
			}

			menuElements.append(UIMenu(title: "",
									   options: .displayInline,
									   children: [
										self.renameAction(indexPath: indexPath),
										self.deleteAction(indexPath: indexPath)
									   ]))

			return UIMenu(title: "", children: menuElements)

		})
	}

	func makePseudoFeedContextMenu(indexPath: IndexPath) -> UIContextMenuConfiguration? {
		guard let markAllAction = self.markAllAsReadAction(indexPath: indexPath) else {
			return nil
		}

		return UIContextMenuConfiguration(identifier: MainFeedRowIdentifier(indexPath: indexPath), previewProvider: nil, actionProvider: { _ in
			return UIMenu(title: "", children: [markAllAction])
		})
	}

	func makeFavoriteFolderContextMenu(indexPath: IndexPath) -> UIContextMenuConfiguration {
		return UIContextMenuConfiguration(identifier: MainFeedRowIdentifier(indexPath: indexPath), previewProvider: nil, actionProvider: { [weak self] _ in
			guard let self,
				  let folder = self.favoriteFolder(at: indexPath) else {
				return nil
			}

			var menuElements = [UIMenuElement]()

			if let markAllAction = self.markAllAsReadAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [markAllAction]))
			}

				if folder.isUserFolder {
					menuElements.append(UIMenu(title: "",
										   options: .displayInline,
										   children: [
											self.renameAction(indexPath: indexPath),
											self.deleteFavoriteFolderAction(folder: folder)
												]))
				} else {
					let batchTitle = NSLocalizedString("Batch Add to Favorite Folder", comment: "Batch add favorite feeds to a folder")
					let batchAction = UIAction(title: batchTitle, image: Assets.Images.folderOutlinePlus) { [weak self] _ in
						self?.presentFavoriteFolderPicker(sourceFolder: folder)
					}
					menuElements.append(UIMenu(title: "", options: .displayInline, children: [batchAction]))

					let newFolderTitle = NSLocalizedString("New Folder", comment: "New Folder")
					let newFolderAction = UIAction(title: newFolderTitle, image: Assets.Images.folderOutlinePlus) { _ in
					self.promptForNewFavoriteFolder()
				}
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [newFolderAction]))
			}

			return UIMenu(title: "", children: menuElements)
		})
	}

	func makeFavoriteAliasContextMenu(indexPath: IndexPath) -> UIContextMenuConfiguration {
		return UIContextMenuConfiguration(identifier: MainFeedRowIdentifier(indexPath: indexPath), previewProvider: nil, actionProvider: { [weak self] _ in
			guard let self else {
				return nil
			}

			var menuElements = [UIMenuElement]()

			if let inspectorAction = self.getInfoAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [inspectorAction]))
			}

			if let favoriteAction = self.favoriteMenuAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [favoriteAction]))
			}

			if let homePageAction = self.homePageAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [homePageAction]))
			}

			var pageActions = [UIAction]()
			if let copyFeedPageAction = self.copyFeedPageAction(indexPath: indexPath) {
				pageActions.append(copyFeedPageAction)
			}
			if let copyHomePageAction = self.copyHomePageAction(indexPath: indexPath) {
				pageActions.append(copyHomePageAction)
			}
			if !pageActions.isEmpty {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: pageActions))
			}

			if let markAllAction = self.markAllAsReadAction(indexPath: indexPath) {
				menuElements.append(UIMenu(title: "", options: .displayInline, children: [markAllAction]))
			}

			if let folderMenu = self.favoriteFoldersMenu(indexPath: indexPath) {
				menuElements.append(folderMenu)
			}

			menuElements.append(UIMenu(title: "", options: .displayInline, children: [self.renameAction(indexPath: indexPath)]))

			return UIMenu(title: "", children: menuElements)
		})
	}

	func homePageAction(indexPath: IndexPath) -> UIAction? {
		guard let feed = feed(at: indexPath),
			  let homePageURL = feed.homePageURL,
			  let url = URL(string: homePageURL) else {
			return nil
		}

		let title = NSLocalizedString("Open Home Page", comment: "Open Home Page")
		let action = UIAction(title: title, image: Assets.Images.safari) { _ in
			UIApplication.shared.open(url, options: [:])
		}
		return action
	}

	func homePageAlertAction(indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let feed = feed(at: indexPath),
			  let homePageURL = feed.homePageURL,
			  let url = URL(string: homePageURL) else {
			return nil
		}

		let title = NSLocalizedString("Open Home Page", comment: "Open Home Page")
		let action = UIAlertAction(title: title, style: .default) { _ in
			UIApplication.shared.open(url, options: [:])
			completion(true)
		}
		return action
	}

	func copyFeedPageAction(indexPath: IndexPath) -> UIAction? {
		guard let feed = feed(at: indexPath),
			  let url = URL(string: feed.url) else {
				  return nil
			  }

		let title = NSLocalizedString("Copy Feed URL", comment: "Copy Feed URL")
		let action = UIAction(title: title, image: Assets.Images.copy) { _ in
			UIPasteboard.general.url = url
		}
		return action
	}

	func copyFeedPageAlertAction(indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let feed = feed(at: indexPath),
			  let url = URL(string: feed.url) else {
				  return nil
			  }

		let title = NSLocalizedString("Copy Feed URL", comment: "Copy Feed URL")
		let action = UIAlertAction(title: title, style: .default) { _ in
			UIPasteboard.general.url = url
			completion(true)
		}
		return action
	}

	func copyHomePageAction(indexPath: IndexPath) -> UIAction? {
		guard let feed = feed(at: indexPath),
			  let homePageURL = feed.homePageURL,
			  let url = URL(string: homePageURL) else {
				  return nil
			  }

		let title = NSLocalizedString("Copy Home Page URL", comment: "Copy Home Page URL")
		let action = UIAction(title: title, image: Assets.Images.copy) { _ in
			UIPasteboard.general.url = url
		}
		return action
	}

	func copyHomePageAlertAction(indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let feed = feed(at: indexPath),
			  let homePageURL = feed.homePageURL,
			  let url = URL(string: homePageURL) else {
				  return nil
			  }

		let title = NSLocalizedString("Copy Home Page URL", comment: "Copy Home Page URL")
		let action = UIAlertAction(title: title, style: .default) { _ in
			UIPasteboard.general.url = url
			completion(true)
		}
		return action
	}

	func markAllAsReadAlertAction(indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let feed = feed(at: indexPath),
			feed.unreadCount > 0,
			let articles = try? feed.fetchArticles(), let contentView = self.collectionView.cellForItem(at: indexPath)?.contentView else {
				return nil
		}

		let localizedMenuText = NSLocalizedString("Mark All as Read in “%@”", comment: "Command")
		let title = NSString.localizedStringWithFormat(localizedMenuText as NSString, feed.nameForDisplay) as String
		let cancel = {
			completion(true)
		}

		let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView, cancelCompletion: cancel) { [weak self] in
				self?.coordinator.markAllAsRead(Array(articles))
				completion(true)
			}
		}
		return action
	}

	func deleteAction(indexPath: IndexPath) -> UIAction {
		let title = NSLocalizedString("Delete", comment: "Delete")

		let action = UIAction(title: title, image: Assets.Images.trash, attributes: .destructive) { [weak self] _ in
			self?.delete(indexPath: indexPath)
		}
		return action
	}

	func renameAction(indexPath: IndexPath) -> UIAction {
		let title = NSLocalizedString("Rename", comment: "Rename")
		let action = UIAction(title: title, image: Assets.Images.edit) { [weak self] _ in
			self?.rename(indexPath: indexPath)
		}
		return action
	}

	func getInfoAction(indexPath: IndexPath) -> UIAction? {
		guard let feed = feed(at: indexPath) else {
			return nil
		}

		let title = NSLocalizedString("Get Info", comment: "Get Info")
		let action = UIAction(title: title, image: Assets.Images.info) { [weak self] _ in
			self?.coordinator.showFeedInspector(for: feed)
		}
		return action
	}

	func favoriteMenuAction(indexPath: IndexPath) -> UIAction? {
		guard let feed = feed(at: indexPath) else {
			return nil
		}

		let isFavorite = FavoriteFeedsController.shared.isFavorite(feed)
		let title = isFavorite ?
			NSLocalizedString("Remove from Favorites", comment: "Remove from Favorites") :
			NSLocalizedString("Add to Favorites", comment: "Add to Favorites")
		let image = UIImage(systemName: isFavorite ? "bookmark.slash" : "bookmark.fill")
		return UIAction(title: title, image: image) { [weak self] _ in
			self?.coordinator.toggleFavorite(for: feed)
		}
	}

	func getAccountInfoAction(account: Account) -> UIAction {
		let title = NSLocalizedString("Get Info", comment: "Get Info")
		let action = UIAction(title: title, image: Assets.Images.info) { [weak self] _ in
			self?.coordinator.showAccountInspector(for: account)
		}
		return action
	}

	func deactivateAccountAction(account: Account) -> UIAction {
		let title = NSLocalizedString("Deactivate", comment: "Deactivate")
		let action = UIAction(title: title, image: Assets.Images.deactivate) { _ in
			account.isActive = false
		}
		return action
	}

	func getInfoAlertAction(indexPath: IndexPath, completion: @escaping (Bool) -> Void) -> UIAlertAction? {
		guard let feed = feed(at: indexPath) else {
			return nil
		}

		let title = NSLocalizedString("Get Info", comment: "Get Info")
		let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
			self?.coordinator.showFeedInspector(for: feed)
			completion(true)
		}
		return action
	}

	func markAllAsReadAction(indexPath: IndexPath) -> UIAction? {
		guard let sidebarItem = dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? SidebarItem,
			  let contentView = self.collectionView.cellForItem(at: indexPath)?.contentView,
			  sidebarItem.unreadCount > 0 else {
				  return nil
			  }

		let localizedMenuText = NSLocalizedString("Mark All as Read in “%@”", comment: "Command")
		let title = NSString.localizedStringWithFormat(localizedMenuText as NSString, sidebarItem.nameForDisplay) as String
		let action = UIAction(title: title, image: Assets.Images.markAllAsRead) { [weak self] _ in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
				if let articles = try? sidebarItem.fetchUnreadArticles() {
					self?.coordinator.markAllAsRead(Array(articles))
				}
			}
		}

		return action
	}

	func markAllAsReadAction(account: Account, contentView: UIView?) -> UIAction? {
		guard account.unreadCount > 0, let contentView else {
			return nil
		}

		let localizedMenuText = NSLocalizedString("Mark All as Read in “%@”", comment: "Command")
		let title = NSString.localizedStringWithFormat(localizedMenuText as NSString, account.nameForDisplay) as String
		let action = UIAction(title: title, image: Assets.Images.markAllAsRead) { [weak self] _ in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
				// If you don't have this delay the screen flashes when it executes this code
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
					if let articles = try? account.fetchArticles(.unread()) {
						self?.coordinator.markAllAsRead(Array(articles))
					}
				}
			}
		}

		return action
	}

	func rename(indexPath: IndexPath) {
		guard let sidebarItem = dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? SidebarItem else {
			return
		}

		let formatString = NSLocalizedString("Rename “%@”", comment: "Rename feed")
		let title = NSString.localizedStringWithFormat(formatString as NSString, sidebarItem.nameForDisplay) as String

		let alertController = UIAlertController(title: title, message: nil, preferredStyle: .alert)

		let cancelTitle = NSLocalizedString("Cancel", comment: "Cancel")
		alertController.addAction(UIAlertAction(title: cancelTitle, style: .cancel))

		let renameTitle = NSLocalizedString("Rename", comment: "Rename")
		let renameAction = UIAlertAction(title: renameTitle, style: .default) { [weak self] _ in

			guard let name = alertController.textFields?[0].text, !name.isEmpty else {
				return
			}

			if let feed = sidebarItem as? Feed {
				feed.rename(to: name) { result in
					switch result {
					case .success:
						break
					case .failure(let error):
						self?.presentError(error)
					}
				}
			} else if let alias = sidebarItem as? FavoriteFeedAlias, let feed = alias.feed {
				feed.rename(to: name) { result in
					switch result {
					case .success:
						break
					case .failure(let error):
						self?.presentError(error)
					}
				}
			} else if let folder = sidebarItem as? Folder {
				folder.rename(to: name) { result in
					switch result {
					case .success:
						break
					case .failure(let error):
						self?.presentError(error)
					}
				}
			} else if let folder = sidebarItem as? FavoriteFeedsFolder {
				self?.coordinator.renameFavoriteFolder(folder, to: name)
			}

		}

		alertController.addAction(renameAction)
		alertController.preferredAction = renameAction

		alertController.addTextField { textField in
			textField.text = sidebarItem.nameForDisplay
			textField.placeholder = NSLocalizedString("Name", comment: "Name")
			textField.clearButtonMode = .always
		}

		self.present(alertController, animated: true) {

		}

	}

	func delete(indexPath: IndexPath) {
		if let alias = favoriteAlias(at: indexPath) {
			coordinator.unfavorite(alias)
			return
		}
		if let folder = favoriteFolder(at: indexPath), folder.isUserFolder {
			confirmDeleteFavoriteFolder(folder)
			return
		}

		guard let sidebarItem = dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? SidebarItem else {
			return
		}

		let title: String
		let message: String
		if sidebarItem is Folder {
			title = NSLocalizedString("Delete Folder", comment: "Delete folder")
			let localizedInformativeText = NSLocalizedString("Are you sure you want to delete the “%@” folder?", comment: "Folder delete text")
			message = NSString.localizedStringWithFormat(localizedInformativeText as NSString, sidebarItem.nameForDisplay) as String
		} else {
			title = NSLocalizedString("Delete Feed", comment: "Delete feed")
			let localizedInformativeText = NSLocalizedString("Are you sure you want to delete the “%@” feed?", comment: "Feed delete text")
			message = NSString.localizedStringWithFormat(localizedInformativeText as NSString, sidebarItem.nameForDisplay) as String
		}

		let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

		let cancelTitle = NSLocalizedString("Cancel", comment: "Cancel")
		alertController.addAction(UIAlertAction(title: cancelTitle, style: .cancel))

		let deleteTitle = NSLocalizedString("Delete", comment: "Delete")
		let deleteAction = UIAlertAction(title: deleteTitle, style: .destructive) { [weak self] _ in
			self?.performDelete(indexPath: indexPath)
		}
		alertController.addAction(deleteAction)
		alertController.preferredAction = deleteAction

		self.present(alertController, animated: true)
	}

	func performDelete(indexPath: IndexPath) {
		guard let undoManager = undoManager,
			  let deleteNode = dataSource.itemIdentifier(for: indexPath)?.node,
			  let deleteCommand = DeleteCommand(nodesToDelete: [deleteNode], undoManager: undoManager, errorHandler: ErrorHandler.present(self)) else {
			return
		}

		if let folder = deleteNode.representedObject as? Folder {
			ActivityManager.cleanUp(folder)
		} else if let feed = deleteNode.representedObject as? Feed {
			ActivityManager.cleanUp(feed)
		}

		if indexPath == coordinator.currentFeedIndexPath {
			coordinator.selectSidebarItem(indexPath: nil)
		}

		pushUndoableCommand(deleteCommand)
		deleteCommand.perform()
	}

	func sectionIdentifier(at indexPath: IndexPath) -> String? {
		let sectionIdentifiers = dataSource.snapshot().sectionIdentifiers
		guard indexPath.section < sectionIdentifiers.count else {
			return nil
		}
		return sectionIdentifiers[indexPath.section]
	}

	func isSmartFeedsSection(_ indexPath: IndexPath) -> Bool {
		sectionIdentifier(at: indexPath)?.isEmpty ?? false
	}

	func isFavoriteFeedsSection(_ indexPath: IndexPath) -> Bool {
		sectionIdentifier(at: indexPath) == FavoriteFeedsController.sectionID
	}

	func isAccountSection(_ indexPath: IndexPath) -> Bool {
		guard let sectionID = sectionIdentifier(at: indexPath) else {
			return false
		}
		return !sectionID.isEmpty && sectionID != FavoriteFeedsController.sectionID
	}

	func feed(at indexPath: IndexPath) -> Feed? {
		let representedObject = dataSource.itemIdentifier(for: indexPath)?.node.representedObject
		if let feed = representedObject as? Feed {
			return feed
		}
		if let alias = representedObject as? FavoriteFeedAlias {
			return alias.feed
		}
		return nil
	}

	func favoriteAlias(at indexPath: IndexPath) -> FavoriteFeedAlias? {
		dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? FavoriteFeedAlias
	}

	func favoriteFolder(at indexPath: IndexPath) -> FavoriteFeedsFolder? {
		dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? FavoriteFeedsFolder
	}

	func deleteFavoriteFolderAction(folder: FavoriteFeedsFolder) -> UIAction {
		let title = NSLocalizedString("Delete Folder", comment: "Delete Folder")
		return UIAction(title: title, image: Assets.Images.trash, attributes: .destructive) { [weak self] _ in
			self?.confirmDeleteFavoriteFolder(folder)
		}
	}

	func deleteFavoriteFolderSwipeAction(for folder: FavoriteFeedsFolder) -> UIContextualAction {
		let title = NSLocalizedString("Delete", comment: "Delete")
		let action = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
			self?.confirmDeleteFavoriteFolder(folder)
			completion(true)
		}
		action.image = UIImage(systemName: "trash")
		action.accessibilityLabel = title
		action.backgroundColor = UIColor.systemRed
		return action
	}

	func confirmDeleteFavoriteFolder(_ folder: FavoriteFeedsFolder) {
		let title = NSLocalizedString("Delete Folder", comment: "Delete folder")
		let localizedInformativeText = NSLocalizedString("Are you sure you want to delete the “%@” folder? Feeds stay in Favorites.", comment: "Favorite folder delete text")
		let message = NSString.localizedStringWithFormat(localizedInformativeText as NSString, folder.nameForDisplay) as String
		let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

		let cancelTitle = NSLocalizedString("Cancel", comment: "Cancel")
		alertController.addAction(UIAlertAction(title: cancelTitle, style: .cancel))

		let deleteTitle = NSLocalizedString("Delete", comment: "Delete")
		let deleteAction = UIAlertAction(title: deleteTitle, style: .destructive) { [weak self] _ in
			self?.coordinator.deleteFavoriteFolder(folder)
		}
		alertController.addAction(deleteAction)
		alertController.preferredAction = deleteAction
		present(alertController, animated: true)
	}

	func promptForNewFavoriteFolder(feed: Feed? = nil, completion: ((FavoriteFeedsFolder) -> Void)? = nil) {
		let title = NSLocalizedString("New Folder", comment: "New Folder")
		let alertController = UIAlertController(title: title, message: nil, preferredStyle: .alert)

		let cancelTitle = NSLocalizedString("Cancel", comment: "Cancel")
		alertController.addAction(UIAlertAction(title: cancelTitle, style: .cancel))

		let createTitle = NSLocalizedString("Create", comment: "Create")
		let createAction = UIAlertAction(title: createTitle, style: .default) { [weak self] _ in
			let name = alertController.textFields?.first?.text ?? ""
			guard let self else {
				return
			}
			let folder = self.coordinator.createFavoriteFolder(named: name)
			if let feed {
				self.coordinator.favorite(feed, to: folder, discloseFolder: true)
			}
			completion?(folder)
		}
		alertController.addAction(createAction)
		alertController.preferredAction = createAction

		alertController.addTextField { textField in
			textField.placeholder = NSLocalizedString("Name", comment: "Name")
			textField.clearButtonMode = .always
		}

		present(alertController, animated: true)
	}

	func favoriteFoldersMenu(indexPath: IndexPath) -> UIMenu? {
		guard let feed = feed(at: indexPath) else {
			return nil
		}
		return favoriteFoldersMenu(for: feed)
	}

	func favoriteFoldersMenu(for feed: Feed) -> UIMenu {
		UIMenu(
			title: Self.favoriteFoldersMenuTitle,
			identifier: Self.favoriteFoldersMenuIdentifier,
			children: favoriteFolderActions(for: feed)
		)
	}

	func favoriteFolderActions(for feed: Feed) -> [UIMenuElement] {
		let containingIDs = Set(FavoriteFeedsController.shared.foldersContaining(feed).map(\.folderID))
		var actions = [UIMenuElement]()

		for folder in FavoriteFeedsController.shared.userFolders {
			let state: UIMenuElement.State = containingIDs.contains(folder.folderID) ? .on : .off
			let action = UIAction(title: folder.nameForDisplay, state: state) { [weak self] _ in
				self?.coordinator.toggleFavorite(feed, in: folder)
				self?.refreshVisibleFavoriteFolderMenu(for: feed)
			}
			action.attributes.insert(.keepsMenuPresented)
			actions.append(action)
		}

		let newFolderTitle = NSLocalizedString("New Folder", comment: "New Folder")
		actions.append(UIAction(title: newFolderTitle, image: Assets.Images.folderOutlinePlus) { [weak self] _ in
			self?.promptForNewFavoriteFolder(feed: feed)
		})
		return actions
	}

	func refreshVisibleFavoriteFolderMenu(for feed: Feed) {
		DispatchQueue.main.async { [weak self] in
			guard let self else {
				return
			}
			self.collectionView.contextMenuInteraction?.updateVisibleMenu { visible in
				self.replacingFavoriteFolderMenu(in: visible, for: feed)
			}
		}
	}

	func replacingFavoriteFolderMenu(in menu: UIMenu, for feed: Feed) -> UIMenu {
		if menu.identifier == Self.favoriteFoldersMenuIdentifier || menu.title == Self.favoriteFoldersMenuTitle {
			return menu.replacingChildren(favoriteFolderActions(for: feed))
		}

		let children = menu.children.map { element -> UIMenuElement in
			guard let submenu = element as? UIMenu else {
				return element
			}
			return self.replacingFavoriteFolderMenu(in: submenu, for: feed)
		}
		return menu.replacingChildren(children)
	}

	func favoriteSwipeAction(for feed: Feed) -> UIContextualAction {
		let isFavorite = FavoriteFeedsController.shared.isFavorite(feed)
		let title = isFavorite ?
			NSLocalizedString("Unfavorite", comment: "Unfavorite") :
			NSLocalizedString("Favorite", comment: "Favorite")
		let action = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
			self?.coordinator.toggleFavorite(for: feed)
			completion(true)
		}
		action.image = UIImage(systemName: isFavorite ? "bookmark.slash.fill" : "bookmark.fill")
		action.accessibilityLabel = title
		action.backgroundColor = UIColor.systemOrange
		return action
	}

	func unfavoriteSwipeAction(for alias: FavoriteFeedAlias) -> UIContextualAction {
		let title = NSLocalizedString("Unfavorite", comment: "Unfavorite")
		let action = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
			self?.coordinator.unfavorite(alias)
			completion(true)
		}
		action.image = UIImage(systemName: "bookmark.slash")
		action.accessibilityLabel = title
		action.backgroundColor = UIColor.systemOrange
		return action
	}

	func presentFavoriteFolderPicker(sourceFolder: FavoriteFeedsFolder) {
		let title = NSLocalizedString("Add to Favorite Folder", comment: "Choose a favorite folder for batch add")
		let alertController = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

		for folder in FavoriteFeedsController.shared.userFolders {
			alertController.addAction(UIAlertAction(title: folder.nameForDisplay, style: .default) { [weak self] _ in
				self?.presentBatchFavoriteFolderSelection(sourceFolder: sourceFolder, destinationFolder: folder)
			})
		}

		let newFolderTitle = NSLocalizedString("New Folder", comment: "New Folder")
		alertController.addAction(UIAlertAction(title: newFolderTitle, style: .default) { [weak self] _ in
			self?.promptForNewFavoriteFolder { [weak self] folder in
				self?.presentBatchFavoriteFolderSelection(sourceFolder: sourceFolder, destinationFolder: folder)
			}
		})

		alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel))
		if let popover = alertController.popoverPresentationController {
			popover.sourceView = view
			popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
		}
		present(alertController, animated: true)
	}

	func presentBatchFavoriteFolderSelection(sourceFolder: FavoriteFeedsFolder, destinationFolder: FavoriteFeedsFolder) {
		let feeds = sourceFolder.aliases.compactMap(\.feed)
		presentBatchFavoriteSelection(feeds: feeds, mode: .addToFolder(destinationFolder))
	}

	func presentBatchFavoriteSelection(for folder: Folder) {
		let feeds = folder.topLevelFeeds.sorted { $0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending }
		presentBatchFavoriteSelection(feeds: feeds, mode: .addToFavorites)
	}

	private func presentBatchFavoriteSelection(feeds: [Feed], mode: BatchFavoriteFeedsMode) {
		let controller = BatchFavoriteFeedsViewController(feeds: feeds, mode: mode)
		controller.completion = { [weak self] result in
			self?.dismiss(animated: true) {
				self?.presentBatchFavoriteResult(result, mode: mode)
			}
		}

		let navigationController = UINavigationController(rootViewController: controller)
		navigationController.modalPresentationStyle = .formSheet
		present(navigationController, animated: true)
	}

	private func presentBatchFavoriteResult(_ result: BatchFavoriteResult, mode: BatchFavoriteFeedsMode) {
		let title = NSLocalizedString("Favorites Updated", comment: "Batch favorites result title")
		let action = NSLocalizedString("Done", comment: "Done")
		let message: String
		switch mode {
		case .addToFavorites:
			message = String.localizedStringWithFormat(
				NSLocalizedString("Added %ld feed(s) to Favorites. Skipped %ld already-favorite feed(s).", comment: "Batch add to Favorites result"),
				result.addedCount,
				result.skippedCount)
		case .addToFolder(let folder):
			message = String.localizedStringWithFormat(
				NSLocalizedString("Added %ld feed(s) to %@. Skipped %ld already-added feed(s).", comment: "Batch add to favorite folder result"),
				result.addedCount,
				folder.nameForDisplay,
				result.skippedCount)
		}
		let finalMessage = result.failedCount > 0
			? "\(message) " + String.localizedStringWithFormat(NSLocalizedString("Failed %ld feed(s).", comment: "Batch favorites failed count"), result.failedCount)
			: message

		let alertController = UIAlertController(title: title, message: finalMessage, preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: action, style: .default))
		present(alertController, animated: true)
	}

	private func findHeaderViewForFavoriteFeeds() -> MainFeedCollectionHeaderReusableView? {
		guard let sectionIndex = dataSource.snapshot().sectionIdentifiers.firstIndex(of: FavoriteFeedsController.sectionID) else {
			return nil
		}
		return collectionView.supplementaryView(
			forElementKind: UICollectionView.elementKindSectionHeader,
			at: IndexPath(item: 0, section: sectionIndex))
		as? MainFeedCollectionHeaderReusableView
	}
}
