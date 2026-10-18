import XCTest
import Articles
@testable import Account
@testable import NetNewsWire

@MainActor final class KeywordNotificationTests: XCTestCase {
	func testSavedPreferencesAreReadForFutureDownloads() {
		let defaults = UserDefaults.standard
		let enabled = defaults.object(forKey: KeywordNotificationPreferences.enabledKey)
		let keywords = defaults.object(forKey: KeywordNotificationPreferences.keywordsKey)
		let ignoresCase = defaults.object(forKey: KeywordNotificationPreferences.ignoresCaseKey)
		defer {
			defaults.set(enabled, forKey: KeywordNotificationPreferences.enabledKey)
			defaults.set(keywords, forKey: KeywordNotificationPreferences.keywordsKey)
			defaults.set(ignoresCase, forKey: KeywordNotificationPreferences.ignoresCaseKey)
		}
		defaults.set(true, forKey: KeywordNotificationPreferences.enabledKey)
		defaults.set("Swift\n中文", forKey: KeywordNotificationPreferences.keywordsKey)
		defaults.removeObject(forKey: KeywordNotificationPreferences.ignoresCaseKey)
		XCTAssertEqual(KeywordNotificationPreferences.current.keywords, ["Swift", "中文"])
		XCTAssertTrue(KeywordNotificationPreferences.current.isEnabled)
		XCTAssertTrue(KeywordNotificationPreferences.current.ignoresCase)
		defaults.set(false, forKey: KeywordNotificationPreferences.ignoresCaseKey)
		XCTAssertFalse(KeywordNotificationPreferences.current.ignoresCase)
		defaults.set(true, forKey: KeywordNotificationPreferences.ignoresCaseKey)
		XCTAssertTrue(KeywordNotificationPreferences.current.ignoresCase)
		defaults.set(false, forKey: KeywordNotificationPreferences.enabledKey)
		XCTAssertFalse(KeywordNotificationPreferences.current.isEnabled)
	}

	func testFeedAndKeywordRoutesShareOneRequestAndFeedGroup() throws {
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		defer { AccountManager.shared.deleteAccount(account) }
		let feed = account.createFeed(with: "Test feed", url: "https://example.invalid/notifications", feedID: "feed", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		let matching = article(title: "Swift", accountID: account.accountID)
		let preferences = KeywordNotificationPreferences(isEnabled: true, keywordsText: "Swift\nswift\nRelease")
		let manager = UserNotificationManager.shared

		feed.newArticleNotificationsEnabled = false
		let keywordRequests = manager.notificationRequests(for: [matching], preferences: preferences)
		XCTAssertEqual(keywordRequests.count, 1)
		let keywordRequest = try XCTUnwrap(keywordRequests.first)
		XCTAssertEqual(keywordRequest.content.threadIdentifier, NotificationArticleReference.threadIdentifier(accountID: account.accountID, feedID: feed.feedID))
		XCTAssertEqual(keywordRequest.content.title, feed.nameForDisplay)
		XCTAssertEqual(UserNotificationManager.articleReference(from: keywordRequest.content.userInfo), NotificationArticleReference(accountID: account.accountID, articleID: matching.articleID))
		XCTAssertFalse(keywordRequest.content.categoryIdentifier.isEmpty)
		XCTAssertNotNil(keywordRequest.content.sound)

		feed.newArticleNotificationsEnabled = true
		let bothRequests = manager.notificationRequests(for: [matching], preferences: preferences)
		XCTAssertEqual(bothRequests.count, 1)
		XCTAssertEqual(bothRequests.first?.identifier, keywordRequest.identifier)
		XCTAssertEqual(bothRequests.first?.content.threadIdentifier, keywordRequest.content.threadIdentifier)
		XCTAssertEqual(manager.notificationRequests(for: [matching], preferences: .init()).count, 1)
		matching.status.read = true
		XCTAssertTrue(manager.notificationRequests(for: [matching], preferences: preferences).isEmpty)
		matching.status.read = false
		feed.newArticleNotificationsEnabled = false
		XCTAssertTrue(manager.notificationRequests(for: [matching], preferences: .init()).isEmpty)
		XCTAssertTrue(manager.notificationRequests(for: [article(title: "Unrelated", accountID: account.accountID)], preferences: preferences).isEmpty)
	}

	func testCaseSensitivityControlsKeywordNotificationsButNotFeedNotifications() {
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		defer { AccountManager.shared.deleteAccount(account) }
		let feed = account.createFeed(with: "Test feed", url: "https://example.invalid/case", feedID: "feed", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		let manager = UserNotificationManager.shared
		let matching = article(title: "SWIFT", accountID: account.accountID)
		var preferences = KeywordNotificationPreferences(isEnabled: true, keywordsText: "Swift", ignoresCase: false)
		XCTAssertTrue(manager.notificationRequests(for: [matching], preferences: preferences).isEmpty)
		preferences.ignoresCase = true
		XCTAssertEqual(manager.notificationRequests(for: [matching], preferences: preferences).count, 1)
		preferences.isEnabled = false
		XCTAssertTrue(manager.notificationRequests(for: [matching], preferences: preferences).isEmpty)
		feed.newArticleNotificationsEnabled = true
		preferences.ignoresCase = false
		XCTAssertEqual(manager.notificationRequests(for: [matching], preferences: preferences).count, 1)
	}

	private func article(title: String? = nil, html: String? = nil, text: String? = nil, summary: String? = nil, accountID: String = "missing-account") -> Article {
		Article(accountID: accountID, articleID: "article", feedID: "feed", uniqueID: "article", title: title, contentHTML: html, contentText: text, markdown: nil, url: nil, externalURL: nil, summary: summary, imageURL: nil, datePublished: nil, dateModified: nil, authors: nil, status: ArticleStatus(articleID: "article", read: false, dateArrived: Date()))
	}
}
