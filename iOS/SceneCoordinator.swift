//
//  NavigationModelController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/21/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import os
import UserNotifications
import Account
import Articles
import ErrorLog
import RSCore
import RSTree
import SafariServices
import SwiftUI
import Images

enum SearchScope: Int {
	case timeline = 0
	case global = 1
	case feeds = 2
}

enum ShowFeedName {
	case none
	case byline
	case feed
}

struct SidebarItemNode: Hashable, Sendable {
	let node: Node
	let sidebarItemID: SidebarItemIdentifier
	let folderID: Int? // Identifies this folder (nil if not a folder)
	let parentFolderID: Int?
	let parentFavoriteFolderID: String?

	@MainActor init(_ node: Node) {
		self.node = node
		self.sidebarItemID = (node.representedObject as! SidebarItem).sidebarItemID!
		self.folderID = (node.representedObject as? Folder)?.folderID
		self.parentFolderID = (node.parent?.representedObject as? Folder)?.folderID
		self.parentFavoriteFolderID = (node.parent?.representedObject as? FavoriteFeedsFolder)?.folderID
	}

	nonisolated func hash(into hasher: inout Hasher) {
		hasher.combine(sidebarItemID)
		hasher.combine(folderID)
		hasher.combine(parentFolderID)
		hasher.combine(parentFavoriteFolderID)
	}

	nonisolated static func == (lhs: SidebarItemNode, rhs: SidebarItemNode) -> Bool {
		lhs.sidebarItemID == rhs.sidebarItemID && lhs.folderID == rhs.folderID && lhs.parentFolderID == rhs.parentFolderID
			&& lhs.parentFavoriteFolderID == rhs.parentFavoriteFolderID
	}
}

@MainActor final class SceneCoordinator: NSObject, UndoableCommandRunner {
	var undoableCommands = [UndoableCommand]()
	var undoManager: UndoManager? {
		return rootSplitViewController.undoManager
	}

	lazy var webViewProvider = WebViewProvider(coordinator: self)

	private var activityManager = ActivityManager()

	private var rootSplitViewController: RootSplitViewController!

	private var mainFeedCollectionViewController: MainFeedCollectionViewController!
	private var mainTimelineViewController: MainTimelineModernViewController?
	private var articleViewController: ArticleViewController?

