#if os(iOS)
import Articles
import RSParser
import Testing
import UIKit
@testable import Account
@testable import NetNewsWire

@MainActor @Suite(.serialized) struct MainTimelineStatusRefreshTests {

	@Test(arguments: [false, true], [false, true])
	func displayingCellUsesLatestReadAndStarredStatus(read: Bool, starred: Bool) async throws {
		let fixture = try await TimelineFixture()
		defer { fixture.close() }
		let article = fixture.articles[0]
		let indexPath = IndexPath(item: 0, section: 0)
		let cell = try #require(fixture.collectionView.cellForItem(at: indexPath) as? MainTimelineCell)

		article.status.read = !read
		article.status.starred = !starred
		cell.cellData = fixture.cellData(article)
		article.status.read = read
		article.status.starred = starred

		fixture.collectionView.delegate?.collectionView?(fixture.collectionView, willDisplay: cell, forItemAt: indexPath)
		cell.layoutIfNeeded()

		#expect(cell.cellData.read == read)
		#expect(cell.cellData.starred == starred)
		try expectIndicator(cell, read: read, starred: starred)
	}

	@Test func appearanceCompletionRestoresIndicatorsAfterEarlyRefresh() async throws {
		let fixture = try await TimelineFixture()
		defer { fixture.close() }
		fixture.timeline.beginAppearanceTransition(true, animated: false)
		let cells = fixture.collectionView.visibleCells.compactMap { $0 as? MainTimelineCell }
		#expect(cells.count > 1)

		// Simulate cell reuse invalidating presentation after viewWillAppear's refresh.
		// The articles remain unread; finishing the transition must restore their dots.
		for cell in cells {
			cell.prepareForReuse()
			#expect(!cell.cellData.read)
			#expect(try indicator(in: cell).isHidden)
		}
		fixture.timeline.endAppearanceTransition()

		for cell in cells {
			try expectIndicator(cell, read: false, starred: false)
		}
		#expect(fixture.articles.allSatisfy { !$0.status.read })
	}

	@Test func scrollingAndReturningFromArticlePreservesOtherUnreadIndicators() async throws {
		let fixture = try await TimelineFixture()
		defer { fixture.close() }
		#expect(!fixture.collectionView.isPrefetchingEnabled)

		for row in [12, 24, 6] {
			fixture.collectionView.scrollToItem(at: IndexPath(item: row, section: 0), at: .top, animated: false)
			fixture.collectionView.layoutIfNeeded()
			let indexPath = try #require(fixture.collectionView.indexPathsForVisibleItems.sorted().first)
			let article = fixture.articles[indexPath.item]
			fixture.coordinator.selectArticle(article, animations: [.navigation])
			for _ in 0..<100 {
				if article.status.read, !fixture.coordinator.isArticleViewControllerPending,
				   fixture.coordinator.isArticleViewControllerShowing {
					break
				}
				try await Task.sleep(for: .milliseconds(20))
			}
			#expect(article.status.read)
			#expect(fixture.coordinator.isArticleViewControllerShowing)
			fixture.coordinator.navigateToTimeline()
			for _ in 0..<100 where fixture.coordinator.isArticleViewControllerShowing || fixture.coordinator.isTimelineViewControllerPending {
				try await Task.sleep(for: .milliseconds(20))
			}
			#expect(!fixture.coordinator.isArticleViewControllerShowing)
			fixture.collectionView.layoutIfNeeded()

			for path in fixture.collectionView.indexPathsForVisibleItems {
				let cell = try #require(fixture.collectionView.cellForItem(at: path) as? MainTimelineCell)
				let model = fixture.articles[path.item]
				#expect(cell.cellData.read == model.status.read)
				try expectIndicator(cell, read: model.status.read, starred: model.status.starred)
			}
			let screenshot = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
				fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
			}
			Attachment.record(screenshot, named: "timeline-after-article-row-\(row)", as: .png)
		}
		#expect(fixture.articles.filter { $0.status.read }.count == 3)
		let databaseUnreadArticles = await fixture.account.fetchArticlesAsync(.unread())
		#expect(databaseUnreadArticles.count == 37)
	}

	private func indicator(in cell: MainTimelineCell) throws -> IconView {
		try #require(cell.contentView.subviews.compactMap { $0 as? IconView }.last)
	}

	private func expectIndicator(_ cell: MainTimelineCell, read: Bool, starred: Bool) throws {
		let indicator = try indicator(in: cell)
		#expect(indicator.isHidden == (read && !starred))
		if !indicator.isHidden {
			#expect(indicator.iconImage === (starred ? Assets.Images.starredFeed : Assets.Images.unreadCellIndicator))
			#expect(indicator.bounds.width > 0)
			#expect(indicator.bounds.height > 0)
			let imageView = try #require(indicator.subviews.first as? UIImageView)
			#expect(imageView.image != nil)
			#expect(imageView.bounds.width > 0)
			#expect(imageView.bounds.height > 0)
		}
	}
}

