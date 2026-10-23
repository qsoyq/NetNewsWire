#if os(iOS)
import XCTest
import UIKit
import WebKit
import Articles
import RSParser
@testable import Account
@testable import NetNewsWire

@MainActor final class ArticleQuickSettingsTests: XCTestCase {
	func testQuickSettingsReturnToSameReaderAndPreventAutomaticNavigation() async throws {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first)
		let window = try XCTUnwrap(scene.window)
		let root = try XCTUnwrap(window.rootViewController as? RootSplitViewController)
		let coordinator = try XCTUnwrap(scene.coordinator)
		let originalTranslation = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		let originalFullscreen = AppDefaults.shared.articleFullscreenAvailable
		let originalFullscreenEnabled = AppDefaults.shared.articleFullscreenEnabled
		let originalMedia = AppDefaults.shared.prefetchNextArticleContent
		try ArticleTranslationSettings.save(ArticleTranslationPreferences(), apiKey: originalKey)
		AppDefaults.shared.articleFullscreenAvailable = false
		AppDefaults.shared.prefetchNextArticleContent = false
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		let token = UUID().uuidString
		let feed = account.createFeed(with: "Quick settings test", url: "https://example.invalid/\(token)",
			feedID: "https://example.invalid/\(token)", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		defer {
			root.dismiss(animated: false)
			coordinator.selectArticle(nil)
			coordinator.navigateToTimeline()
			coordinator.selectFeed(nil)
			AccountManager.shared.deleteAccount(account)
			try? ArticleTranslationSettings.save(originalTranslation, apiKey: originalKey)
			AppDefaults.shared.articleFullscreenAvailable = originalFullscreen
			AppDefaults.shared.articleFullscreenEnabled = originalFullscreenEnabled
			AppDefaults.shared.prefetchNextArticleContent = originalMedia
		}
		defer { attach(window, name: "Quick Settings Final Reader State") }
		let body = (0..<80).map { "<p>Reading paragraph \($0). Quick settings must preserve this article and its reading position.</p>" }.joined()
		let items = Set((0..<2).map { index in
			ParsedItem(syncServiceID: nil, uniqueID: "\(token)-\(index)", feedURL: feed.url,
				url: nil, externalURL: nil, title: "Quick settings article \(index)", language: nil,
				contentHTML: body, contentText: nil, markdown: nil, summary: nil, imageURL: nil, bannerImageURL: nil,
				datePublished: Date().addingTimeInterval(Double(-index)), dateModified: nil, authors: nil, tags: nil, attachments: nil)
		})
		_ = await account.updateAsync(feedID: feed.feedID, parsedItems: items, deleteOlder: false)
		let seeded = await account.fetchArticlesAsync(.feed(feed))
		XCTAssertEqual(seeded.count, 2, "The local test feed must contain both articles before navigation")
		let timeline = try XCTUnwrap(root.viewController(for: .supplementary) as? MainTimelineModernViewController)
		timeline.loadViewIfNeeded()
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			coordinator.discloseFeed(feed, initialLoad: true, animations: []) { continuation.resume() }
		}
		try await waitUntil { coordinator.articles.count == 2 }
		let first = try XCTUnwrap(coordinator.articles.first)
		coordinator.selectArticle(first, animations: [.navigation])
		let article = try XCTUnwrap(root.viewController(for: .secondary) as? ArticleViewController)
		try await waitUntil { article.viewIfLoaded?.window != nil && !coordinator.isArticleViewControllerPending }
		let pager = try XCTUnwrap(article.children.first { $0 is UIPageViewController } as? UIPageViewController)
		let reader = try XCTUnwrap(pager.viewControllers?.first as? WebViewController)
		try await waitUntil { reader.isArticleDocumentReady }
		let webView = try XCTUnwrap(reader.view.subviews.first { $0 is WKWebView } as? WKWebView)
		let button = try XCTUnwrap(article.navigationItem.rightBarButtonItems?.last)
		XCTAssertEqual(button.accessibilityIdentifier, "article.quickSettings")
		XCTAssertTrue(button.isEnabled)
		let menu = try XCTUnwrap(button.menu)
		let actions = try XCTUnwrap(menu.children as? [UIAction])
		XCTAssertEqual(actions.map(\.identifier.rawValue), ArticleQuickSettingsDestination.allCases.map(\.identifier))
		XCTAssertEqual(actions.map(\.title), ArticleQuickSettingsDestination.allCases.map(\.title))
		XCTAssertEqual(article.navigationItem.rightBarButtonItems?.count, 3)