	private let fetchAndMergeArticlesQueue = CoalescingQueue(name: "Fetch and Merge Articles", interval: 0.5)
	private let rebuildBackingStoresQueue = CoalescingQueue(name: "Rebuild The Backing Stores", interval: 0.5)
	private let refreshTimelineAfterStatusChangeQueue = CoalescingQueue(name: "Refresh Timeline After Status Change", interval: 0.5)
	private var queuedFetchAndMergeShouldAnimate = true
	private let saveColumnWidthsQueue = CoalescingQueue(name: "Save Column Widths", interval: 0.5)
	private var fetchSerialNumber = 0
	private let fetchRequestQueue = FetchRequestQueue()
	private var performanceFetchInterval: PerformanceDiagnosticInterval?
	private var performanceRequestID: Int?
	private var timelinePreparationTask: Task<Void, Never>?
	private var timelinePreparationState = TimelinePreparationState()
	private(set) var preparedTimelineArticles: TimelinePreparedArticles?
	private(set) var articlesRevision = 0

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "SceneCoordinator")

	private var isSidebarContextMenuPresented = false
	private var pendingFavoriteFeedsReload = false

	// Which Containers are expanded
	private var expandedContainers = Set<ContainerIdentifier>()

	// Which Containers used to be expanded. Reset by rebuilding the sidebar.
	private var lastExpandedContainers = Set<ContainerIdentifier>()

	private let hidingReadArticlesState = HidingReadArticlesState()
	private let timelineSortDirectionState = TimelineSortDirectionState()

	private(set) var preSearchTimelineFeed: SidebarItem?
	private var lastSearchString = ""
	private var lastSearchScope: SearchScope?
	private var isSearching: Bool = false
	private var savedSearchArticles: ArticleArray?
	private var savedSearchArticleIDs: Set<String>?
	private var isRestoringState = false

	var isTimelineViewControllerPending = false
	var isArticleViewControllerPending = false

	/// `Bool` to track whether a refresh is scheduled.
	private var isNavigationBarSubtitleRefreshScheduled: Bool = false

	private(set) var sortDirection = AppDefaults.shared.timelineSortDirection {
		didSet {
			if sortDirection != oldValue {
				sortParametersDidChange()
			}
		}
	}

	private(set) var groupByFeed = AppDefaults.shared.timelineGroupByFeed {
		didSet {
			if groupByFeed != oldValue {
				sortParametersDidChange()
			}
		}
	}

	var prefersStatusBarHidden = false

	private let treeControllerDelegate = SidebarTreeControllerDelegate()
	private let treeController: TreeController

	var stateRestorationActivity: NSUserActivity {
		activityManager.stateRestorationActivity
	}

	var isNavigationDisabled = false

	var isRootSplitCollapsed: Bool {
		return rootSplitViewController.isCollapsed
	}

	// In collapsed mode, the article view is in the window only while it’s on top of the navigation stack.
	var isArticleViewControllerShowing: Bool {
		articleViewController?.viewIfLoaded?.window != nil
	}

	var isReadFeedsFiltered: Bool {
		return treeControllerDelegate.isReadFiltered
	}

	var isReadArticlesFiltered: Bool {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			return false
		}
		return hidingReadArticlesState.isHidingReadArticles(for: sidebarItemID)
	}

	var timelineDefaultReadFilterType: ReadFilterType {
		return timelineFeed?.defaultReadFilterType ?? .none
	}

	var rootNode: Node {
		return treeController.rootNode
	}

	// At some point we should refactor the current Feed IndexPath out and only use the timeline feed
	private(set) var currentFeedIndexPath: IndexPath?

	var timelineIconImage: IconImage? {
		guard let timelineFeed = timelineFeed else {
			return nil
		}
		return IconImageCache.shared.imageForFeed(timelineFeed)
	}

	private var exceptionArticleFetcher: ArticleFetcher?
	private var videoPlaybackArticles = [Article]()
	private(set) var timelineFeed: SidebarItem? {
		didSet {
			mainTimelineViewController?.cancelPendingScrollReset()
			mainTimelineViewController?.updateNavigationBarTitle(timelineFeed?.nameForDisplay ?? "")
			updateNavigationBarSubtitles(nil)
			updateTimelineSortDirection()
			mainTimelineViewController?.resetUI(resetScroll: false)
		}
	}

	var timelineMiddleIndexPath: IndexPath?

	private(set) var showFeedNames = ShowFeedName.none
	private(set) var showIcons = false

	var prevFeedIndexPath: IndexPath? {
		guard let indexPath = currentFeedIndexPath else {
			return nil
		}

		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot

		let prevIndexPath: IndexPath? = {
			if indexPath.row - 1 < 0 {
				for i in (0..<indexPath.section).reversed() {
					let numberOfItems = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[i])
					if numberOfItems > 0 {
						return IndexPath(row: numberOfItems - 1, section: i)
					}
				}
				return nil
			} else {
				return IndexPath(row: indexPath.row - 1, section: indexPath.section)
			}
		}()

		return prevIndexPath
	}

	var nextFeedIndexPath: IndexPath? {
		guard let indexPath = currentFeedIndexPath else {
			return nil
		}

		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot
		let numberOfSections = snapshot.numberOfSections

		let nextIndexPath: IndexPath? = {
			let numberOfItems = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[indexPath.section])
			if indexPath.row + 1 >= numberOfItems {
				for i in indexPath.section + 1..<numberOfSections {
					let count = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[i])
					if count > 0 {
						return IndexPath(row: 0, section: i)
					}
				}
				return nil
			} else {
				return IndexPath(row: indexPath.row + 1, section: indexPath.section)
			}
		}()

		return nextIndexPath
	}

	var isPrevArticleAvailable: Bool {
		guard let articleRow = currentArticleRow else {
			return false
		}
		return articleRow > 0
	}

	var isNextArticleAvailable: Bool {
		guard let articleRow = currentArticleRow else {
			return false
		}
		return articleRow + 1 < articles.count
	}

	var prevArticle: Article? {
		guard isPrevArticleAvailable, let articleRow = currentArticleRow else {
			return nil
		}
		return articles[articleRow - 1]
	}

	var nextArticle: Article? {
		guard isNextArticleAvailable, let articleRow = currentArticleRow else {
			return nil
		}
		return articles[articleRow + 1]
	}

	var firstUnreadArticleIndexPath: IndexPath? {
		for (row, article) in articles.enumerated() {
			if !article.status.read {
				return IndexPath(row: row, section: 0)
			}
		}
		return nil
	}

	var currentArticle: Article? {
		didSet {
			if let article = currentArticle {
				AppDefaults.shared.selectedArticle = ArticleSpecifier(article: article)
			} else {
				AppDefaults.shared.selectedArticle = nil
			}
		}
	}

	private(set) var articles = ArticleArray() {
		didSet {
			articlesRevision += 1
			timelineMiddleIndexPath = nil
			articleDictionaryNeedsUpdate = true
		}
	}

	private var articleDictionaryNeedsUpdate = true
	private var _idToArticleDictionary = [String: Article]()
	private var idToArticleDictionary: [String: Article] {
		if articleDictionaryNeedsUpdate {
			rebuildArticleDictionaries()
		}
		return _idToArticleDictionary
	}

	private var currentArticleRow: Int? {
		guard let article = currentArticle else {
			return nil
		}
		return articles.firstIndex(where: { $0.articleID == article.articleID && $0.accountID == article.accountID })
	}

	var isTimelineUnreadAvailable: Bool {
		return timelineUnreadCount > 0
	}

	var isNextUnreadAvailable: Bool {
		// Return false when the only unread article is the selected article.
		// With nothing selected — e.g. the collapsed timeline — this falls through to "is there any unread at all".
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5008>
		if AccountManager.shared.unreadCount == 1, let article = currentArticle, !article.status.read {
			return false
		}
		return AccountManager.shared.unreadCount > 0
	}

	var timelineUnreadCount: Int = 0 {
		didSet {
			updateNavigationBarSubtitles(nil)
		}
	}

	private static let minimumTimelineWidth: CGFloat = 280
	private static let maximumTimelineWidth: CGFloat = 440

	private static func clampTimelineWidth(_ width: CGFloat) -> CGFloat {
		if width < minimumTimelineWidth {
			return minimumTimelineWidth
		}
		if width > maximumTimelineWidth {
			return maximumTimelineWidth
		}
		return width
	}

	private static let minimumSidebarWidth: CGFloat = 300
	private static let maximumSidebarWidth: CGFloat = 500

	private static func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
		if width < minimumSidebarWidth {
			return minimumSidebarWidth
		}
		if width > maximumSidebarWidth {
			return maximumSidebarWidth
		}
		return width
	}

	init(rootSplitViewController: RootSplitViewController) {
		self.rootSplitViewController = rootSplitViewController
		self.rootSplitViewController.minimumPrimaryColumnWidth = SceneCoordinator.minimumSidebarWidth
		self.rootSplitViewController.maximumPrimaryColumnWidth = SceneCoordinator.maximumSidebarWidth
		self.rootSplitViewController.minimumSupplementaryColumnWidth = SceneCoordinator.minimumTimelineWidth
		self.rootSplitViewController.maximumSupplementaryColumnWidth = SceneCoordinator.maximumTimelineWidth
		let restoredTimelineWidth: CGFloat
		if let savedTimelineWidth = AppDefaults.shared.timelineWidth {
			restoredTimelineWidth = CGFloat(savedTimelineWidth)
		} else {
			restoredTimelineWidth = 320
		}
		self.rootSplitViewController.preferredSupplementaryColumnWidth = Self.clampTimelineWidth(restoredTimelineWidth)
		if let savedSidebarWidth = AppDefaults.shared.sidebarWidth {
			self.rootSplitViewController.preferredPrimaryColumnWidth = Self.clampSidebarWidth(CGFloat(savedSidebarWidth))
		}
		self.rootSplitViewController.preferredSplitBehavior = .tile

		self.treeController = TreeController(delegate: treeControllerDelegate)

		super.init()

		self.mainFeedCollectionViewController = rootSplitViewController.viewController(for: .primary) as? MainFeedCollectionViewController
		self.mainFeedCollectionViewController.coordinator = self
		self.mainFeedCollectionViewController?.navigationController?.delegate = self
		updateNavigationBarSubtitles(nil)

		self.mainTimelineViewController = rootSplitViewController.viewController(for: .supplementary) as? MainTimelineModernViewController
		self.mainTimelineViewController?.coordinator = self
		self.mainTimelineViewController?.navigationController?.delegate = self

		self.articleViewController = rootSplitViewController.viewController(for: .secondary) as? ArticleViewController
		self.articleViewController?.coordinator = self
		self.articleViewController?.navigationController?.delegate = self

		for sectionNode in treeController.rootNode.childNodes {
			markExpanded(sectionNode)
		}

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidInitialize(_:)), name: .UnreadCountDidInitialize, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(containerChildrenDidChange(_:)), name: .ChildrenDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange(_:)), name: .DisplayNameDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountStateDidChange(_:)), name: .AccountStateDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(userDidAddAccount(_:)), name: .UserDidAddAccount, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(userDidDeleteAccount(_:)), name: .UserDidDeleteAccount, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(userDidAddFeed(_:)), name: .UserDidAddFeed, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDownloadArticles(_:)), name: .AccountDidDownloadArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(favoriteFeedsDidChange(_:)), name: .FavoriteFeedsDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(importDownloadedTheme(_:)), name: .didEndDownloadingTheme, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(themeDownloadDidFail(_:)), name: .didFailToImportThemeWithError, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(updateNavigationBarSubtitles(_:)), name: .progressInfoDidChange, object: CombinedRefreshProgress.shared)

		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.userDefaultsDidChange()
			}
		}
	}

	func restoreWindowState(activity: NSUserActivity?, restoreSelection: Bool) {
		let stateInfo = StateRestorationInfo(legacyState: activity)
		restoreWindowState(stateInfo, restoreSelection: restoreSelection)
	}

	private func restoreWindowState(_ stateInfo: StateRestorationInfo, restoreSelection: Bool) {
		Self.logger.debug("SceneCoordinator: restoreWindowState")

		isRestoringState = true

		if AppDefaults.shared.isFirstRun {
			// Expand top-level items on first run.
			for sectionNode in treeController.rootNode.childNodes {
				markExpanded(sectionNode)
			}
			saveExpandedContainers()
		} else {
			expandedContainers = stateInfo.expandedContainers
		}

		hidingReadArticlesState.copy(from: stateInfo)
		timelineSortDirectionState.copy(from: stateInfo)

		// Ensure the view is loaded so dataSource is initialized before rebuilding
		_ = mainFeedCollectionViewController.view

		rebuildBackingStores(initialLoad: true)

		// You can’t assign the Feeds Read Filter until we’ve built the backing stores at least once or there is nothing
		// for state restoration to work with while we are waiting for the unread counts to initialize.
		treeControllerDelegate.isReadFiltered = stateInfo.hideReadFeeds

		guard restoreSelection else {
			isRestoringState = false
			return
		}

		restoreSelectedSidebarItemAndArticle(stateInfo)
	}

	private func restoreSelectedSidebarItemAndArticle(_ stateInfo: StateRestorationInfo) {
		guard let selectedSidebarItem = stateInfo.selectedSidebarItem else {
			isRestoringState = false
			return
		}

		guard let sidebarItemNode = nodeFor(sidebarItemID: selectedSidebarItem),
			  let indexPath = indexPathFor(sidebarItemNode) else {
			isRestoringState = false
			return
		}
		selectSidebarItem(indexPath: indexPath, animations: []) {
			self.restoreSelectedArticle(stateInfo)
		}
	}

	private func restoreSelectedArticle(_ stateInfo: StateRestorationInfo) {
		defer {
			isRestoringState = false
		}

		guard let articleSpecifier = stateInfo.selectedArticle else {
			return
		}

		let article = articles.article(matching: articleSpecifier) ??
		AccountManager.shared.fetchArticle(accountID: articleSpecifier.accountID,
										   articleID: articleSpecifier.articleID)

		if let article {
			// Disable animation since this function runs only during state restoration on launch.
			UIView.performWithoutAnimation {
				selectArticle(article, isShowingExtractedArticle: stateInfo.isShowingExtractedArticle, articleWindowScrollY: stateInfo.articleWindowScrollY)
			}
		}
	}

	func handle(_ activity: NSUserActivity) {
		guard let activityType = ActivityType(rawValue: activity.activityType) else {
			return
		}

		// Add Feed just presents a sheet — unlike the activities below, it doesn’t navigate,
		// so it must not clear the current selection.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4352>
		if activityType == .addFeedIntent {
			showAddFeed()
			return
		}

		selectSidebarItem(indexPath: nil) {
			switch activityType {
			case .selectFeed:
				self.handleSelectFeed(activity.userInfo)
			case .nextUnread:
				self.selectFirstUnreadInAllUnread()
			case .readArticle:
				self.handleReadArticle(activity.userInfo)
			case .restoration, .addFeedIntent:
				break
			}
		}
	}

	func handle(_ response: UNNotificationResponse) {
		let userInfo = response.notification.request.content.userInfo
		handleReadArticle(userInfo)
	}

	func resetFocus() {
		if currentArticle != nil {
			mainTimelineViewController?.focus()
		} else {
			mainFeedCollectionViewController?.focus()
		}
	}

	func selectFirstUnreadInAllUnread() {
		markExpanded(SmartFeedsController.shared)
		self.ensureFeedIsAvailableToSelect(SmartFeedsController.shared.unreadFeed) {
			self.selectFeed(SmartFeedsController.shared.unreadFeed) {
				self.selectFirstUnreadArticleInTimeline()
			}
		}
	}

	func showSearch() {
		selectSidebarItem(indexPath: nil) {
			self.rootSplitViewController.showColumn(.supplementary)
			DispatchQueue.main.asyncAfter(deadline: .now()) {
				self.mainTimelineViewController!.showSearchAll()
			}
		}
	}

	// MARK: Notifications

	@objc func unreadCountDidInitialize(_ notification: Notification) {
		Self.logger.debug("SceneCoordinator: unreadCountDidInitialize")

		guard notification.object is AccountManager else {
			return
		}

		if isReadFeedsFiltered {
			rebuildBackingStores()
		}
	}

	@objc func unreadCountDidChange(_ note: Notification) {
		// We will handle the filtering of unread feeds in unreadCountDidInitialize after they have all be calculated
		guard AccountManager.shared.areUnreadCountsInitialized else {
			return
		}
		queueRebuildBackingStores()
	}

	@objc func statusesDidChange(_ note: Notification) {
		updateUnreadCount()
	}

	@objc func containerChildrenDidChange(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: containerChildrenDidChange")
		if timelineFetcherContainsAnyPseudoFeed() || timelineFetcherContainsAnyFolder() {
			fetchAndMergeArticlesAsync(animated: true) {
				self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
				self.queueRebuildBackingStores()
			}
		} else {
			queueRebuildBackingStores()
		}
	}

	@objc func displayNameDidChange(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: displayNameDidChange")

		if let sidebarItem = note.object as? SidebarItem {
			reconfigureSidebarItem(sidebarItem)
			if timelineFeed?.sidebarItemID == sidebarItem.sidebarItemID {
				mainTimelineViewController?.updateNavigationBarTitle(sidebarItem.nameForDisplay)
			}
		}
		queueRebuildBackingStores()
	}

	@objc func accountStateDidChange(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: accountStateDidChange")

		if timelineFetcherContainsAnyPseudoFeed() {
			fetchAndMergeArticlesAsync(animated: true) {
				self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
				self.rebuildBackingStores()
			}
		} else {
			self.rebuildBackingStores()
		}
	}

	@objc func userDidAddAccount(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: userDidAddAccount")

		let expandNewAccount = {
			if let account = note.userInfo?[Account.UserInfoKey.account] as? Account,
				let node = self.treeController.rootNode.childNodeRepresentingObject(account) {
				self.markExpanded(node)
			}
		}

		if timelineFetcherContainsAnyPseudoFeed() {
			fetchAndMergeArticlesAsync(animated: true) {
				self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
				self.rebuildBackingStores(updateExpandedNodes: expandNewAccount)
			}
		} else {
			self.rebuildBackingStores(updateExpandedNodes: expandNewAccount)
		}
	}

	@objc func userDidDeleteAccount(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: userDidDeleteAccount")

		undoManager?.removeAllActions() // Undo stack may contain actions for the deleted account.

		let cleanupAccount = {
			if let account = note.userInfo?[Account.UserInfoKey.account] as? Account,
				let node = self.treeController.rootNode.childNodeRepresentingObject(account) {
				self.unmarkExpanded(node)
			}
		}

		if timelineFetcherContainsAnyPseudoFeed() {
			fetchAndMergeArticlesAsync(animated: true) {
				self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
				self.rebuildBackingStores(updateExpandedNodes: cleanupAccount)
			}
		} else {
			self.rebuildBackingStores(updateExpandedNodes: cleanupAccount)
		}
	}

	@objc func userDidAddFeed(_ notification: Notification) {
		guard let feed = notification.userInfo?[UserInfoKey.feed] as? Feed else {
			return
		}

		// Disclosing navigates away from whatever the user was reading, so do it only when
		// nothing is selected — otherwise adding a feed would cost them their place.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4352>
		guard timelineFeed == nil else {
			return
		}

		discloseFeed(feed, animations: [.scroll, .navigation])
	}

	func userDefaultsDidChange() {
		updateTimelineSortDirection()
		groupByFeed = AppDefaults.shared.timelineGroupByFeed
		mainTimelineViewController?.resetUI(resetScroll: false)
	}

	func beginSidebarContextMenu() {
		isSidebarContextMenuPresented = true
	}

	func endSidebarContextMenu() {
		isSidebarContextMenuPresented = false
		flushPendingFavoriteFeedsReload()
	}

	@objc func favoriteFeedsDidChange(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: favoriteFeedsDidChange")
		reloadFavoriteFeeds(deferIfContextMenuPresented: true)
	}

	@objc func accountDidDownloadArticles(_ note: Notification) {
		guard let feeds = note.userInfo?[Account.UserInfoKey.feeds] as? Set<Feed> else {
			return
		}

		let shouldFetchAndMergeArticles = timelineFetcherContainsAnyFeed(feeds) || timelineFetcherContainsAnyPseudoFeed()
		if shouldFetchAndMergeArticles {
			queueFetchAndMergeArticles()
		}
	}

	@objc func willEnterForeground(_ note: Notification) {
		// Don’t interfere with any fetch requests that we may have initiated before the app was returned to the foreground.
		// For example if you select Next Unread from the Home Screen Quick actions, you can start a request before we are
		// in the foreground.
		if !fetchRequestQueue.isAnyCurrentRequest {
			PerformanceDiagnosticLog.event(operation: "Timeline refresh", message: "queue reason=foreground kind=\(timelinePerformanceKind)")
			queueTimelineRefresh(for: .foreground)
		} else {
			PerformanceDiagnosticLog.event(operation: "Timeline refresh", message: "skip reason=foreground current_request=true kind=\(timelinePerformanceKind)")
		}
		AccountManager.shared.repairStatusesIfNeeded()
	}

	@objc func importDownloadedTheme(_ note: Notification) {
		guard let userInfo = note.userInfo,
			let url = userInfo["url"] as? URL else {
			return
		}

		DispatchQueue.main.async {
			self.importTheme(filename: url.path)
		}
	}

	@objc func themeDownloadDidFail(_ note: Notification) {
		guard let userInfo = note.userInfo,
			  let error = userInfo["error"] as? Error else {
				  return
			  }
		DispatchQueue.main.async {
			let title = NSLocalizedString("Theme Error", comment: "Theme download error")
			self.rootSplitViewController.presentError(title: title, message: ArticleThemesManager.importErrorMessage(for: error))
		}
	}

	/// Updates navigation bar subtitles in response to feed selection, unread count changes,
	/// `progressInfoDidChange` notifications, and a timed refresh every
	/// 60s.
	///
	/// Subtitles are handled differently on iPhone and iPad.
	///
	/// `MainFeedViewController`
	/// - When refreshing: Feeds will display "Updating..." on both iPhone and iPad.
	/// - When refreshed: Feeds will display "Updated <#relative_time#>" on both iPhone and iPad.
	///
	/// `MainTimelineViewController`
	/// - Where the unread count for the timeline is > 0, this is displayed on both iPhone and iPad.
	/// - If the timeline count is 0, the iPhone follows the same logic as `MainFeedViewController`
	/// - Specific to iPad, if the unread count is 0, the iPad will not display a subtitle. The refresh text
	/// will generally be visible in the sidebar and there’s no need to display it twice.
	///
	/// - Parameter note: Optional `Notification`
	@objc func updateNavigationBarSubtitles(_ note: Notification?) {
		let progressInfo = CombinedRefreshProgress.shared.progressInfo

		if progressInfo.isComplete {
			if let accountLastArticleFetchEndTime = AccountManager.shared.lastRefreshCompletedDate {
				if Date.now > accountLastArticleFetchEndTime.addingTimeInterval(60) {
					let relativeDateTimeFormatter = RelativeDateTimeFormatter()
					relativeDateTimeFormatter.dateTimeStyle = .named
					let refreshed = relativeDateTimeFormatter.localizedString(for: accountLastArticleFetchEndTime, relativeTo: Date())
					let localizedRefreshText = NSLocalizedString("Updated %@", comment: "Updated")
					let refreshText = NSString.localizedStringWithFormat(localizedRefreshText as NSString, refreshed) as String

					// Update Feeds with Updated text
					if #available(iOS 26, *) {
						self.mainFeedCollectionViewController?.navigationItem.subtitle = refreshText
					}

					// If unread count > 0, add unread string to timeline
					if timelineFeed != nil, timelineUnreadCount > 0 {
						let localizedUnreadCount = NSLocalizedString("%i Unread", comment: "14 Unread")
						let unreadCount = NSString.localizedStringWithFormat(localizedUnreadCount as NSString, timelineUnreadCount) as String
						self.mainTimelineViewController?.updateNavigationBarSubtitle(unreadCount)
					} else {
						// When unread count == 0, iPhone timeline displays Updated Just Now; iPad is blank
						if UIDevice.current.userInterfaceIdiom == .phone {
							self.mainTimelineViewController?.updateNavigationBarSubtitle(refreshText)
						} else {
							self.mainTimelineViewController?.updateNavigationBarSubtitle("")
						}
					}
				} else {
					// Use 'Updated Just Now' while <60s have passed since refresh.
					if #available(iOS 26, *) {
						self.mainFeedCollectionViewController?.navigationItem.subtitle = NSLocalizedString("Updated Just Now", comment: "Updated Just Now")
					}

					// If unread count > 0, add unread string to timeline
					if timelineFeed != nil, timelineUnreadCount > 0 {
						let localizedUnreadCount = NSLocalizedString("%i Unread", comment: "14 Unread")
						let refreshTextWithUnreadCount = NSString.localizedStringWithFormat(localizedUnreadCount as NSString, timelineUnreadCount) as String
						self.mainTimelineViewController?.updateNavigationBarSubtitle(refreshTextWithUnreadCount)
					} else {
						// When unread count == 0, iPhone timeline displays Updated Just Now; iPad is blank
						if UIDevice.current.userInterfaceIdiom == .phone {
							self.mainTimelineViewController?.updateNavigationBarSubtitle(NSLocalizedString("Updated Just Now", comment: "Updated Just Now"))
						} else {
							self.mainTimelineViewController?.updateNavigationBarSubtitle("")
						}
					}
				}
			} else {
				if #available(iOS 26, *) {
					self.mainFeedCollectionViewController?.navigationItem.subtitle = ""
				}
				// If unread count > 0, add unread string to timeline
				if timelineFeed != nil, timelineUnreadCount > 0 {
					let localizedUnreadCount = NSLocalizedString("%i Unread", comment: "14 Unread")
					let refreshTextWithUnreadCount = NSString.localizedStringWithFormat(localizedUnreadCount as NSString, timelineUnreadCount) as String
					self.mainTimelineViewController?.updateNavigationBarSubtitle(refreshTextWithUnreadCount)
				} else {
					// When unread count == 0, iPhone timeline displays Updated Just Now; iPad is blank
					if UIDevice.current.userInterfaceIdiom == .phone {
						self.mainTimelineViewController?.updateNavigationBarSubtitle(NSLocalizedString("Updated Just Now", comment: "Updated Just Now"))
					} else {
						self.mainTimelineViewController?.updateNavigationBarSubtitle("")
					}
				}
			}
		} else {
			// Updating in progress, apply to both iPhone and iPad Feeds.
			if #available(iOS 26, *) {
				self.mainFeedCollectionViewController?.navigationItem.subtitle = NSLocalizedString("Updating…", comment: "Updating…")
			}
		}

		scheduleNavigationBarSubtitleUpdate()
	}

	func scheduleNavigationBarSubtitleUpdate() {
		if isNavigationBarSubtitleRefreshScheduled {
			return
		}
		isNavigationBarSubtitleRefreshScheduled = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
			self?.isNavigationBarSubtitleRefreshScheduled = false
			self?.updateNavigationBarSubtitles(nil)
		}
	}

	// MARK: API

	func didEnterBackground() {
		hidingReadArticlesState.save()
		timelineSortDirectionState.save()
		saveExpandedContainers()
	}

	func timelineDidLayout() {
		saveColumnWidthsQueue.add(self, #selector(saveTimelineWidth))
	}

	@objc private func saveTimelineWidth() {
		guard !rootSplitViewController.isCollapsed, rootSplitViewController.displayMode != .secondaryOnly else {
			return
		}
		// The timeline view extends under the sidebar, so its bounds are wider than the column looks.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5401>
		let width = mainTimelineViewController?.view.safeAreaLayoutGuide.layoutFrame.width ?? 0
		guard width > 0 else {
			return
		}
		AppDefaults.shared.timelineWidth = Int(SceneCoordinator.clampTimelineWidth(width))
	}

	func sidebarDidLayout() {
		saveColumnWidthsQueue.add(self, #selector(saveSidebarWidth))
	}

	@objc private func saveSidebarWidth() {
		// The sidebar is only on screen in the "two" display modes. In the others, a layout pass
		// during a hide animation could measure a transient width that the clamp would floor to the minimum.
		let displayMode = rootSplitViewController.displayMode
		let sidebarIsVisible = displayMode == .twoBesideSecondary || displayMode == .twoOverSecondary || displayMode == .twoDisplaceSecondary
		guard !rootSplitViewController.isCollapsed, sidebarIsVisible else {
			return
		}
		let width = mainFeedCollectionViewController?.view.safeAreaLayoutGuide.layoutFrame.width ?? 0
		guard width > 0 else {
			return
		}
		AppDefaults.shared.sidebarWidth = Int(SceneCoordinator.clampSidebarWidth(width))
	}

	func suspend() {
		invalidateTimelinePreparation()
		fetchAndMergeArticlesQueue.performCallsImmediately()
		rebuildBackingStoresQueue.performCallsImmediately()
		refreshTimelineAfterStatusChangeQueue.cancelPendingCalls()
		fetchRequestQueue.cancelAllRequests()
	}

	func saveExpandedContainers() {
		AppDefaults.shared.expandedContainers = expandedContainers
	}

	func cleanUp(conditional: Bool) {
		Self.logger.debug("SceneCoordinator: cleanUp: conditional \(conditional ? "true" : "false")")
		if isReadFeedsFiltered {
			rebuildBackingStores()
		}
		if AppDefaults.shared.refreshClearsReadArticles || !conditional {
			removeArticlesHiddenByReadFilter()
		}
	}

	func removeArticlesHiddenByReadFilter() {
		removeReadArticles { _ in true }
	}

	// Marking one feed read shouldn’t make another feed’s already-read rows disappear.
	func removeArticlesHiddenByReadFilter(among articleIDs: Set<String>) {
		removeReadArticles { articleIDs.contains($0.articleID) }
	}

	// Cleanup dropped these articles, so fetching is the only way to get the rows back.
	func restoreArticlesToTimeline() {
		guard isReadArticlesFiltered else {
			return
		}

		queueFetchAndMergeArticles()
	}

	private func removeReadArticles(where isEligible: @escaping (Article) -> Bool) {
		let sidebarItemID = timelineFeed?.sidebarItemID

		// A snapshot applied during a UIKit transition gets dropped, so wait it out.
		Task { @MainActor in
			// If the timeline moved on while we waited, it’s not the one the user acted on.
			guard sidebarItemID == self.timelineFeed?.sidebarItemID, self.isReadArticlesFiltered else {
				return
			}

			// Keep the open article — don’t pull the row out from under what the user is reading.
			let remainingArticles = self.articles.filter { article in
				!article.status.read || !isEligible(article) || self.isCurrentArticle(article)
			}
			self.replaceArticles(with: remainingArticles, animated: true)
		}
	}

	private func isCurrentArticle(_ article: Article) -> Bool {
		guard let currentArticle else {
			return false
		}
		return article.articleID == currentArticle.articleID && article.accountID == currentArticle.accountID
	}

	func toggleReadFeedsFilter() {
		Self.logger.debug("SceneCoordinator: toggleReadFeedsFilter")

		let newValue = !isReadFeedsFiltered
		treeControllerDelegate.isReadFiltered = newValue
		AppDefaults.shared.hideReadFeeds = newValue
		rebuildBackingStores()
		mainFeedCollectionViewController?.updateUI()
	}

	func shouldShowFilterButton() -> Bool {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			return false
		}
		return hidingReadArticlesState.canToggleHidingReadArticles(for: sidebarItemID)
	}

	func shouldShowSortDirectionButton() -> Bool {
		timelineFeed?.sidebarItemID != nil
	}

	func toggleTimelineSortDirection() {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			return
		}
		timelineSortDirectionState.toggleSortDirection(for: sidebarItemID, defaultSortDirection: AppDefaults.shared.timelineSortDirection)
		updateTimelineSortDirection()
		mainTimelineViewController?.resetUI(resetScroll: false)
	}

	func toggleReadArticlesFilter() {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			return
		}
		hidingReadArticlesState.toggleHidingReadArticles(for: sidebarItemID)
		refreshTimeline(resetScroll: false)
	}

	func nodeFor(sidebarItemID: SidebarItemIdentifier) -> Node? {
		return treeController.rootNode.descendantNode(where: { node in
			if let sidebarItem = node.representedObject as? SidebarItem {
				return sidebarItem.sidebarItemID == sidebarItemID
			} else {
				return false
			}
		})
	}

	func nodeFor(_ indexPath: IndexPath) -> Node? {
		guard let sidebarItemNode = mainFeedCollectionViewController.sidebarItemNode(for: indexPath) else {
			return nil
		}
		return sidebarItemNode.node
	}

	func indexPathFor(_ node: Node) -> IndexPath? {
		let sidebarItemNode = SidebarItemNode(node)
		return mainFeedCollectionViewController.indexPath(for: sidebarItemNode)
	}

	func articleFor(_ articleID: String) -> Article? {
		// Check if it’s the currently displayed article
		if let currentArticle, currentArticle.articleID == articleID {
			return currentArticle
		}
		return idToArticleDictionary[articleID] ?? videoPlaybackArticles.first(where: { $0.articleID == articleID })
	}

	func retainArticleForVideoPlayback(_ article: Article) {
		guard !videoPlaybackArticles.contains(where: { $0.articleID == article.articleID && $0.accountID == article.accountID }) else {
			return
		}
		videoPlaybackArticles.append(article)
	}

	func unreadCountFor(_ node: Node) -> Int {
		// The coordinator supplies the unread count for the currently selected feed
		if node.representedObject === timelineFeed as AnyObject {
			return timelineUnreadCount
		}
		if let unreadCountProvider = node.representedObject as? UnreadCountProvider {
			return unreadCountProvider.unreadCount
		}
		assertionFailure("This method should only be called for nodes that have an UnreadCountProvider as the represented object.")
		return 0
	}

	func refreshTimeline(resetScroll: Bool) {
		fetchAndReplaceArticlesAsync(animated: true, emptyFirst: false) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: resetScroll)
		}
	}

	func isExpanded(_ containerID: ContainerIdentifier) -> Bool {
		return expandedContainers.contains(containerID)
	}

	func isExpanded(_ containerIdentifiable: ContainerIdentifiable) -> Bool {
		if let containerID = containerIdentifiable.containerID {
			return isExpanded(containerID)
		}
		return false
	}

	func isExpanded(_ node: Node) -> Bool {
		if let containerIdentifiable = node.representedObject as? ContainerIdentifiable {
			return isExpanded(containerIdentifiable)
		}
		return false
	}

	func expand(_ containerID: ContainerIdentifier) {
		Self.logger.debug("SceneCoordinator: expand")

		markExpanded(containerID)
		rebuildBackingStores()
		saveExpandedContainers()
	}

	/// This is a special function that expects the caller to change the disclosure arrow state outside this function.
	/// Failure to do so will get the Sidebar into an invalid state.
	func expand(_ node: Node) {
		guard let containerID = (node.representedObject as? ContainerIdentifiable)?.containerID else {
			return
		}
		lastExpandedContainers.insert(containerID)
		expand(containerID)
	}

	func expandAllSectionsAndFolders() {
		Self.logger.debug("SceneCoordinator: expandAllSectionsAndFolders")

		for sectionNode in treeController.rootNode.childNodes {
			markExpanded(sectionNode)
			for topLevelNode in sectionNode.childNodes {
				if topLevelNode.representedObject is Folder || topLevelNode.representedObject is FavoriteFeedsFolder {
					markExpanded(topLevelNode)
				}
			}
		}
		rebuildBackingStores()
		saveExpandedContainers()
	}

	func collapse(_ containerID: ContainerIdentifier) {
		Self.logger.debug("SceneCoordinator: collapse")
		unmarkExpanded(containerID)
		rebuildBackingStores()
		clearTimelineIfNoLongerAvailable()
		saveExpandedContainers()
	}

	/// This is a special function that expects the caller to change the disclosure arrow state outside this function.
	/// Failure to do so will get the Sidebar into an invalid state.
	func collapse(_ node: Node) {
		guard let containerID = (node.representedObject as? ContainerIdentifiable)?.containerID else {
			return
		}
		lastExpandedContainers.remove(containerID)
		collapse(containerID)
	}

	func collapseFoldersOrSections() {
		Self.logger.debug("SceneCoordinator: collapseFoldersOrSections")
		let hasExpandedFolder = treeController.rootNode.childNodes.contains { sectionNode in
			isExpanded(sectionNode) && sectionNode.childNodes.contains { node in
				(node.representedObject is Folder || node.representedObject is FavoriteFeedsFolder) && isExpanded(node)
			}
		}
		if hasExpandedFolder {
			collapseAllFolders()
			return
		}

		let sectionsToCollapse = treeController.rootNode.childNodes.filter { node in
			(node.representedObject is Account || node.representedObject is FavoriteFeedsController) && isExpanded(node)
		}
		guard !sectionsToCollapse.isEmpty else {
			return
		}
		for sectionNode in sectionsToCollapse {
			unmarkExpanded(sectionNode)
		}
		rebuildBackingStores { [weak self] in
			self?.mainFeedCollectionViewController.refreshVisibleDisclosureStates()
			self?.clearTimelineIfNoLongerAvailable()
		}
		saveExpandedContainers()
	}

	func collapseAllFolders() {
		Self.logger.debug("SceneCoordinator: collapseAllFolders")
		for sectionNode in treeController.rootNode.childNodes {
			for topLevelNode in sectionNode.childNodes {
				if topLevelNode.representedObject is Folder || topLevelNode.representedObject is FavoriteFeedsFolder {
					unmarkExpanded(topLevelNode)
				}
			}
		}
		rebuildBackingStores { [weak self] in
			self?.mainFeedCollectionViewController.refreshVisibleDisclosureStates()
			self?.clearTimelineIfNoLongerAvailable()
		}
		saveExpandedContainers()
	}

	func mainFeedIndexPathForCurrentTimeline() -> IndexPath? {
		guard let node = treeController.rootNode.descendantNodeRepresentingObject(timelineFeed as AnyObject) else {
			return nil
		}
		return indexPathFor(node)
	}

	func selectFeed(_ sidebarItem: SidebarItem?, animations: Animations = [], deselectArticle: Bool = true, completion: (() -> Void)? = nil) {
		let indexPath: IndexPath? = {
			if let sidebarItem, let indexPath = indexPathFor(sidebarItem as AnyObject) {
				return indexPath
			} else {
				return nil
			}
		}()
		selectSidebarItem(indexPath: indexPath, animations: animations, deselectArticle: deselectArticle, completion: completion)
		updateNavigationBarSubtitles(nil)
	}

	func selectSidebarItem(indexPath: IndexPath?, animations: Animations = [], deselectArticle: Bool = true, completion: (() -> Void)? = nil) {
		Self.logger.debug("SceneCoordinator: selectSidebarItem")

		// Compare by feed identity, not indexPath — indexPath can change when feeds are added/removed
		var tappedFeed: AnyObject?
		if let indexPath {
			tappedFeed = nodeFor(indexPath)?.representedObject as AnyObject?
		}
		guard tappedFeed !== timelineFeed as AnyObject? else {
			// Same feed — just make sure the timeline is showing.
			if indexPath != nil {
				rootSplitViewController.showColumn(.supplementary)
			}
			completion?()
			return
		}
		videoPlaybackArticles.removeAll()

		currentFeedIndexPath = indexPath
		mainFeedCollectionViewController.updateFeedSelection(animations: animations)

		if deselectArticle {
			selectArticle(nil)
		}

		if let ip = indexPath, let node = nodeFor(ip), let sidebarItem = node.representedObject as? SidebarItem {

			self.activityManager.selecting(sidebarItem: sidebarItem)
			self.rootSplitViewController.showColumn(.supplementary)
			setTimelineFeed(sidebarItem, animated: false) {
				if self.isReadFeedsFiltered {
					self.rebuildBackingStores()
				}
				AppDefaults.shared.selectedSidebarItem = sidebarItem.sidebarItemID
				completion?()
			}

		} else {

			setTimelineFeed(nil, animated: false) {
				if self.isReadFeedsFiltered {
					self.rebuildBackingStores()
				}
				self.activityManager.invalidateSelecting()
				self.rootSplitViewController.showColumn(.primary)
				AppDefaults.shared.selectedSidebarItem = nil
				completion?()
			}

		}
		updateNavigationBarSubtitles(nil)
	}

	func selectPrevFeed() {
		if let indexPath = prevFeedIndexPath {
			selectSidebarItem(indexPath: indexPath, animations: [.navigation, .scroll])
		}
	}

	func selectNextFeed() {
		if let indexPath = nextFeedIndexPath {
			selectSidebarItem(indexPath: indexPath, animations: [.navigation, .scroll])
		}
	}

	func selectTodayFeed(completion: (() -> Void)? = nil) {
		markExpanded(SmartFeedsController.shared)
		self.ensureFeedIsAvailableToSelect(SmartFeedsController.shared.todayFeed) {
			self.selectFeed(SmartFeedsController.shared.todayFeed, animations: [.navigation, .scroll], completion: completion)
		}
	}

	func selectAllUnreadFeed(completion: (() -> Void)? = nil) {
		markExpanded(SmartFeedsController.shared)
		self.ensureFeedIsAvailableToSelect(SmartFeedsController.shared.unreadFeed) {
			self.selectFeed(SmartFeedsController.shared.unreadFeed, animations: [.navigation, .scroll], completion: completion)
		}
	}

	func selectStarredFeed(completion: (() -> Void)? = nil) {
		markExpanded(SmartFeedsController.shared)
		self.ensureFeedIsAvailableToSelect(SmartFeedsController.shared.starredFeed) {
			self.selectFeed(SmartFeedsController.shared.starredFeed, animations: [.navigation, .scroll], completion: completion)
		}
	}

	func toggleFavorite(for feed: Feed) {
		if !FavoriteFeedsController.shared.isFavorite(feed) {
			markExpanded(FavoriteFeedsController.shared)
		}
		FavoriteFeedsController.shared.toggle(feed)
	}

	func toggleFavorite(_ feed: Feed, in folder: FavoriteFeedsFolder) {
		markExpanded(FavoriteFeedsController.shared)
		markExpanded(folder)
		FavoriteFeedsController.shared.toggle(feed, in: folder)
	}

	func favorite(_ feed: Feed, to folder: FavoriteFeedsFolder?, discloseFolder: Bool = false) {
		markExpanded(FavoriteFeedsController.shared)
		if discloseFolder {
			if let folder, folder.isUserFolder {
				markExpanded(folder)
			} else {
				markExpanded(FavoriteFeedsController.shared.ungroupedFolder)
			}
		}
		FavoriteFeedsController.shared.add(feed, to: folder)
	}

	func unfavorite(_ alias: FavoriteFeedAlias) {
		FavoriteFeedsController.shared.remove(alias)
	}

	func createFavoriteFolder(named name: String) -> FavoriteFeedsFolder {
		markExpanded(FavoriteFeedsController.shared)
		return FavoriteFeedsController.shared.createFolder(named: name)
	}

	func renameFavoriteFolder(_ folder: FavoriteFeedsFolder, to name: String) {
		FavoriteFeedsController.shared.rename(folder, to: name)
	}

	func deleteFavoriteFolder(_ folder: FavoriteFeedsFolder) {
		FavoriteFeedsController.shared.deleteFolder(folder)
	}

	func moveFavorite(_ alias: FavoriteFeedAlias, to folder: FavoriteFeedsFolder?, discloseFolder: Bool = true) {
		markExpanded(FavoriteFeedsController.shared)
		if discloseFolder {
			if let folder, folder.isUserFolder {
				markExpanded(folder)
			} else {
				markExpanded(FavoriteFeedsController.shared.ungroupedFolder)
			}
		}
		FavoriteFeedsController.shared.move(alias, to: folder)
	}

	var videoPlayerPresenter: UIViewController? {
		var presenter: UIViewController = rootSplitViewController
		while let presentedViewController = presenter.presentedViewController {
			presenter = presentedViewController
		}
		return presenter
	}

	func selectArticle(_ article: Article?, animations: Animations = [], isShowingExtractedArticle: Bool? = nil, articleWindowScrollY: Int? = nil) {
		if article == currentArticle {
			if article != nil {
				rootSplitViewController.show(.secondary)
			}
			return
		}

		currentArticle = article
		activityManager.reading(feed: timelineFeed, article: article)

		if article == nil {
			isArticleViewControllerPending = false
			articleViewController?.article = nil
			rootSplitViewController.showColumn(.supplementary)
			mainTimelineViewController?.updateArticleSelection(animations: animations)
			return
		}

		if !isNavigationDisabled, rootSplitViewController.isCollapsed, !isArticleViewControllerShowing {
			// A push will follow — set to false in ArticleViewController.viewDidAppear.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/5417>
			isArticleViewControllerPending = true
		}

		rootSplitViewController.showColumn(.secondary)
		mainTimelineViewController?.didPushArticleViewController = true

		// Mark article as read before navigating to it, so the read status does not flash unread/read on display
		markArticles(Set([article!]), statusKey: .read, flag: true)

		mainTimelineViewController?.updateArticleSelection(animations: animations)
		articleViewController?.article = article
		if let isShowingExtractedArticle = isShowingExtractedArticle, let articleWindowScrollY = articleWindowScrollY {
			articleViewController?.restoreScrollPosition = (isShowingExtractedArticle, articleWindowScrollY)
		}
	}

	func beginSearching() {
		isSearching = true
		preSearchTimelineFeed = timelineFeed
		savedSearchArticles = articles
		savedSearchArticleIDs = Set(articles.map { $0.articleID })
		setTimelineFeed(nil, animated: true)
		selectArticle(nil)
	}

	func endSearching() {
		if let oldTimelineFeed = preSearchTimelineFeed {
			emptyTheTimeline()
			timelineFeed = oldTimelineFeed
			mainTimelineViewController?.reinitializeArticles(resetScroll: true)
			replaceArticles(with: savedSearchArticles!, animated: true)
		} else {
			setTimelineFeed(nil, animated: true)
		}

		lastSearchString = ""
		lastSearchScope = nil
		preSearchTimelineFeed = nil
		savedSearchArticleIDs = nil
		savedSearchArticles = nil
		isSearching = false
		selectArticle(nil)
		mainTimelineViewController?.focus()
	}

	func searchArticles(_ searchString: String, _ searchScope: SearchScope) {

		guard isSearching else {
			return
		}

		if !searchString.containsCJKCharacters && searchString.count < 3 {
			setTimelineFeed(nil, animated: true)
			return
		}

		if searchString != lastSearchString || searchScope != lastSearchScope {

			switch searchScope {
			case .global:
				setTimelineFeed(SmartFeed(delegate: SearchFeedDelegate(searchString: searchString)), animated: true)
			case .timeline:
				setTimelineFeed(SmartFeed(delegate: SearchTimelineFeedDelegate(searchString: searchString, articleIDs: savedSearchArticleIDs!)), animated: true)
			case .feeds:
				return
			}

			lastSearchString = searchString
			lastSearchScope = searchScope
		}

	}

	func searchFeeds(byAuthor searchString: String) -> [Feed] {
		let query = searchString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return [] }
		let feeds = AccountManager.shared.sortedActiveAccounts.flatMap { $0.flattenedFeeds() }
		let uniqueFeeds = Dictionary(uniqueKeysWithValues: feeds.map { ("\($0.accountID):\($0.feedID)", $0) }).values
		return uniqueFeeds
			.filter { feed in
				feed.authors?.contains { author in
					guard let name = author.name else { return false }
					return name.localizedCaseInsensitiveContains(query)
				} == true
			}
			.sorted { $0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending }
	}

	func findPrevArticle(_ article: Article) -> Article? {
		guard let index = articles.firstIndex(where: { $0.articleID == article.articleID && $0.accountID == article.accountID }), index > 0 else {
			return nil
		}
		return articles[index - 1]
	}

	func findNextArticle(_ article: Article) -> Article? {
		guard let index = articles.firstIndex(where: { $0.articleID == article.articleID && $0.accountID == article.accountID }), index + 1 < articles.count else {
			return nil
		}
		return articles[index + 1]
	}

	func selectPrevArticle() {
		if let article = prevArticle {
			selectArticle(article, animations: [.navigation, .scroll])
		}
	}

	func selectNextArticle() {
		if let article = nextArticle {
			selectArticle(article, animations: [.navigation, .scroll])
		}
	}

	func selectPrevUnread() {

		// This should never happen, but I don’t want to risk throwing us
		// into an infinite loop searching for an unread that isn’t there.
		if AccountManager.shared.unreadCount < 1 {
			return
		}

		if selectPrevUnreadArticleInTimeline() {
			return
		}

		// Disable navigation only while hopping to another feed, so the intermediate
		// timeline isn’t pushed. Selecting within the current timeline must be able to
		// push the article view controller.
		isNavigationDisabled = true
		defer {
			isNavigationDisabled = false
		}

		selectPrevUnreadFeedFetcher()
		selectPrevUnreadArticleInTimeline()
	}

	func selectNextUnread() {

		// Flush coalesced unread-count updates so folder counts are current.
		CoalescingQueue.standard.performCallsImmediately()

		// This should never happen, but I don’t want to risk throwing us
		// into an infinite loop searching for an unread that isn’t there.
		if AccountManager.shared.unreadCount < 1 {
			return
		}

		if selectNextUnreadArticleInTimeline() {
			return
		}

		// Disable navigation only while hopping to another feed, so the intermediate
		// timeline isn’t pushed. Selecting within the current timeline must be able to
		// push the article view controller.
		isNavigationDisabled = true
		defer {
			isNavigationDisabled = false
		}

		if self.isSearching {
			self.mainTimelineViewController?.hideSearch()
		}

		selectNextUnreadFeed {
			// The supplementary push from selectSidebarItem may still be animating when
			// this completion fires — the async data fetch can outrun the push animation
			// in compact mode. Wait for the in-flight transition before pushing the
			// article view controller, or UIKit aborts with NSInternalInconsistencyException
			// from -[UINavigationController pushViewController:transition:forceImmediate:].
			if let coordinator = self.mainTimelineViewController?.navigationController?.transitionCoordinator {
				coordinator.animate(alongsideTransition: nil) { _ in
					self.selectNextUnreadArticleInTimeline()
				}
			} else {
				self.selectNextUnreadArticleInTimeline()
			}
		}
	}

	func scrollOrGoToNextUnread() {
		if articleViewController?.canScrollDown() ?? false {
			articleViewController?.scrollPageDown()
		} else {
			selectNextUnread()
		}
	}

	func scrollUp() {
		if articleViewController?.canScrollUp() ?? false {
			articleViewController?.scrollPageUp()
		}
	}

	func markAllAsRead(_ articles: [Article], completion: (() -> Void)? = nil) {
		markArticlesWithUndo(articles, statusKey: .read, flag: true, completion: completion)
	}

	// The marked articles are in the timeline. Remove them. Undo brings them back.
	func markAllAsReadInTimeline(_ articlesToMark: [Article], completion: (() -> Void)? = nil) {
		let articleIDs = Set(articlesToMark.articleIDs())

		markArticlesWithUndo(articlesToMark, statusKey: .read, flag: true, completion: completion) { [weak self] markedAsRead in
			if markedAsRead {
				self?.removeArticlesHiddenByReadFilter(among: articleIDs)
			} else {
				self?.restoreArticlesToTimeline()
			}
		}
	}

	// From the sidebar: clean up only when the marked item is the one the timeline is showing.
	func markAllAsRead(_ articlesToMark: [Article], in sidebarItem: SidebarItem, completion: (() -> Void)? = nil) {
		if sidebarItem.sidebarItemID == timelineFeed?.sidebarItemID {
			markAllAsReadInTimeline(articlesToMark, completion: completion)
		} else {
			markAllAsRead(articlesToMark, completion: completion)
		}
	}

	func markAsReadAndShowSidebar(_ articlesToMark: [Article], completion: (() -> Void)? = nil) {
		markAllAsReadInTimeline(articlesToMark) {
			self.rootSplitViewController.preferredDisplayMode = .twoBesideSecondary
			self.rootSplitViewController.showColumn(.primary, bypassDisplayModeRestriction: true)
			completion?()
		}
	}

	func canMarkAboveAsRead(for article: Article) -> Bool {
		let articlesAboveArray = articles.articlesAbove(article: article)
		return articlesAboveArray.canMarkAllAsRead()
	}

	func markAboveAsRead() {
		guard let currentArticle = currentArticle else {
			return
		}

		markAboveAsRead(currentArticle)
	}

	func markAboveAsRead(_ article: Article) {
		let articlesAboveArray = articles.articlesAbove(article: article)
		markAboveAsReadAndRemoveFromTimeline(articlesAboveArray)
	}

	func markAboveAndIncludingAsRead(_ article: Article) {
		let articlesAboveArray = articles.articlesAboveAndIncluding(article: article)
		markAboveAsReadAndRemoveFromTimeline(articlesAboveArray)
	}

	func canMarkBelowAsRead(for article: Article) -> Bool {
		let articleBelowArray = articles.articlesBelow(article: article)
		return articleBelowArray.canMarkAllAsRead()
	}

	func markBelowAsRead() {
		guard let currentArticle = currentArticle else {
			return
		}

		markBelowAsRead(currentArticle)
	}

	func markBelowAsRead(_ article: Article) {
		let articleBelowArray = articles.articlesBelow(article: article)
		markAllAsReadInTimeline(articleBelowArray)
	}

	func markAllAsUnread(_ articles: [Article], completion: (() -> Void)? = nil) {
		markArticlesWithUndo(articles, statusKey: .read, flag: false, completion: completion)
	}

	func canMarkAboveAsUnread(for article: Article) -> Bool {
		let articlesAboveArray = articles.articlesAbove(article: article)
		return articlesAboveArray.anyArticleIsReadAndCanMarkUnread()
	}

	func markAboveAsUnread() {
		guard let currentArticle = currentArticle else {
			return
		}

		markAboveAsUnread(currentArticle)
	}

	func markAboveAsUnread(_ article: Article) {
		let articlesAboveArray = articles.articlesAbove(article: article)
		markAllAsUnread(articlesAboveArray)
	}

	func canMarkBelowAsUnread(for article: Article) -> Bool {
		let articleBelowArray = articles.articlesBelow(article: article)
		return articleBelowArray.anyArticleIsReadAndCanMarkUnread()
	}

	func markBelowAsUnread() {
		guard let currentArticle = currentArticle else {
			return
		}

		markBelowAsUnread(currentArticle)
	}

	func markBelowAsUnread(_ article: Article) {
		let articleBelowArray = articles.articlesBelow(article: article)
		markAllAsUnread(articleBelowArray)
	}

	func markAsReadForCurrentArticle() {
		if let article = currentArticle {
			markArticlesWithUndo([article], statusKey: .read, flag: true)
		}
	}

	func markAsUnreadForCurrentArticle() {
		if let article = currentArticle {
			markArticlesWithUndo([article], statusKey: .read, flag: false)
		}
	}

	func toggleReadForCurrentArticle() {
		if let article = currentArticle {
			toggleRead(article)
		}
	}

	func toggleReaderViewForCurrentArticle() {
		guard currentArticle != nil else {
			return
		}
		articleViewController?.toggleReaderView(nil)
	}

	func toggleRead(_ article: Article) {
		guard !article.status.read || article.isAvailableToMarkUnread else {
			return
		}
		markArticlesWithUndo([article], statusKey: .read, flag: !article.status.read)
	}

	func toggleStarredForCurrentArticle() {
		if let article = currentArticle {
			toggleStar(article)
		}
	}

	func toggleStar(_ article: Article) {
		markArticlesWithUndo([article], statusKey: .starred, flag: !article.status.starred)
	}

	func timelineFeedIsEqualTo(_ feed: Feed) -> Bool {
		if let timelineFeed = timelineFeed as? Feed {
			return timelineFeed == feed
		}
		if let alias = timelineFeed as? FavoriteFeedAlias {
			return alias.key == FavoriteFeedKey(feed: feed)
		}
		return false
	}

	func discloseFeed(_ feed: Feed, initialLoad: Bool = false, animations: Animations = [], completion: (() -> Void)? = nil) {
		Self.logger.debug("SceneCoordinator: discloseFeed")

		if isSearching {
			mainTimelineViewController?.hideSearch()
		}

		if isFavoritesTimelineContext, FavoriteFeedsController.shared.isFavorite(feed) {
			discloseFavoriteFeed(feed, initialLoad: initialLoad, animations: animations, completion: completion)
			return
		}

		discloseAccountFeed(feed, initialLoad: initialLoad, animations: animations, completion: completion)
	}

	func showStatusBar() {
		prefersStatusBarHidden = false
		UIView.animate(withDuration: 0.15) {
			self.rootSplitViewController.setNeedsStatusBarAppearanceUpdate()
		}
	}

	func hideStatusBar() {
		prefersStatusBarHidden = true
		UIView.animate(withDuration: 0.15) {
			self.rootSplitViewController.setNeedsStatusBarAppearanceUpdate()
		}
	}

	func showSettings(scrollToArticlesSection: Bool = false) {
		let settingsNavController = UIStoryboard.settings.instantiateInitialViewController() as! UINavigationController
		let settingsViewController = settingsNavController.topViewController as! SettingsViewController
		settingsViewController.scrollToArticlesSection = scrollToArticlesSection
		settingsNavController.modalPresentationStyle = .formSheet
		settingsViewController.presentingParentController = rootSplitViewController
		rootSplitViewController.present(settingsNavController, animated: true)
	}

	func showCurrentActivity() {
		let hostingController = UIHostingController(rootView: NavigationStack { CurrentActivityView() })
		if let sheet = hostingController.sheetPresentationController {
			sheet.detents = [.medium(), .large()]
			sheet.prefersGrabberVisible = true
		}
		rootSplitViewController.present(hostingController, animated: true)
	}

	func showAccountInspector(for account: Account) {
		let accountInspectorNavController =
			UIStoryboard.inspector.instantiateViewController(identifier: "AccountInspectorNavigationViewController") as! UINavigationController
		let accountInspectorController = accountInspectorNavController.topViewController as! AccountInspectorViewController
		accountInspectorNavController.modalPresentationStyle = .formSheet
		accountInspectorNavController.preferredContentSize = AccountInspectorViewController.preferredContentSizeForFormSheetDisplay
		accountInspectorController.isModal = true
		accountInspectorController.account = account
		rootSplitViewController.present(accountInspectorNavController, animated: true)
	}

	func showNotificationInspector(for account: Account) {
		let hostingController = UIHostingController(rootView: AccountNotificationInspectorView(account: account))
		hostingController.modalPresentationStyle = .formSheet
		rootSplitViewController.present(hostingController, animated: true)
	}

	func showFeedInspector() {
		guard let feed = (timelineFeed as? Feed)
			?? (timelineFeed as? FavoriteFeedAlias)?.feed
			?? currentArticle?.feed else {
			return
		}
		showFeedInspector(for: feed)
	}

	func showFeedInspector(for feed: Feed) {
		let feedInspectorNavController =
			UIStoryboard.inspector.instantiateViewController(identifier: "FeedInspectorNavigationViewController") as! UINavigationController
		let feedInspectorController = feedInspectorNavController.topViewController as! FeedInspectorViewController
		feedInspectorNavController.modalPresentationStyle = .formSheet
		feedInspectorNavController.preferredContentSize = FeedInspectorViewController.preferredContentSizeForFormSheetDisplay
		feedInspectorController.feed = feed
		rootSplitViewController.present(feedInspectorNavController, animated: true)
	}

	func showAddFeed(initialFeed: String? = nil, initialFeedName: String? = nil) {

		// The sheet appears over the current screen, so the feed and article selection stay as they are.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4352>

		let addFeedView = AddFeedView(initialFeed: initialFeed, initialFeedName: initialFeedName)
		let hostingController = UIHostingController(rootView: addFeedView)
		hostingController.modalPresentationStyle = .formSheet
		hostingController.preferredContentSize = AddFeedView.preferredContentSizeForFormSheetDisplay

		// Presenting over an active nav-bar-hosted search bar crashes inside UIKit.
		guard let mainTimelineViewController else {
			rootSplitViewController.present(hostingController, animated: true)
			return
		}
		mainTimelineViewController.hideSearch {
			self.rootSplitViewController.present(hostingController, animated: true)
		}
	}

	func showAddFolder() {
		let hostingController = UIHostingController(rootView: AddFolderView())
		hostingController.modalPresentationStyle = .formSheet
		hostingController.preferredContentSize = AddFolderView.preferredContentSizeForFormSheetDisplay
		mainFeedCollectionViewController.present(hostingController, animated: true)
	}

	func showFullScreenImage(image: UIImage, imageTitle: String?, resourceURL: String?, transition: ImageTransition, saveAllImagesHandler: (() -> Void)? = nil) {
		let imageVC = UIStoryboard.main.instantiateController(ofType: ImageViewController.self)
		imageVC.image = image
		imageVC.imageTitle = imageTitle
		imageVC.resourceURL = resourceURL
		imageVC.transition = transition
		imageVC.saveAllImagesHandler = saveAllImagesHandler
		let navController = UINavigationController(rootViewController: imageVC)
		navController.modalPresentationStyle = .currentContext
		navController.transitioningDelegate = transition
		rootSplitViewController.present(navController, animated: true)
	}

	func homePageURLForFeed(_ indexPath: IndexPath) -> URL? {
		guard let node = nodeFor(indexPath),
			let feed = node.representedObject as? Feed,
			let homePageURL = feed.homePageURL,
			let url = URL(string: homePageURL) else {
				return nil
		}
		return url
	}

	func showBrowserForCurrentFeed() {
		if let ip = currentFeedIndexPath, let url = homePageURLForFeed(ip) {
			UIApplication.shared.open(url, options: [:])
		}
	}

	func showBrowserForArticle(_ article: Article) {
		guard let url = article.preferredURL else {
			return
		}
		UIApplication.shared.open(url, options: [:])
	}

	func showBrowserForCurrentArticle() {
		guard let url = currentArticle?.preferredURL else {
			return
		}
		UIApplication.shared.open(url, options: [:])
	}

	func showInAppBrowser() {
		if currentArticle != nil {
			articleViewController?.openInAppBrowser()
		} else {
			mainFeedCollectionViewController.openInAppBrowser()
		}
	}

	func beganBrowsing(url: URL) {
		activityManager.browsing(url: url)
	}

	func endedBrowsing() {
		activityManager.invalidateBrowsing()
	}

	func navigateToFeeds() {
		if !isRootSplitCollapsed {
			// In three-pane mode, focusing the sidebar deselects the article.
			// In collapsed mode the pop below drives cleanup via navigationController(_:didShow:).
			selectArticle(nil)
		}
		revealColumn(.primary) { [weak self] in
			self?.mainFeedCollectionViewController?.focus()
		}
	}

	func navigateToTimeline() {
		// Only auto-select the first article in three-pane mode, where it populates the
		// detail pane without hiding the timeline.
		let displayMode = rootSplitViewController.displayMode
		let isThreePane = !isRootSplitCollapsed && displayMode != .oneBesideSecondary && displayMode != .secondaryOnly
		if isThreePane && currentArticle == nil && articles.count > 0 {
			selectArticle(articles[0])
		}
		revealColumn(.supplementary) { [weak self] in
			self?.mainTimelineViewController?.focus()
		}
	}

	func navigateToDetail() {
		// If nothing is selected, open the first article so right-arrow reveals the detail even in
		// collapsed and two-pane layouts. selectArticle reveals/pushes the detail column itself.
		if currentArticle == nil {
			guard articles.count > 0 else {
				return
			}
			selectArticle(articles[0])
		}
		revealColumn(.secondary) { [weak self] in
			self?.articleViewController?.focus()
		}
	}

	func selectArticleInCurrentFeed(_ articleID: String, isShowingExtractedArticle: Bool? = nil, articleWindowScrollY: Int? = nil) {
		if let article = self.articles.first(where: { $0.articleID == articleID }) {
			self.selectArticle(article, isShowingExtractedArticle: isShowingExtractedArticle, articleWindowScrollY: articleWindowScrollY)
		}
	}

	func importTheme(filename: String) {
		do {
			try ArticleThemeImporter.importTheme(controller: rootSplitViewController, url: URL(fileURLWithPath: filename))
		} catch {
			NotificationCenter.default.post(name: .didFailToImportThemeWithError, object: nil, userInfo: ["error": error])
		}

	}

	/// This will dismiss the foremost view controller if the user
	/// has launched from an external action (i.e., a widget tap, or
	/// selecting an article via a notification).
	///
	/// The dismiss is only applicable if the view controller is a
	/// `SFSafariViewController` or `SettingsViewController`,
	/// otherwise, this function does nothing.
	func dismissIfLaunchingFromExternalAction() {
		guard let presentedController = mainFeedCollectionViewController.presentedViewController else {
			return
		}

		if presentedController.isKind(of: SFSafariViewController.self) {
			presentedController.dismiss(animated: true, completion: nil)
		}
		guard let settings = presentedController.children.first as? SettingsViewController else {
			return
		}
		settings.dismiss(animated: true, completion: nil)
	}

}