@MainActor private final class TimelineFixture {
	let root: RootSplitViewController
	let coordinator: SceneCoordinator
	let timeline: MainTimelineModernViewController
	let collectionView: UICollectionView
	let window: UIWindow
	let account: Account
	var articles: [Article] { coordinator.articles }

	init() async throws {
		account = AccountManager.shared.createAccount(type: .onMyMac)
		account.name = "Timeline status fixture"
		let feed = account.createFeed(with: "Timeline fixture", url: "https://example.invalid/timeline-fixture",
			feedID: "https://example.invalid/timeline-fixture", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		let parsedItems = Set((0..<40).map { row in
			ParsedItem(syncServiceID: nil, uniqueID: "timeline-status-fixture-\(row)", feedURL: feed.url,
				url: nil, externalURL: nil, title: "Timeline fixture article \(row)", language: nil,
				contentHTML: "<p>Local navigation regression fixture.</p>", contentText: nil, markdown: nil,
				summary: nil, imageURL: nil, bannerImageURL: nil,
				datePublished: Date().addingTimeInterval(Double(-row)), dateModified: nil,
				authors: nil, tags: nil, attachments: nil)
		})
		_ = await account.updateAsync(feedID: feed.feedID, parsedItems: parsedItems, deleteOlder: false)
		let seededArticles = await account.fetchArticlesAsync(.feed(feed))
		try #require(seededArticles.count == 40)
		try #require(seededArticles.allSatisfy { !$0.status.read })
		let sceneDelegate = try #require(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		window = try #require(sceneDelegate.window)
		root = try #require(window.rootViewController as? RootSplitViewController)
		coordinator = try #require(sceneDelegate.coordinator)
		timeline = try #require(root.viewController(for: .supplementary) as? MainTimelineModernViewController)
		timeline.loadViewIfNeeded()
		collectionView = try #require(timeline.collectionView)
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			coordinator.discloseFeed(feed, initialLoad: true, animations: []) {
				continuation.resume()
			}
		}
		for _ in 0..<150 {
			root.view.layoutIfNeeded()
			collectionView.layoutIfNeeded()
			if articles.count == 40, collectionView.numberOfSections > 0,
			   collectionView.numberOfItems(inSection: 0) == articles.count,
			   !collectionView.visibleCells.isEmpty,
			   collectionView.visibleCells.allSatisfy({ cell in
				   guard let cell = cell as? MainTimelineCell else { return false }
				   return cell.cellData.accountID == account.accountID && !cell.cellData.read && !cell.cellData.starred
			   }) {
				return
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		Issue.record("Timeline did not display: model=\(articles.count), cells=\(collectionView.visibleCells.count), feed=\(coordinator.timelineFeed?.nameForDisplay ?? "nil")")
		throw TimelineFixtureError.didNotDisplay
	}

	func cellData(_ article: Article) -> MainTimelineCellData {
		MainTimelineCellData(article: article, showFeedName: .none, feedName: nil, byline: nil,
			iconImage: nil, showIcon: false, numberOfLines: 3, iconSize: .medium)
	}

	func close() {
		coordinator.selectArticle(nil)
		if let feeds = root.viewController(for: .primary) {
			timeline.navigationController?.popToViewController(feeds, animated: false)
		}
		coordinator.selectFeed(nil)
		AccountManager.shared.deleteAccount(account)
	}
}

private enum TimelineFixtureError: Error {
	case didNotDisplay
}
#endif