		_ = try await webView.evaluateJavaScript("window.scrollTo(0, 900)")
		try await Task.sleep(for: .milliseconds(400))
		let scrollY = try await webView.evaluateJavaScript("window.scrollY") as? Double ?? 0
		XCTAssertGreaterThan(scrollY, 500)
		let stack = article.navigationController?.viewControllers
		attach(window, name: "Article Quick Settings Entry")
		for destination in ArticleQuickSettingsDestination.allCases {
			coordinator.showArticleQuickSettings(destination)
			XCTAssertTrue(coordinator.isArticleQuickSettingsPresented)
			let sheet = try XCTUnwrap(root.presentedViewController as? ArticleQuickSettingsViewController)
			XCTAssertEqual(sheet.rootView.destination, destination)
			try await waitUntil { sheet.viewIfLoaded?.window != nil && !sheet.isBeingPresented }
			coordinator.showArticleQuickSettings(.cache)
			XCTAssertTrue(root.presentedViewController === sheet, "Repeated requests must not stack sheets")
			coordinator.selectNextArticleAfterVideo()
			XCTAssertEqual(coordinator.currentArticle, first)
			attach(window, name: "Article Quick Settings - \(destination.rawValue)")
			sheet.rootView.close()
			try await waitUntil { !coordinator.isArticleQuickSettingsPresented && root.presentedViewController == nil }
			XCTAssertEqual(coordinator.currentArticle, first)
			XCTAssertTrue(pager.viewControllers?.first === reader)
			XCTAssertTrue(reader.view.subviews.contains { $0 === webView })
			XCTAssertEqual(article.navigationController?.viewControllers, stack)
			let returnedY = try await webView.evaluateJavaScript("window.scrollY") as? Double ?? 0
			XCTAssertEqual(returnedY, scrollY, accuracy: 2)
		}

		coordinator.showArticleQuickSettings(.media)
		let sheet = try XCTUnwrap(root.presentedViewController as? ArticleQuickSettingsViewController)
		try await waitUntil { !sheet.isBeingPresented }
		root.dismiss(animated: false)
		try await waitUntil { !coordinator.isArticleQuickSettingsPresented }
		XCTAssertEqual(coordinator.currentArticle, first, "Dismissal must not replay a blocked video event")
		coordinator.selectNextArticleAfterVideo()
		XCTAssertNotEqual(coordinator.currentArticle, first, "New video events should navigate after dismissal")
		coordinator.selectArticle(first, animations: [])

		let originalFrame = window.frame
		window.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
		try await Task.sleep(for: .milliseconds(400))
		window.layoutIfNeeded()
		let zone = try XCTUnwrap(article.navigationItem.titleView)
		XCTAssertLessThanOrEqual(zone.bounds.width, 150)
		XCTAssertGreaterThanOrEqual(zone.bounds.width, 44)
		attach(window, name: "Article Quick Settings Narrow 320")
		window.frame = originalFrame