// MARK: UISplitViewControllerDelegate

extension SceneCoordinator: UISplitViewControllerDelegate {

	func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
		switch proposedTopColumn {
		case .supplementary:
			if currentFeedIndexPath != nil {
				return .supplementary
			} else {
				return .primary
			}
		case .secondary:
			if currentArticle != nil {
				return .secondary
			} else {
				if currentFeedIndexPath != nil {
					return .supplementary
				} else {
					return .primary
				}
			}
		default:
			return .primary
		}
	}

	func splitViewController(_ svc: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
		AppDefaults.shared.splitViewPreferredDisplayMode = displayMode.rawValue
		mainTimelineViewController?.updateToolbarProgressView(for: displayMode)
	}

	func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
		mainTimelineViewController?.splitViewStateDidChange()
	}

	func splitViewControllerDidExpand(_ svc: UISplitViewController) {
		mainTimelineViewController?.splitViewStateDidChange()
	}

}

// MARK: UINavigationControllerDelegate

extension SceneCoordinator: UINavigationControllerDelegate {

	func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
		guard UIApplication.shared.applicationState != .background else {
			return
		}

		guard rootSplitViewController.isCollapsed else {
			return
		}

		// If we are showing the Feeds and only the feeds start clearing stuff
		if viewController === mainFeedCollectionViewController && !isTimelineViewControllerPending {
			activityManager.invalidateCurrentActivities()
			selectFeed(nil, animations: [.scroll, .select, .navigation])
			return
		}

