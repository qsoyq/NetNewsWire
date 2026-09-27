import XCTest
@testable import NetNewsWire

final class NotificationArticleGroupTests: XCTestCase {
	func testLegacyGroupSelectsOnlyDeliveredArticlesFromSelectedAccount() {
		let selected = notification("selected")
		let sameGroup = notification("same-group")
		let otherAccount = notification("other-account", accountID: "other")
		let otherThread = notification("other-thread", thread: "other-feed")
		let result = NotificationArticleGroup.select(from: [selected, sameGroup, otherAccount, otherThread], selected: selected)
		XCTAssertEqual(Set(result.map(\.requestIdentifier)), ["selected", "same-group"])
	}

	func testSelectedResponseIsIncludedWhenRemovedFromDeliveredSnapshot() {
		let selected = notification("selected")
		let result = NotificationArticleGroup.select(from: [notification("other")], selected: selected)
		XCTAssertEqual(Set(result.map(\.requestIdentifier)), ["selected", "other"])
	}

	func testEmptyThreadNeverSelectsOtherUngroupedNotifications() {
		let selected = notification("selected", thread: "")
		let result = NotificationArticleGroup.select(from: [notification("other", thread: "")], selected: selected)
		XCTAssertEqual(result.map(\.requestIdentifier), ["selected"])
	}

	func testInvalidSelectedArticleLeavesGroupUntouched() {
		let selected = DeliveredArticleNotification(requestIdentifier: "invalid", threadIdentifier: "feed", article: nil)
		XCTAssertTrue(NotificationArticleGroup.select(from: [notification("other")], selected: selected).isEmpty)
	}

	func testRemovalUsesSuccessfulArticlesInOriginalSnapshot() {
		let saved = notification("saved")
		let failed = notification("failed")
		let arrivedLater = notification("arrived-later")
		let marked = Set([saved.article!, arrivedLater.article!])
		XCTAssertEqual(NotificationArticleGroup.identifiersToRemove(from: [saved, failed], marked: marked), ["saved"])
	}

	func testNotificationAndThreadIdentifiersIncludeUnambiguousAccountIdentity() {
		XCTAssertNotEqual(NotificationArticleReference(accountID: "first", articleID: "shared").notificationIdentifier,
			NotificationArticleReference(accountID: "second", articleID: "shared").notificationIdentifier)
		XCTAssertNotEqual(NotificationArticleReference.threadIdentifier(accountID: "a:b", feedID: "c"),
			NotificationArticleReference.threadIdentifier(accountID: "a", feedID: "b:c"))
	}

	private func notification(_ id: String, accountID: String = "account", thread: String = "feed") -> DeliveredArticleNotification {
		DeliveredArticleNotification(requestIdentifier: id, threadIdentifier: thread,
			article: NotificationArticleReference(accountID: accountID, articleID: id))
	}
}