		if article.traitCollection.userInterfaceIdiom == .phone {
			AppDefaults.shared.articleFullscreenAvailable = true
			reader.hideBars()
			try await Task.sleep(for: .milliseconds(300))
			XCTAssertTrue(article.navigationController?.isNavigationBarHidden == true)
			reader.showBars()
			try await Task.sleep(for: .milliseconds(300))
			XCTAssertFalse(article.navigationController?.isNavigationBarHidden == true)
		}
		coordinator.selectArticle(nil)
		article.updateUI()
		XCTAssertFalse(button.isEnabled)
		coordinator.showArticleQuickSettings(.media)
		XCTAssertNil(root.presentedViewController)
	}

	func testTranslationSheetSavesOrDiscardsDraft() async throws {
		let original = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		let baseline = ArticleTranslationPreferences()
		try ArticleTranslationSettings.save(baseline, apiKey: "")
		defer { try? ArticleTranslationSettings.save(original, apiKey: originalKey) }
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		let root = UIViewController()
		window.rootViewController = root
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		for shouldSave in [false, true] {
			let sheet = ArticleQuickSettingsViewController(destination: .translation)
			var dismissCount = 0
			sheet.onDismiss = { dismissCount += 1 }
			root.present(sheet, animated: false)
			try await Task.sleep(for: .milliseconds(400))
			let field = try XCTUnwrap(views(of: UITextField.self, in: sheet.view).first { $0.text == baseline.baseURL })
			field.text = "https://example.invalid/draft"
			field.sendActions(for: .editingChanged)
			try await Task.sleep(for: .milliseconds(100))
			if shouldSave {
				try saveTranslation(in: sheet)
			} else {
				sheet.rootView.close()
			}
			try await waitUntil { root.presentedViewController == nil }
			XCTAssertEqual(dismissCount, 1)
			XCTAssertEqual(ArticleTranslationSettings.preferences.baseURL, shouldSave ? "https://example.invalid/draft" : baseline.baseURL)
		}
	}

	func testNativeAndPiPPlaybackFinishWhileQuickSettingsBlocksNavigation() {
		for pip in [false, true] {
			for autoNext in [false, true] {
				for nextVideo in [false, true] {
					XCTAssertEqual(VideoPlayerManager.playbackEndAction(isPiPActive: pip,
						pipAutoPlayNextVideo: true, autoGotoNextAfterVideo: autoNext, hasNextVideo: nextVideo,
						isArticleNavigationBlocked: true), .finish)
				}
			}
		}
		XCTAssertEqual(VideoPlayerManager.playbackEndAction(isPiPActive: true,
			pipAutoPlayNextVideo: true, autoGotoNextAfterVideo: true, hasNextVideo: true,
			isArticleNavigationBlocked: false), .playNextVideo)
	}

	func testQuickSettingsLabelsAreBundledInEnglishAndChinese() throws {
		for (language, title) in [("en", "Quick Settings"), ("zh-Hans", "快捷设置")] {
			let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
			let bundle = try XCTUnwrap(Bundle(path: path))
			XCTAssertEqual(bundle.localizedString(forKey: "Quick Settings", value: nil, table: "Localizable"), title)
		}
	}

	private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline {
			if predicate() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		XCTFail("Quick settings did not reach the expected presentation state", file: file, line: line)
		throw URLError(.timedOut)
	}

	private func views<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
		((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
	}

	private func saveTranslation(in sheet: ArticleQuickSettingsViewController) throws {
		let items = views(of: UINavigationBar.self, in: sheet.view).compactMap(\.topItem).flatMap {
			($0.rightBarButtonItems ?? []) + $0.trailingItemGroups.flatMap(\.barButtonItems)
		}
		let save = try XCTUnwrap(items.first)
		if let action = save.primaryAction {
			let control = UIControl()
			control.addAction(action, for: .primaryActionTriggered)
			control.sendActions(for: .primaryActionTriggered)
		} else {
			let action = try XCTUnwrap(save.action)
			XCTAssertTrue(UIApplication.shared.sendAction(action, to: save.target, from: save, for: nil))
		}
	}

	private func attach(_ window: UIWindow, name: String) {
		window.layoutIfNeeded()
		let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
			window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
		}
		let attachment = XCTAttachment(image: image)
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
#endif