		// If we are using a phone and navigate away from the detail, clear up the article resources (including activity).
		// Don’t clear it if we have pushed an ArticleViewController, but don’t yet see it on the navigation stack.
		// This happens when we are going to the next unread and we need to grab another timeline to continue.  The
		// ArticleViewController will be pushed, but we will briefly show the Timeline.  Don’t clear things out when that happens.
		// Also skip during state restoration so we don’t clear the restored article.
		if viewController === mainTimelineViewController && rootSplitViewController.isCollapsed && !isArticleViewControllerPending && !isRestoringState {
			currentArticle = nil
			mainTimelineViewController?.updateArticleSelection(animations: [.scroll, .select, .navigation])
			activityManager.invalidateReading()

			// Restore any bars hidden by the article controller
			showStatusBar()
			navigationController.setNavigationBarHidden(false, animated: true)
			navigationController.setToolbarHidden(false, animated: true)
			return
		}
	}

}

// MARK: Private

private extension SceneCoordinator {

	// Reveal the destination column, then focus it. Works across collapsed (iPhone),
	// two-pane, and three-pane layouts, so arrow-key navigation isn’t limited to the
	// case where all columns are already visible.
	// <https://github.com/Ranchero-Software/NetNewsWire/issues/3138>
	func revealColumn(_ column: UISplitViewController.Column, thenFocus focus: @escaping @MainActor () -> Void) {
		if isRootSplitCollapsed {
			revealColumnInCollapsedMode(column, thenFocus: focus)
		} else {
			rootSplitViewController.showColumn(column, bypassDisplayModeRestriction: true)
			// Defer focus so becomeFirstResponder targets the revealed column, not the outgoing one.
			Task { @MainActor in
				focus()
			}
		}
	}

