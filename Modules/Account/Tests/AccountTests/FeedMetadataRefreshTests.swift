import XCTest
import RSWeb
@testable import Account

@MainActor final class FeedMetadataRefreshTests: XCTestCase {
	private var directory: URL!
	private var account: Account!
	private var feed: Feed!
	private var delegate: ReaderAPIAccountDelegate!

	override func setUp() async throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		TestingURLProtocol.reset()
		account = Account(dataFolder: directory.path, type: .freshRSS, accountID: UUID().uuidString)
		delegate = try XCTUnwrap(account.delegate as? ReaderAPIAccountDelegate)
		feed = account.createFeed(with: "Original", url: "https://old.example/feed", feedID: "feed/1", homePageURL: "https://old.example/")
		feed.externalID = feed.feedID
		account.addFeedToTreeAtTopLevel(feed)
	}

	override func tearDown() async throws {
		feed = nil
		delegate = nil
		account = nil
		try? FileManager.default.removeItem(at: directory)
		directory = nil
	}

	func testURLRefreshPreservesIdentityPreferencesAndFolderRelationship() async throws {
		feed.editedName = "My Name"
		feed.newArticleNotificationsEnabled = true
		feed.readerViewAlwaysEnabled = true
		feed.folderRelationship = ["Folder": "remote-folder"]
		feed.conditionalGetInfo = HTTPConditionalGetInfo(lastModified: "old", etag: "old")
		let folder = try XCTUnwrap(account.ensureFolder(with: "Folder"))
		folder.externalID = "remote-folder"
		folder.addFeedToTreeAtTopLevel(feed)
		account.removeFeedFromTreeAtTopLevel(feed)

		let count = try await delegate.updateExistingFeedMetadata(account: account, subscriptions: [subscription()])
		XCTAssertEqual(count, 1)
		XCTAssertTrue(account.existingFeed(withFeedID: "feed/1") === feed)
		XCTAssertTrue(folder.topLevelFeeds.contains(feed))
		XCTAssertEqual(feed.url, "https://new.example/feed")
		XCTAssertNil(account.existingFeed(withURL: "https://old.example/feed"))
		XCTAssertTrue(account.existingFeed(withURL: "https://new.example/feed") === feed)
		XCTAssertEqual(feed.name, "Remote Name")
		XCTAssertEqual(feed.editedName, "My Name")
		XCTAssertEqual(feed.homePageURL, "https://new.example/")
		XCTAssertEqual(feed.faviconURL, "https://new.example/icon.png")
		XCTAssertTrue(feed.newArticleNotificationsEnabled)
		XCTAssertTrue(feed.readerViewAlwaysEnabled)
		XCTAssertEqual(feed.folderRelationship, ["Folder": "remote-folder"])
		XCTAssertNil(feed.conditionalGetInfo)
	}

	func testNewURLAndLocalSettingsSurviveAccountReload() async throws {
		feed.editedName = "Local"
		feed.newArticleNotificationsEnabled = true
		_ = try await delegate.updateExistingFeedMetadata(account: account, subscriptions: [subscription()])
		let reloaded = Account(dataFolder: directory.path, type: .freshRSS, accountID: account.accountID)
		let restored = try XCTUnwrap(reloaded.existingFeed(withFeedID: "feed/1"))
		XCTAssertEqual(restored.url, "https://new.example/feed")
		XCTAssertEqual(restored.homePageURL, "https://new.example/")
		XCTAssertEqual(restored.name, "Remote Name")
		XCTAssertEqual(restored.editedName, "Local")
		XCTAssertTrue(restored.newArticleNotificationsEnabled)
		let database = FeedSettingsDatabase(databasePath: directory.appendingPathComponent("FeedSettings.db").path)
		XCTAssertNil(database.allRows()["https://old.example/feed"])
		XCTAssertEqual(database.allRows()["https://new.example/feed"]?.feedID, "feed/1")
	}

	func testNumericFeedIDWithoutURLIsRejectedAndKeepsMetadata() async throws {
		do {
			_ = try await delegate.updateExistingFeedMetadata(account: account, subscriptions: [subscription(url: nil)])
			XCTFail("Expected an invalid URL response")
		} catch ReaderAPIAccountDelegateError.invalidResponse { }
		XCTAssertEqual(feed.url, "https://old.example/feed")
		XCTAssertEqual(feed.name, "Original")
	}

	func testIncompleteSubscriptionSnapshotDoesNotRemoveFeed() async throws {
		do {
			_ = try await delegate.updateExistingFeedMetadata(account: account, subscriptions: [])
			XCTFail("Expected a missing subscription error")
		} catch ReaderAPIAccountDelegateError.invalidResponse { }
		XCTAssertTrue(account.existingFeed(withFeedID: "feed/1") === feed)
	}

	func testConflictingURLDoesNotOverwriteOtherFeedsSettings() async throws {
		let other = account.createFeed(with: "Other", url: "https://new.example/feed", feedID: "feed/2", homePageURL: nil)
		other.editedName = "Other Local"
		account.addFeedToTreeAtTopLevel(other)
		do {
			try await account.updateURL("https://new.example/feed", for: feed)
			XCTFail("Expected a conflicting URL error")
		} catch AccountError.createErrorAlreadySubscribed { }
		XCTAssertEqual(feed.url, "https://old.example/feed")
		XCTAssertEqual(other.editedName, "Other Local")
	}

	func testOPMLWriteFailureRestoresOldURLAndSettingsBinding() async throws {
		feed.editedName = "Local"
		try await account.persistFeedMetadata()
		let opml = directory.appendingPathComponent("Subscriptions.opml")
		try FileManager.default.removeItem(at: opml)
		try FileManager.default.createDirectory(at: opml, withIntermediateDirectories: true)
		do {
			try await account.updateURL("https://new.example/feed", for: feed)
			XCTFail("Expected a persistence error")
		} catch { }
		XCTAssertEqual(feed.url, "https://old.example/feed")
		feed.editedName = "Still Local"
		try FileManager.default.removeItem(at: opml)
		try await account.persistFeedMetadata()
		let database = FeedSettingsDatabase(databasePath: directory.appendingPathComponent("FeedSettings.db").path)
		XCTAssertEqual(database.allRows()["https://old.example/feed"]?.editedName, "Still Local")
	}

	func testOrdinaryFreshRSSSyncUsesSameURLUpdatePath() async throws {
		feed.editedName = "Local"
		try await delegate.syncFeeds(account, [subscription()])
		XCTAssertEqual(feed.url, "https://new.example/feed")
		XCTAssertEqual(feed.editedName, "Local")
	}

	func testSubscriptionRequestReportsMissingOptionalMetadata() async throws {
		account.endpointURL = URL(string: "https://example.com/")
		TestingURLProtocol.setResponse("subscription/list", file: "JSON/ReaderAPI/feed-metadata-missing-icon.json")
		let result = try await account.refreshFeedMetadata()
		XCTAssertEqual(result.updatedCount, 1)
		XCTAssertEqual(result.incompleteCount, 1)
		XCTAssertEqual(feed.url, "https://new.example/feed")
		XCTAssertEqual(feed.name, "Remote Name")
	}

	private func subscription(url: String? = "https://new.example/feed") -> ReaderAPISubscription {
		ReaderAPISubscription(feedID: "feed/1", name: "Remote Name", categories: [], feedURL: url,
			homePageURL: "https://new.example/", iconURL: "https://new.example/icon.png")
	}
}
