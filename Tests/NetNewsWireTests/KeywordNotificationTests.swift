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

	func testSavedBlockingPreferencesAndDefaults() {
		let defaults = UserDefaults.standard
		let keys = [KeywordNotificationPreferences.blockingEnabledKey, KeywordNotificationPreferences.blockedKeywordsKey, KeywordNotificationPreferences.blockingIgnoresCaseKey]
		let saved = keys.map { defaults.object(forKey: $0) }
		defer {
			for (key, value) in zip(keys, saved) {
				defaults.set(value, forKey: key)
			}
		}
		for key in keys {
			defaults.removeObject(forKey: key)
		}
		XCTAssertFalse(KeywordNotificationPreferences.current.isBlockingEnabled)
		XCTAssertTrue(KeywordNotificationPreferences.current.blockedKeywords.isEmpty)
		XCTAssertTrue(KeywordNotificationPreferences.current.blockingIgnoresCase)

		defaults.set(true, forKey: KeywordNotificationPreferences.blockingEnabledKey)
		defaults.set("  Swift  \n\n 中文\r\n  ", forKey: KeywordNotificationPreferences.blockedKeywordsKey)
		defaults.set(false, forKey: KeywordNotificationPreferences.blockingIgnoresCaseKey)
		XCTAssertTrue(KeywordNotificationPreferences.current.isBlockingEnabled)
		XCTAssertEqual(KeywordNotificationPreferences.current.blockedKeywords, ["Swift", "中文"])
		XCTAssertFalse(KeywordNotificationPreferences.current.blockingIgnoresCase)
	}

	func testBlockedKeywordsOverrideFeedAndKeywordNotificationsAcrossArticleFields() {
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		defer { AccountManager.shared.deleteAccount(account) }
		let feed = account.createFeed(with: "Test feed", url: "https://example.invalid/blocked", feedID: "feed", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		let manager = UserNotificationManager.shared
		let articles = [
			article(title: "Swift BLOCKED", accountID: account.accountID),
			article(title: "Swift", text: "BLOCKED", accountID: account.accountID),
			article(title: "Swift", html: "<p>Tom &amp; Jerry</p>", accountID: account.accountID),
			article(title: "Swift", summary: "包含屏蔽词", accountID: account.accountID)
		]
		for (feedEnabled, keywordEnabled) in [(true, false), (false, true), (true, true)] {
			feed.newArticleNotificationsEnabled = feedEnabled
			var preferences = KeywordNotificationPreferences(isEnabled: keywordEnabled, keywordsText: "Swift", isBlockingEnabled: true, blockedKeywordsText: "blocked\nTom & Jerry\n屏蔽词")
			for item in articles {
				XCTAssertTrue(manager.notificationRequests(for: [item], preferences: preferences).isEmpty)
				preferences.isBlockingEnabled = false
				XCTAssertEqual(manager.notificationRequests(for: [item], preferences: preferences).count, 1)
				preferences.isBlockingEnabled = true
			}
			XCTAssertEqual(manager.notificationRequests(for: [article(title: "Swift release", accountID: account.accountID)], preferences: preferences).count, 1)
			preferences.blockedKeywordsText = " \n\t"
			XCTAssertEqual(manager.notificationRequests(for: [articles[0]], preferences: preferences).count, 1)
		}
	}

	func testBlockingCaseSensitivityIsIndependentOfNotificationKeywords() {
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		defer { AccountManager.shared.deleteAccount(account) }
		let feed = account.createFeed(with: "Test feed", url: "https://example.invalid/blocked-case", feedID: "feed", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		let item = article(title: "SWIFT", accountID: account.accountID)
		let manager = UserNotificationManager.shared
		var preferences = KeywordNotificationPreferences(isEnabled: true, keywordsText: "swift", isBlockingEnabled: true, blockedKeywordsText: "Swift", blockingIgnoresCase: false)
		XCTAssertEqual(manager.notificationRequests(for: [item], preferences: preferences).count, 1)
		preferences.blockingIgnoresCase = true
		preferences.ignoresCase = false
		feed.newArticleNotificationsEnabled = true
		XCTAssertTrue(manager.notificationRequests(for: [item], preferences: preferences).isEmpty)
		preferences.blockingIgnoresCase = false
		preferences.blockedKeywordsText = "SWIFT"
		XCTAssertTrue(manager.notificationRequests(for: [item], preferences: preferences).isEmpty)
	}

	func testAuthorMatchingPreferencesDefaultToOffAndPersistIndependently() {
		let defaults = UserDefaults.standard
		let keys = [KeywordNotificationPreferences.matchesAuthorsKey, KeywordNotificationPreferences.blockingMatchesAuthorsKey]
		let saved = keys.map { defaults.object(forKey: $0) }
		defer {
			for (key, value) in zip(keys, saved) {
				defaults.set(value, forKey: key)
			}
		}
		for key in keys {
			defaults.removeObject(forKey: key)
		}
		XCTAssertFalse(KeywordNotificationPreferences().matchesAuthors)
		XCTAssertFalse(KeywordNotificationPreferences().blockingMatchesAuthors)
		XCTAssertFalse(KeywordNotificationPreferences.current.matchesAuthors)
		XCTAssertFalse(KeywordNotificationPreferences.current.blockingMatchesAuthors)
		for matchesAuthors in [false, true] {
			for blockingMatchesAuthors in [false, true] {
				defaults.set(matchesAuthors, forKey: KeywordNotificationPreferences.matchesAuthorsKey)
				defaults.set(blockingMatchesAuthors, forKey: KeywordNotificationPreferences.blockingMatchesAuthorsKey)
				XCTAssertEqual(KeywordNotificationPreferences.current.matchesAuthors, matchesAuthors)
				XCTAssertEqual(KeywordNotificationPreferences.current.blockingMatchesAuthors, blockingMatchesAuthors)
			}
		}
	}

	func testAuthorTriggerAndBlockingSwitchesAreIndependentAcrossNotificationRoutes() throws {
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		defer { AccountManager.shared.deleteAccount(account) }
		let feed = account.createFeed(with: "Test feed", url: "https://example.invalid/authors", feedID: "feed", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		let author = try XCTUnwrap(Author(authorID: nil, name: "Jane Doe", url: nil, avatarURL: nil, emailAddress: nil))
		let item = article(title: "Ordinary article", accountID: account.accountID, authors: [author])
		let manager = UserNotificationManager.shared
		for feedEnabled in [false, true] {
			feed.newArticleNotificationsEnabled = feedEnabled
			for triggerEnabled in [false, true] {
				for blockingEnabled in [false, true] {
					for matchesAuthors in [false, true] {
						for blockingMatchesAuthors in [false, true] {
							let preferences = KeywordNotificationPreferences(isEnabled: triggerEnabled, keywordsText: "Jane", isBlockingEnabled: blockingEnabled, blockedKeywordsText: "Doe", matchesAuthors: matchesAuthors, blockingMatchesAuthors: blockingMatchesAuthors)
							let shouldNotify = (feedEnabled || (triggerEnabled && matchesAuthors)) && !(blockingEnabled && blockingMatchesAuthors)
							XCTAssertEqual(manager.notificationRequests(for: [item], preferences: preferences).count, shouldNotify ? 1 : 0)
							item.status.read = true
							XCTAssertTrue(manager.notificationRequests(for: [item], preferences: preferences).isEmpty)
							item.status.read = false
						}
					}
				}
			}
		}

		feed.newArticleNotificationsEnabled = false
		let titleMatch = article(title: "Swift", accountID: account.accountID, authors: [author])
		var preferences = KeywordNotificationPreferences(isEnabled: true, keywordsText: "Swift", isBlockingEnabled: true, blockedKeywordsText: "Jane", blockingMatchesAuthors: true)
		XCTAssertTrue(manager.notificationRequests(for: [titleMatch], preferences: preferences).isEmpty)
		preferences.blockingMatchesAuthors = false
		XCTAssertEqual(manager.notificationRequests(for: [titleMatch], preferences: preferences).count, 1)
	}

	func testAuthorMatchingUsesIndependentCaseSensitivityAndSupportsRSSNames() throws {
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		defer { AccountManager.shared.deleteAccount(account) }
		let feed = account.createFeed(with: "Test feed", url: "https://example.invalid/author-case", feedID: "feed", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		feed.newArticleNotificationsEnabled = false
		let authors = [
			try XCTUnwrap(Author(authorID: nil, name: "JANE DOE", url: nil, avatarURL: nil, emailAddress: nil)),
			try XCTUnwrap(Author(authorID: nil, name: nil, url: nil, avatarURL: nil, emailAddress: "jane@example.com (JANE DOE)"))
		]
		for author in authors {
			let item = article(accountID: account.accountID, authors: [author])
			for ignoresCase in [false, true] {
				for blockingIgnoresCase in [false, true] {
					let preferences = KeywordNotificationPreferences(isEnabled: true, keywordsText: "Jane Doe", ignoresCase: ignoresCase, isBlockingEnabled: true, blockedKeywordsText: "Jane Doe", blockingIgnoresCase: blockingIgnoresCase, matchesAuthors: true, blockingMatchesAuthors: true)
					XCTAssertEqual(UserNotificationManager.shared.notificationRequests(for: [item], preferences: preferences).count, ignoresCase && !blockingIgnoresCase ? 1 : 0)
				}
			}
		}
	}

	func testAuthorMatchingDoesNotFallBackToFeedAuthors() throws {
		let account = AccountManager.shared.createAccount(type: .onMyMac)
		defer { AccountManager.shared.deleteAccount(account) }
		let feed = account.createFeed(with: "Jane Doe", url: "https://example.invalid/feed-author", feedID: "feed", homePageURL: nil)
		account.addFeedToTreeAtTopLevel(feed)
		let author = try XCTUnwrap(Author(authorID: nil, name: "Jane Doe", url: nil, avatarURL: nil, emailAddress: nil))
		feed.authors = [author]
		let preferences = KeywordNotificationPreferences(isEnabled: true, keywordsText: "Jane", isBlockingEnabled: true, blockedKeywordsText: "Doe", matchesAuthors: true, blockingMatchesAuthors: true)
		for authors: Set<Author>? in [nil, []] {
			let item = article(accountID: account.accountID, authors: authors)
			feed.newArticleNotificationsEnabled = false
			XCTAssertTrue(UserNotificationManager.shared.notificationRequests(for: [item], preferences: preferences).isEmpty)
			feed.newArticleNotificationsEnabled = true
			XCTAssertEqual(UserNotificationManager.shared.notificationRequests(for: [item], preferences: preferences).count, 1)
		}
	}

	private func article(title: String? = nil, html: String? = nil, text: String? = nil, summary: String? = nil, accountID: String = "missing-account", authors: Set<Author>? = nil) -> Article {
		Article(accountID: accountID, articleID: "article", feedID: "feed", uniqueID: "article", title: title, contentHTML: html, contentText: text, markdown: nil, url: nil, externalURL: nil, summary: summary, imageURL: nil, datePublished: nil, dateModified: nil, authors: authors, status: ArticleStatus(articleID: "article", read: false, dateArrived: Date()))
	}
}