	func revealColumnInCollapsedMode(_ column: UISplitViewController.Column, thenFocus focus: @escaping @MainActor () -> Void) {
		guard !isNavigationDisabled, let navController = mainFeedCollectionViewController.navigationController else {
			return
		}
		let targetViewController: UIViewController?
		switch column {
		case .primary:
			targetViewController = mainFeedCollectionViewController
		case .supplementary:
			targetViewController = mainTimelineViewController
		case .secondary:
			targetViewController = articleViewController
		default:
			targetViewController = nil
		}
		guard let targetViewController else {
			return
		}

		if navController.topViewController === targetViewController {
			// Already on the destination column — just move focus.
			Task { @MainActor in
				focus()
			}
		} else if navController.viewControllers.contains(targetViewController) {
			// Backward navigation. The pop fires navigationController(_:didShow:), which performs
			// the existing collapsed-mode cleanup. Don’t duplicate that here.
			navController.popToViewController(targetViewController, animated: true)
			focusWhenTransitionCompletes(in: navController, thenFocus: focus)
		} else {
			// Forward navigation — push the destination column onto the stack.
			rootSplitViewController.showColumn(column, bypassDisplayModeRestriction: true)
			focusWhenTransitionCompletes(in: navController, thenFocus: focus)
		}
	}

	// Focus once the navigation transition finishes, so becomeFirstResponder lands on the
	// revealed column rather than firing mid-animation. Falls back to the next runloop.
	func focusWhenTransitionCompletes(in navController: UINavigationController, thenFocus focus: @escaping @MainActor () -> Void) {
		if let transitionCoordinator = navController.transitionCoordinator {
			transitionCoordinator.animate(alongsideTransition: nil) { _ in
				focus()
			}
		} else {
			Task { @MainActor in
				focus()
			}
		}
	}

	func markArticlesWithUndo(_ articles: [Article], statusKey: ArticleStatus.Key, flag: Bool, statusChangeHandler: ((Set<Article>, ArticleStatus.Key, Bool) -> Void)? = nil, completion: (() -> Void)? = nil, didMark: ((Bool) -> Void)? = nil) {
		guard let undoManager = undoManager,
			  let markReadCommand = MarkStatusCommand(initialArticles: articles, statusKey: statusKey, flag: flag, undoManager: undoManager, statusChangeHandler: statusChangeHandler, completion: completion, didMark: didMark) else {
			completion?()
			return
		}
		runCommand(markReadCommand)
	}

	func markAboveAsReadAndRemoveFromTimeline(_ articles: [Article]) {
		let removalCandidates = Set(articles)
		let sidebarItemID = timelineFeed?.sidebarItemID
		markArticlesWithUndo(articles, statusKey: .read, flag: true, statusChangeHandler: { [weak self] _, statusKey, flag in
			guard let self, self.timelineFeed?.sidebarItemID == sidebarItemID else { return }
			self.applyExplicitAboveReadStatusChange(removalCandidates, statusKey: statusKey, flag: flag)
		})
	}

	func applyExplicitAboveReadStatusChange(_ removalCandidates: Set<Article>, statusKey: ArticleStatus.Key, flag: Bool) {
		guard statusKey == .read, isReadArticlesFiltered else {
			return
		}

		if flag {
			let articleIDsByAccount = Dictionary(grouping: removalCandidates, by: \.accountID).mapValues { Set($0.map(\.articleID)) }
			let remaining = articles.filter { article in
				guard article.status.read,
					  let articleIDs = articleIDsByAccount[article.accountID],
					  articleIDs.contains(article.articleID) else {
					return true
				}
				return false
			}

			let removedCount = articles.count - remaining.count
			if removedCount > 0 {
				NotificationActionLog.log(.info, operation: "Timeline explicit hide-read", message: "Removed \(removedCount) articles marked above as read from timeline")
				replaceArticles(with: remaining, animated: true, resetScroll: true)
			}
		} else {
			mainTimelineViewController?.cancelPendingScrollReset()
			fetchAndMergeArticlesAsync(animated: true) {
				self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
			}
		}
	}

	func updateUnreadCount() {
		var count = 0
		for article in articles {
			if !article.status.read {
				count += 1
			}
		}
		if count != timelineUnreadCount {
			timelineUnreadCount = count
		}
	}

	func rebuildArticleDictionaries() {
		var idDictionary = [String: Article]()

		for article in articles {
			idDictionary[article.articleID] = article
		}

		_idToArticleDictionary = idDictionary
		articleDictionaryNeedsUpdate = false
	}

	func ensureFeedIsAvailableToSelect(_ sidebarItem: SidebarItem, completion: @escaping () -> Void) {
		Self.logger.debug("SceneCoordinator: ensureFeedIsAvailableToSelect")

		addToFilterExceptionsIfNecessary(sidebarItem)
		addVisibleSidebarItemsToFilterExceptions()

		rebuildBackingStores(completion: {
			self.treeControllerDelegate.resetFilterExceptions()
			completion()
		})
	}

	func addToFilterExceptionsIfNecessary(_ sidebarItem: SidebarItem?) {
		if isReadFeedsFiltered, let sidebarItemID = sidebarItem?.sidebarItemID {
			if let alias = sidebarItem as? FavoriteFeedAlias {
				treeControllerDelegate.addFilterException(sidebarItemID)
				addParentFolderToFilterExceptions(alias)
			} else if sidebarItem is PseudoFeed {
				treeControllerDelegate.addFilterException(sidebarItemID)
			} else if let folderFeed = sidebarItem as? Folder {
				if folderFeed.account?.existingFolder(withID: folderFeed.folderID) != nil {
					treeControllerDelegate.addFilterException(sidebarItemID)
				}
			} else if let feed = sidebarItem as? Feed {
				if feed.account?.existingFeed(withFeedID: feed.feedID) != nil {
					treeControllerDelegate.addFilterException(sidebarItemID)
					addParentFolderToFilterExceptions(feed)
				}
			}
		}
	}

	func addParentFolderToFilterExceptions(_ sidebarItem: SidebarItem) {
		guard let node = treeController.rootNode.descendantNodeRepresentingObject(sidebarItem as AnyObject) else {
			return
		}

		if let folder = node.parent?.representedObject as? Folder,
		   let folderSidebarItemID = folder.sidebarItemID {
			treeControllerDelegate.addFilterException(folderSidebarItemID)
			return
		}

		if let folder = node.parent?.representedObject as? FavoriteFeedsFolder,
		   let folderSidebarItemID = folder.sidebarItemID {
			treeControllerDelegate.addFilterException(folderSidebarItemID)
		}
	}

	func addVisibleSidebarItemsToFilterExceptions() {
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot
		for sidebarItemNode in snapshot.itemIdentifiers {
			if let feed = sidebarItemNode.node.representedObject as? SidebarItem, let sidebarItemID = feed.sidebarItemID {
				treeControllerDelegate.addFilterException(sidebarItemID)
			}
		}
	}

	func queueRebuildBackingStores() {
		rebuildBackingStoresQueue.add(self, #selector(rebuildBackingStoresWithDefaults))
	}

	@objc func rebuildBackingStoresWithDefaults() {
		Self.logger.debug("SceneCoordinator: rebuildBackingStoresWithDefaults")

		rebuildBackingStores()
	}

	static var rebuildCount = 0

	func flushPendingFavoriteFeedsReload() {
		guard pendingFavoriteFeedsReload else {
			return
		}
		pendingFavoriteFeedsReload = false
		reloadFavoriteFeeds(deferIfContextMenuPresented: false)
	}

	func reloadFavoriteFeeds(deferIfContextMenuPresented: Bool) {
		if deferIfContextMenuPresented, isSidebarContextMenuPresented {
			pendingFavoriteFeedsReload = true
			return
		}

		let shouldRefreshTimeline = timelineFeed?.sidebarItemID == FavoriteFeedsController.shared.allFeed.sidebarItemID || timelineFeed is FavoriteFeedAlias || timelineFeed is FavoriteFeedsFolder
		if shouldRefreshTimeline {
			fetchAndMergeArticlesAsync(animated: true) {
				self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
				self.rebuildBackingStores {
					self.clearTimelineIfNoLongerAvailable()
				}
			}
		} else {
			rebuildBackingStores()
		}
	}

	func rebuildBackingStores(initialLoad: Bool = false, updateExpandedNodes: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
#if DEBUG
		if initialLoad {
			Self.logger.debug("SceneCoordinator: rebuildBackingStores: #\(Self.rebuildCount) initialLoad == true")
		} else {
			Self.logger.debug("SceneCoordinator: rebuildBackingStores: #\(Self.rebuildCount)")
		}
		Self.rebuildCount += 1
#endif

		addToFilterExceptionsIfNecessary(timelineFeed)
		treeController.rebuild()
		treeControllerDelegate.resetFilterExceptions()

		updateExpandedNodes?()

		lastExpandedContainers = expandedContainers

		let snapshot = createSidebarSnapshot()
		mainFeedCollectionViewController.applySnapshot(snapshot, animatingDifferences: !initialLoad) { [weak self] in
			guard let self else {
				return
			}
			// The data source reflects the new snapshot only after the apply
			// completes — recomputing earlier would read the old layout.
			if self.currentFeedIndexPath != nil {
				self.currentFeedIndexPath = self.indexPathFor(self.timelineFeed as AnyObject)
			}
			completion?()
		}
	}

	private func createSidebarSnapshot() -> NSDiffableDataSourceSnapshot<String, SidebarItemNode> {
		var snapshot = NSDiffableDataSourceSnapshot<String, SidebarItemNode>()

		for i in 0..<treeController.rootNode.numberOfChildNodes {
			let sectionNode = treeController.rootNode.childAtIndex(i)!
			let sectionID = sidebarSectionID(for: sectionNode)

			snapshot.appendSections([sectionID])

			if isExpanded(sectionNode) {
				var siNodes = [SidebarItemNode]()

				for node in sectionNode.childNodes {
					siNodes.append(SidebarItemNode(node))
					if isExpanded(node) {
						for child in node.childNodes {
							siNodes.append(SidebarItemNode(child))
						}
					}
				}

				snapshot.appendItems(siNodes, toSection: sectionID)
			}
		}

		return snapshot
	}

	func sidebarSectionID(for sectionNode: Node) -> String {
		if let account = sectionNode.representedObject as? Account {
			return account.accountID
		}
		if sectionNode.representedObject is FavoriteFeedsController {
			return FavoriteFeedsController.sectionID
		}
		return ""
	}

	func reconfigureSidebarItem(_ sidebarItem: SidebarItem) {
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot

		// Find all nodes that represent this sidebar item
		var nodesToReconfigure: [SidebarItemNode] = []
		for sidebarItemNode in snapshot.itemIdentifiers {
			if let nodeSidebarItem = sidebarItemNode.node.representedObject as? SidebarItem,
			   nodeSidebarItem.sidebarItemID == sidebarItem.sidebarItemID {
				nodesToReconfigure.append(sidebarItemNode)
			}
		}

		guard !nodesToReconfigure.isEmpty else {
			return
		}

		mainFeedCollectionViewController.reconfigureItems(nodesToReconfigure)
	}

	func sidebarContains(_ sidebarItem: SidebarItem) -> Bool {
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot
		for sidebarItemNode in snapshot.itemIdentifiers {
			if let nodeSidebarItem = sidebarItemNode.node.representedObject as? SidebarItem, nodeSidebarItem.sidebarItemID == sidebarItem.sidebarItemID {
				return true
			}
		}
		return false
	}

	func clearTimelineIfNoLongerAvailable() {
		if let feed = timelineFeed, !sidebarContains(feed) {
			selectFeed(nil, deselectArticle: true)
		}
	}

	var isFavoritesTimelineContext: Bool {
		timelineFeed is FavoriteFeedsAllFeed
			|| timelineFeed is FavoriteFeedsFolder
			|| timelineFeed is FavoriteFeedAlias
	}

	func preferredFavoriteFolder(for feed: Feed) -> FavoriteFeedsFolder? {
		if let folder = timelineFeed as? FavoriteFeedsFolder, folder.contains(feed) {
			return folder
		}
		if let folder = FavoriteFeedsController.shared.foldersContaining(feed).first {
			return folder
		}
		let ungrouped = FavoriteFeedsController.shared.ungroupedFolder
		return ungrouped.contains(feed) ? ungrouped : nil
	}

	func selectFavoriteAlias(_ alias: FavoriteFeedAlias, in folder: FavoriteFeedsFolder?, animations: Animations, completion: (() -> Void)?) {
		let indexPath: IndexPath?
		if let folder,
		   let node = treeController.rootNode.descendantNode(where: { node in
			   node.representedObject === alias && node.parent?.representedObject === folder
		   }) {
			indexPath = indexPathFor(node)
		} else {
			indexPath = indexPathFor(alias as AnyObject)
		}
		selectSidebarItem(indexPath: indexPath, animations: animations, completion: completion)
	}

	func discloseFavoriteFeed(_ feed: Feed, initialLoad: Bool, animations: Animations, completion: (() -> Void)?) {
		guard let alias = FavoriteFeedsController.shared.alias(for: feed) else {
			discloseAccountFeed(feed, initialLoad: initialLoad, animations: animations, completion: completion)
			return
		}

		markExpanded(FavoriteFeedsController.shared)
		let folder = preferredFavoriteFolder(for: feed)
		if let folder {
			markExpanded(folder)
		}
		if let aliasID = alias.sidebarItemID {
			treeControllerDelegate.addFilterException(aliasID)
		}
		if let folderID = folder?.sidebarItemID {
			treeControllerDelegate.addFilterException(folderID)
		}

		rebuildBackingStores(initialLoad: initialLoad, completion: {
			self.treeControllerDelegate.resetFilterExceptions()
			self.selectFeed(nil) {
				if self.rootSplitViewController.traitCollection.horizontalSizeClass == .compact {
					DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
						self.selectFavoriteAlias(alias, in: folder, animations: animations, completion: completion)
					}
				} else {
					self.selectFavoriteAlias(alias, in: folder, animations: animations, completion: completion)
				}
			}
		})
	}

	func discloseAccountFeed(_ feed: Feed, initialLoad: Bool, animations: Animations, completion: (() -> Void)?) {
		guard let account = feed.account else {
			completion?()
			return
		}

		let parentFolder = account.sortedFolders?.first(where: { $0.objectIsChild(feed) })

		markExpanded(account)
		if let parentFolder = parentFolder {
			markExpanded(parentFolder)
		}

		if let feedSidebarItemID = feed.sidebarItemID {
			treeControllerDelegate.addFilterException(feedSidebarItemID)
		}
		if let parentFolderSidebarItemID = parentFolder?.sidebarItemID {
			treeControllerDelegate.addFilterException(parentFolderSidebarItemID)
		}

		rebuildBackingStores(initialLoad: initialLoad, completion: {
			self.treeControllerDelegate.resetFilterExceptions()
			self.selectFeed(nil) {
				let ensureAndSelect: @MainActor () -> Void = {
					if self.isReadFeedsFiltered {
						self.ensureFeedIsAvailableToSelect(feed) {
							self.selectFeed(feed, animations: animations, completion: completion)
						}
					} else {
						self.selectFeed(feed, animations: animations, completion: completion)
					}
				}
				if self.rootSplitViewController.traitCollection.horizontalSizeClass == .compact {
					DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: ensureAndSelect)
				} else {
					ensureAndSelect()
				}
			}
		})
	}

	func indexPathFor(_ object: AnyObject) -> IndexPath? {
		guard let node = treeController.rootNode.descendantNodeRepresentingObject(object) else {
			return nil
		}
		return indexPathFor(node)
	}

	func setTimelineFeed(_ sidebarItem: SidebarItem?, animated: Bool, completion: (() -> Void)? = nil) {
		timelineFeed = sidebarItem

		refreshTimeline(for: .feedSelection, animated: animated) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: true)
			completion?()
		}
	}

	func updateShowNamesAndIcons() {

		if timelineFeed is Feed || timelineFeed is FavoriteFeedAlias {
			showFeedNames = {
				for article in articles {
					if !article.byline().isEmpty {
						return .byline
					}
				}
				return .none
			}()
		} else {
			showFeedNames = .feed
		}

		if showFeedNames == .feed {
			self.showIcons = true
			return
		}

		if showFeedNames == .none {
			self.showIcons = false
			return
		}

		for article in articles {
			if let authors = article.authors {
				for author in authors {
					if author.avatarURL != nil {
						self.showIcons = true
						return
					}
				}
			}
		}

		self.showIcons = false
	}

	func markExpanded(_ containerID: ContainerIdentifier) {
		expandedContainers.insert(containerID)
	}

	func markExpanded(_ containerIdentifiable: ContainerIdentifiable) {
		if let containerID = containerIdentifiable.containerID {
			markExpanded(containerID)
		}
	}

	func markExpanded(_ node: Node) {
		if let containerIdentifiable = node.representedObject as? ContainerIdentifiable {
			markExpanded(containerIdentifiable)
		}
	}

	func unmarkExpanded(_ containerID: ContainerIdentifier) {
		expandedContainers.remove(containerID)
	}

	func unmarkExpanded(_ containerIdentifiable: ContainerIdentifiable) {
		if let containerID = containerIdentifiable.containerID {
			unmarkExpanded(containerID)
		}
	}

	func unmarkExpanded(_ node: Node) {
		if let containerIdentifiable = node.representedObject as? ContainerIdentifiable {
			unmarkExpanded(containerIdentifiable)
		}
	}

	// MARK: Select Prev Unread

	@discardableResult
	func selectPrevUnreadArticleInTimeline() -> Bool {
		let startingRow: Int = {
			if let articleRow = currentArticleRow {
				return articleRow
			} else {
				return articles.count - 1
			}
		}()

		return selectPrevArticleInTimeline(startingRow: startingRow)
	}

	func selectPrevArticleInTimeline(startingRow: Int) -> Bool {

		guard startingRow >= 0 else {
			return false
		}

		for i in (0...startingRow).reversed() {
			let article = articles[i]
			if !article.status.read {
				selectArticle(article)
				return true
			}
		}

		return false

	}

	func selectPrevUnreadFeedFetcher() {

		let indexPath: IndexPath = {
			if currentFeedIndexPath == nil {
				return IndexPath(row: 0, section: 0)
			} else {
				return currentFeedIndexPath!
			}
		}()

		// Increment or wrap around the IndexPath
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot
		let numberOfSections = snapshot.numberOfSections
		let nextIndexPath: IndexPath = {
			if indexPath.row - 1 < 0 {
				if indexPath.section - 1 < 0 {
					let lastSection = numberOfSections - 1
					let count = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[lastSection])
					return IndexPath(row: count - 1, section: lastSection)
				} else {
					let count = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[indexPath.section - 1])
					return IndexPath(row: count - 1, section: indexPath.section - 1)
				}
			} else {
				return IndexPath(row: indexPath.row - 1, section: indexPath.section)
			}
		}()

		if selectPrevUnreadFeedFetcher(startingWith: nextIndexPath) {
			return
		}
		let lastSection = numberOfSections - 1
		let count = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[lastSection])
		let maxIndexPath = IndexPath(row: count - 1, section: lastSection)
		selectPrevUnreadFeedFetcher(startingWith: maxIndexPath)

	}

	@discardableResult
	func selectPrevUnreadFeedFetcher(startingWith indexPath: IndexPath) -> Bool {
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot

		for i in (0...indexPath.section).reversed() {

			let startingRow: Int = {
				if indexPath.section == i {
					return indexPath.row
				} else {
					let count = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[i])
					return count - 1
				}
			}()

			guard startingRow >= 0 else {
				continue
			}

			for j in (0...startingRow).reversed() {

				let prevIndexPath = IndexPath(row: j, section: i)
				guard let node = nodeFor(prevIndexPath), let unreadCountProvider = node.representedObject as? UnreadCountProvider else {
					assertionFailure()
					return true
				}

				if isExpanded(node) {
					continue
				}

				if unreadCountProvider.unreadCount > 0 {
					selectSidebarItem(indexPath: prevIndexPath, animations: [.scroll, .navigation])
					return true
				}

			}

		}

		return false

	}

	// MARK: Select Next Unread

	@discardableResult
	func selectFirstUnreadArticleInTimeline() -> Bool {
		return selectNextArticleInTimeline(startingRow: 0, animated: true)
	}

	@discardableResult
	func selectNextUnreadArticleInTimeline() -> Bool {
		let startingRow: Int = {
			if let articleRow = currentArticleRow {
				return articleRow + 1
			} else {
				return 0
			}
		}()

		return selectNextArticleInTimeline(startingRow: startingRow, animated: false)
	}

	func selectNextArticleInTimeline(startingRow: Int, animated: Bool) -> Bool {

		guard startingRow < articles.count else {
			return false
		}

		for i in startingRow..<articles.count {
			let article = articles[i]
			if !article.status.read {
				selectArticle(article, animations: [.scroll, .navigation])
				return true
			}
		}

		return false

	}

	func selectNextUnreadFeed(completion: @escaping () -> Void) {

		let indexPath: IndexPath = {
			if currentFeedIndexPath == nil {
				return IndexPath(row: -1, section: 0)
			} else {
				return currentFeedIndexPath!
			}
		}()

		// Increment or wrap around the IndexPath
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot
		let numberOfSections = snapshot.numberOfSections
		let nextIndexPath: IndexPath = {
			let count = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[indexPath.section])
			if indexPath.row + 1 >= count {
				if indexPath.section + 1 >= numberOfSections {
					return IndexPath(row: 0, section: 0)
				} else {
					return IndexPath(row: 0, section: indexPath.section + 1)
				}
			} else {
				return IndexPath(row: indexPath.row + 1, section: indexPath.section)
			}
		}()

		selectNextUnreadFeed(startingWith: nextIndexPath) { found in
			if !found {
				self.selectNextUnreadFeed(startingWith: IndexPath(row: 0, section: 0)) { _ in
					completion()
				}
			} else {
				completion()
			}
		}

	}

	func selectNextUnreadFeed(startingWith indexPath: IndexPath, completion: @escaping (Bool) -> Void) {
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot
		let numberOfSections = snapshot.numberOfSections

		for i in indexPath.section..<numberOfSections {

			let startingRow: Int = {
				if indexPath.section == i {
					return indexPath.row
				} else {
					return 0
				}
			}()

			let count = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[i])
			for j in startingRow..<count {

				let nextIndexPath = IndexPath(row: j, section: i)
				guard let node = nodeFor(nextIndexPath), let unreadCountProvider = node.representedObject as? UnreadCountProvider else {
					assertionFailure()
					completion(false)
					return
				}

				if isExpanded(node) {
					continue
				}

				if unreadCountProvider.unreadCount > 0 {
					selectSidebarItem(indexPath: nextIndexPath, animations: [.scroll, .navigation], deselectArticle: false) {
						self.currentArticle = nil
						completion(true)
					}
					return
				}

			}

		}

		completion(false)

	}

	// MARK: Fetching Articles

	func emptyTheTimeline() {
		invalidateTimelinePreparation()
		if !articles.isEmpty {
			commitArticles([], prepared: nil, animated: false)
		}
	}

	func sortParametersDidChange() {
		replaceArticles(with: Set(articles), animated: true)
	}

	func updateTimelineSortDirection() {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			sortDirection = AppDefaults.shared.timelineSortDirection
			return
		}
		sortDirection = timelineSortDirectionState.sortDirection(for: sidebarItemID, defaultSortDirection: AppDefaults.shared.timelineSortDirection)
	}

	func replaceArticles(with unsortedArticles: Set<Article>, animated: Bool, completion: (() -> Void)? = nil) {
		invalidateTimelinePreparation()
		guard !unsortedArticles.isEmpty else {
			commitArticles([], prepared: nil, animated: animated)
			completion?()
			return
		}
		var namesByFeed = [String: [String: String]]()
		let keys = unsortedArticles.map { article in
			let name: String
			if !groupByFeed {
				name = ""
			} else if let cached = namesByFeed[article.accountID]?[article.feedID] {
				name = cached
			} else {
				name = article.account?.existingFeed(withFeedID: article.feedID)?.name ?? ""
				namesByFeed[article.accountID, default: [:]][article.feedID] = name
			}
			return TimelineArticleSortKey(article: article, feedName: name)
		}
		let generation = timelinePreparationState.generation
		let direction = sortDirection
		let grouping = groupByFeed
		let sortInterval = PerformanceDiagnosticLog.begin("Timeline sort", details: "article_count=\(keys.count) background=true", tracksMainThread: false)
		let worker = Task.detached(priority: .userInitiated) {
			try TimelinePreparedArticles.sort(keys, direction: direction, groupByFeed: grouping)
		}
		timelinePreparationTask = Task { @MainActor [weak self] in
			do {
				let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
				PerformanceDiagnosticLog.end(sortInterval, details: "article_count=\(prepared.articles.count)")
				guard !Task.isCancelled, let self, self.timelinePreparationState.isCurrent(generation) else { return }
				self.timelinePreparationTask = nil
				self.commitArticles(prepared.articles, prepared: prepared, animated: animated)
				completion?()
			} catch {
				PerformanceDiagnosticLog.end(sortInterval, details: "result=cancelled")
			}
		}
	}

	func replaceArticles(with sortedArticles: ArticleArray, animated: Bool, resetScroll: Bool = false) {
		invalidateTimelinePreparation()
		commitArticles(sortedArticles, prepared: nil, animated: animated, resetScroll: resetScroll)
	}

	func invalidateTimelinePreparation() {
		timelinePreparationState.invalidate()
		timelinePreparationTask?.cancel()
		timelinePreparationTask = nil
	}

	func commitArticles(_ sortedArticles: ArticleArray, prepared: TimelinePreparedArticles?, animated: Bool, resetScroll: Bool = false) {
		let didChange = articles != sortedArticles
		let updateInterval = PerformanceDiagnosticLog.begin("Timeline model update", details: "old_count=\(articles.count) new_count=\(sortedArticles.count) animated=\(animated)")
		defer {
			PerformanceDiagnosticLog.end(updateInterval, details: "changed=\(didChange)")
		}
		articles = sortedArticles
		preparedTimelineArticles = prepared ?? (didChange ? nil : preparedTimelineArticles)
		if !isRestoringState, let newArticle = sortedArticles.first(where: isCurrentArticle), newArticle !== currentArticle {
			currentArticle = newArticle
		}
		updateShowNamesAndIcons()
		updateUnreadCount()
		IconImageCache.shared.prefetchImagesForArticles(articles)
		mainTimelineViewController?.reloadArticles(animated: animated, resetScroll: resetScroll)
	}

	func queueFetchAndMergeArticles() {
		fetchAndMergeArticlesQueue.add(self, #selector(fetchAndMergeArticlesAsync))
	}

	func queueTimelineRefresh(for reason: TimelineRefreshReason) {
		PerformanceDiagnosticLog.event(operation: "Timeline refresh", message: "dispatch reason=\(reason.performanceName) mode=\(reason.fetchMode.performanceName) kind=\(timelinePerformanceKind)")
		switch reason.fetchMode {
		case .merge:
			if reason == .foreground {
				queuedFetchAndMergeShouldAnimate = false
			}
			queueFetchAndMergeArticles()
		case .replace:
			queueRefreshTimelineAfterStatusChange()
		}
	}

	func queueRefreshTimelineAfterStatusChange() {
		refreshTimelineAfterStatusChangeQueue.add(self, #selector(refreshTimelineAfterStatusChange))
	}

	@objc func refreshTimelineAfterStatusChange() {
		guard isReadArticlesFiltered, timelineFeed != nil else {
			return
		}
		if let article = currentArticle, let account = article.account {
			exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: article.articleID)
		}
		NotificationActionLog.log(.debug, operation: "Timeline hide-read", message: "Replacing timeline after read status change")
		fetchAndReplaceArticlesAsync(animated: true, emptyFirst: false) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
		}
	}

	@objc func fetchAndMergeArticlesAsync() {
		let animated = queuedFetchAndMergeShouldAnimate
		queuedFetchAndMergeShouldAnimate = true
		fetchAndMergeArticlesAsync(animated: animated) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
			self.mainTimelineViewController?.restoreSelectionIfNecessary(adjustScroll: false)
		}
	}

	func fetchAndMergeArticlesAsync(animated: Bool = true, completion: (() -> Void)? = nil) {

		guard let timelineFeed = timelineFeed else {
			return
		}
		let favoriteFeedKeys: Set<FavoriteFeedKey>?
		if timelineFeed is FavoriteFeedsAllFeed {
			favoriteFeedKeys = Set(FavoriteFeedsController.shared.aliases.map(\.key))
		} else if let folder = timelineFeed as? FavoriteFeedsFolder {
			favoriteFeedKeys = Set(folder.aliases.map(\.key))
		} else if let alias = timelineFeed as? FavoriteFeedAlias {
			favoriteFeedKeys = [alias.key]
		} else {
			favoriteFeedKeys = nil
		}

		fetchUnsortedArticlesAsync(for: [timelineFeed]) { [weak self] (unsortedArticles) in
			guard let strongSelf = self else {
				return
			}
			let existing = strongSelf.articles
			let revision = strongSelf.articlesRevision
			let existingFeedKeys = Set(AccountManager.shared.accounts.flatMap { account in
				account.flattenedFeeds().map { FavoriteFeedKey(feed: $0) }
			})
			strongSelf.invalidateTimelinePreparation()
			let generation = strongSelf.timelinePreparationState.generation
			let interval = PerformanceDiagnosticLog.begin("Timeline merge", details: "fetched_count=\(unsortedArticles.count) existing_count=\(existing.count) background=true", tracksMainThread: false)
			let worker = Task.detached(priority: .userInitiated) {
				try Task.checkCancellation()
				let merged = TimelineArticleMerger.merge(fetchedArticles: unsortedArticles, existingArticles: existing) { article in
					let key = FavoriteFeedKey(accountID: article.accountID, feedID: article.feedID)
					return existingFeedKeys.contains(key) && (favoriteFeedKeys?.contains(key) ?? true)
				}
				try Task.checkCancellation()
				return merged
			}
			strongSelf.timelinePreparationTask = Task { @MainActor [weak self] in
				do {
					let merged = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
					PerformanceDiagnosticLog.end(interval, details: "result_count=\(merged.count)")
					guard !Task.isCancelled, let self, self.timelinePreparationState.isCurrent(generation),
						self.articlesRevision == revision else { return }
					self.timelinePreparationTask = nil
					self.replaceArticles(with: merged, animated: animated, completion: completion)
				} catch {
					PerformanceDiagnosticLog.end(interval, details: "result=cancelled")
				}
			}
		}

	}

	func refreshTimeline(for reason: TimelineRefreshReason, animated: Bool, completion: @escaping () -> Void) {
		switch reason.fetchMode {
		case .merge:
			fetchAndMergeArticlesAsync(animated: animated, completion: completion)
		case .replace:
			fetchAndReplaceArticlesAsync(animated: animated, emptyFirst: reason.emptiesTimelineBeforeFetch, completion: completion)
		}
	}

	func cancelPendingAsyncFetches() {
		invalidateTimelinePreparation()
		if let performanceFetchInterval {
			PerformanceDiagnosticLog.end(performanceFetchInterval, details: "result=cancelled")
			self.performanceFetchInterval = nil
		}
		if let performanceRequestID {
			PerformanceDiagnosticLog.endRequest(performanceRequestID, details: "result=cancelled")
			self.performanceRequestID = nil
		}
		fetchSerialNumber += 1
		fetchRequestQueue.cancelAllRequests()
	}

	func fetchAndReplaceArticlesAsync(animated: Bool, emptyFirst: Bool = true, completion: @escaping () -> Void) {
		// To be called when we need to do an entire fetch, but an async delay is okay.
		// Example: we have the Today feed selected, and the calendar day just changed.
		cancelPendingAsyncFetches()
		if emptyFirst {
			emptyTheTimeline()
		} else if let article = currentArticle, let account = article.account {
			// Keeping the timeline in place keeps the open article, even when the read filter excludes it.
			exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: article.articleID)
		}
		guard let timelineFeed = timelineFeed else {
			completion()
			return
		}

		var fetchers = [ArticleFetcher]()
		fetchers.append(timelineFeed)
		if exceptionArticleFetcher != nil {
			fetchers.append(exceptionArticleFetcher!)
			exceptionArticleFetcher = nil
		}
		for article in videoPlaybackArticles {
			if let account = article.account {
				fetchers.append(SingleArticleFetcher(account: account, articleID: article.articleID))
			}
		}

		fetchUnsortedArticlesAsync(for: fetchers) { [weak self] (articles) in
			self?.replaceArticles(with: articles, animated: animated, completion: completion)
		}

	}

	func fetchUnsortedArticlesAsync(for representedObjects: [Any], completion: @escaping ArticleSetBlock) {
		// The callback will *not* be called if the fetch is no longer relevant — that is,
		// if it’s been superseded by a newer fetch, or the timeline was emptied, etc., it won’t get called.
		precondition(Thread.isMainThread)
		cancelPendingAsyncFetches()

		let fetchers = representedObjects.compactMap { $0 as? ArticleFetcher }
		let requestID = PerformanceDiagnosticLog.beginRequest(kind: timelinePerformanceKind, details: "fetcher_count=\(fetchers.count) serial=\(fetchSerialNumber)")
		performanceRequestID = requestID
		performanceFetchInterval = PerformanceDiagnosticLog.begin("Timeline fetch", details: "fetcher_count=\(fetchers.count)", requestID: requestID, tracksMainThread: false)
		let fetchOperation = FetchRequestOperation(id: fetchSerialNumber, hidingReadArticlesState: hidingReadArticlesState, fetchers: fetchers) { [weak self] (articles, operation) in
			precondition(Thread.isMainThread)
			guard !operation.isCanceled, let strongSelf = self, operation.id == strongSelf.fetchSerialNumber else {
				return
			}
			if let interval = strongSelf.performanceFetchInterval {
				PerformanceDiagnosticLog.end(interval, details: "article_count=\(articles.count) result=success")
				strongSelf.performanceFetchInterval = nil
			}
			completion(articles)
			if let requestID = strongSelf.performanceRequestID {
				PerformanceDiagnosticLog.endRequest(requestID, details: "result=delivered article_count=\(articles.count)")
				strongSelf.performanceRequestID = nil
			}
		}

		fetchRequestQueue.add(fetchOperation)
	}

	var timelinePerformanceKind: String {
		guard let timelineFeed else {
			return "none"
		}
		if timelineFeed is Feed {
			return "feed"
		}
		if timelineFeed is FavoriteFeedsAllFeed {
			return "favorites-all"
		}
		if timelineFeed is FavoriteFeedsFolder {
			return "favorites-folder"
		}
		if timelineFeed is Folder {
			return "folder"
		}
		if timelineFeed is PseudoFeed {
			return "pseudo-feed"
		}
		return "other"
	}

	func timelineFetcherContainsAnyPseudoFeed() -> Bool {
		if timelineFeed is PseudoFeed {
			return true
		}
		return false
	}

	func timelineFetcherContainsAnyFolder() -> Bool {
		if timelineFeed is Folder {
			return true
		}
		return false
	}

	func timelineFetcherContainsAnyFeed(_ feeds: Set<Feed>) -> Bool {

		// Return true if there’s a match or if a folder contains (recursively) one of feeds

		if let feed = timelineFeed as? Feed {
			for oneFeed in feeds {
				if feed.feedID == oneFeed.feedID || feed.url == oneFeed.url {
					return true
				}
			}
		} else if let alias = timelineFeed as? FavoriteFeedAlias, let feed = alias.feed {
			for oneFeed in feeds {
				if feed.feedID == oneFeed.feedID || feed.url == oneFeed.url {
					return true
				}
			}
		} else if let favoriteFolder = timelineFeed as? FavoriteFeedsFolder {
			for oneFeed in feeds {
				if favoriteFolder.contains(oneFeed) {
					return true
				}
			}
		} else if timelineFeed?.sidebarItemID == FavoriteFeedsController.shared.allFeed.sidebarItemID {
			for oneFeed in feeds {
				if FavoriteFeedsController.shared.isFavorite(oneFeed) {
					return true
				}
			}
		} else if let folder = timelineFeed as? Folder {
			for oneFeed in feeds {
				if folder.hasFeed(with: oneFeed.feedID) || folder.hasFeed(withURL: oneFeed.url) {
					return true
				}
			}
		}

		return false

	}

	// MARK: NSUserActivity

	func handleSelectFeed(_ userInfo: [AnyHashable: Any]?) {
		Self.logger.debug("SceneCoordinator: handleSelectFeed")

		guard let userInfo = userInfo,
			let sidebarItemIDUserInfo = userInfo[UserInfoKey.sidebarItemID] as? [String: String],
			let sidebarItemID = SidebarItemIdentifier(userInfo: sidebarItemIDUserInfo) else {
				return
		}

		treeControllerDelegate.addFilterException(sidebarItemID)

		switch sidebarItemID {

		case .smartFeed:
			if let smartFeed = SmartFeedsController.shared.find(by: sidebarItemID) {
				markExpanded(SmartFeedsController.shared)
				rebuildBackingStores(initialLoad: true, completion: {
					self.treeControllerDelegate.resetFilterExceptions()
					if let indexPath = self.indexPathFor(smartFeed) {
						self.selectSidebarItem(indexPath: indexPath) {
							self.mainFeedCollectionViewController.focus()
						}
					}
				})
				return
			}

			guard let favoriteItem = FavoriteFeedsController.shared.find(by: sidebarItemID) else {
				return
			}

			markExpanded(FavoriteFeedsController.shared)
			if let alias = favoriteItem as? FavoriteFeedAlias {
				let folders = FavoriteFeedsController.shared.foldersContaining(alias)
				if folders.isEmpty {
					markExpanded(FavoriteFeedsController.shared.ungroupedFolder)
				} else {
					for folder in folders {
						markExpanded(folder)
					}
				}
			}
			rebuildBackingStores(initialLoad: true, completion: {
				self.treeControllerDelegate.resetFilterExceptions()
				if let indexPath = self.indexPathFor(favoriteItem) {
					self.selectSidebarItem(indexPath: indexPath) {
						self.mainFeedCollectionViewController.focus()
					}
				}
			})

		case .folder(let accountID, let folderName):
			guard let accountNode = self.findAccountNode(accountID: accountID),
				let account = accountNode.representedObject as? Account else {
				return
			}

			markExpanded(account)

			rebuildBackingStores(initialLoad: true, completion: {
				self.treeControllerDelegate.resetFilterExceptions()

				if let folderNode = self.findFolderNode(folderName: folderName, beginningAt: accountNode), let indexPath = self.indexPathFor(folderNode) {
					self.selectSidebarItem(indexPath: indexPath) {
						self.mainFeedCollectionViewController.focus()
					}
				}
			})

		case .feed(let accountID, let feedID):
			guard let accountNode = findAccountNode(accountID: accountID),
				let account = accountNode.representedObject as? Account,
				let feed = account.existingFeed(withFeedID: feedID) else {
				return
			}

			self.discloseFeed(feed, initialLoad: true) {
				self.mainFeedCollectionViewController.focus()
			}
		}
	}

	func handleReadArticle(_ userInfo: [AnyHashable: Any]?) {
		guard let userInfo = userInfo else {
			return
		}

		// A deep link supersedes any in-flight state restoration.
		isRestoringState = false

		guard let articlePathUserInfo = userInfo[UserInfoKey.articlePath] as? [AnyHashable: Any],
			  let accountID = articlePathUserInfo[ArticlePathKey.accountID] as? String,
			  let accountName = articlePathUserInfo[ArticlePathKey.accountName] as? String,
			  let feedID = articlePathUserInfo[ArticlePathKey.feedID] as? String,
			  let articleID = articlePathUserInfo[ArticlePathKey.articleID] as? String,
			  let accountNode = findAccountNode(accountID: accountID, accountName: accountName),
			  let account = accountNode.representedObject as? Account else {
				  return
			  }

		exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: articleID)

		if restoreFeedSelection(userInfo, accountID: accountID, feedID: feedID, articleID: articleID) {
			return
		}

		guard let feed = account.existingFeed(withFeedID: feedID) else {
			return
		}

		discloseFeed(feed) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
				self.selectArticleInCurrentFeed(articleID)
			})
		}
	}

	func restoreFeedSelection(_ userInfo: [AnyHashable: Any], accountID: String, feedID: String, articleID: String) -> Bool {
		guard let sidebarItemIDUserInfo = (userInfo[UserInfoKey.sidebarItemID] ?? userInfo[UserInfoKey.feedIdentifier]) as? [String: String],
			  let sidebarItemID = SidebarItemIdentifier(userInfo: sidebarItemIDUserInfo) else {
			return false
		}

		// A handoff or deep link opens the article at the top — the persisted scroll
		// position belongs to launch state restoration, not to this article.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5243>
		switch sidebarItemID {

		case .smartFeed, .folder:
			let found = selectSidebarItemAndArticle(sidebarItemID: sidebarItemID, articleID: articleID)
			if found {
				treeControllerDelegate.addFilterException(sidebarItemID)
			}
			return found

		case .feed:
			let found = selectSidebarItemAndArticle(sidebarItemID: sidebarItemID, articleID: articleID)
			if found {
				treeControllerDelegate.addFilterException(sidebarItemID)
				if let sidebarItemNode = nodeFor(sidebarItemID: sidebarItemID), let folder = sidebarItemNode.parent?.representedObject as? Folder, let folderSidebarItemID = folder.sidebarItemID {
					treeControllerDelegate.addFilterException(folderSidebarItemID)
				}
			}
			return found

		}
	}

	func findAccountNode(accountID: String, accountName: String? = nil) -> Node? {
		if let node = treeController.rootNode.descendantNode(where: { ($0.representedObject as? Account)?.accountID == accountID }) {
			return node
		}

		if let accountName = accountName, let node = treeController.rootNode.descendantNode(where: { ($0.representedObject as? Account)?.nameForDisplay == accountName }) {
			return node
		}

		return nil
	}

	func findFolderNode(folderName: String, beginningAt startingNode: Node) -> Node? {
		if let node = startingNode.descendantNode(where: { ($0.representedObject as? Folder)?.nameForDisplay == folderName }) {
			return node
		}
		return nil
	}

	func findSidebarItemNode(feedID: String, beginningAt startingNode: Node) -> Node? {
		if let node = startingNode.descendantNode(where: { ($0.representedObject as? Feed)?.feedID == feedID }) {
			return node
		}
		return nil
	}

	func selectSidebarItemAndArticle(sidebarItemID: SidebarItemIdentifier, articleID: String) -> Bool {
		guard let sidebarItemNode = nodeFor(sidebarItemID: sidebarItemID), let sidebarItemIndexPath = indexPathFor(sidebarItemNode) else {
			return false
		}

		selectSidebarItem(indexPath: sidebarItemIndexPath) {
			self.selectArticleInCurrentFeed(articleID)
		}

		return true
	}
}
