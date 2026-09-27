import Foundation

struct NotificationArticleReference: Hashable, Sendable {
	let accountID: String
	let articleID: String

	var notificationIdentifier: String {
		"article:\(accountID.utf8.count):\(accountID):\(articleID)"
	}

	static func threadIdentifier(accountID: String, feedID: String) -> String {
		"feed:\(accountID.utf8.count):\(accountID):\(feedID)"
	}
}

struct DeliveredArticleNotification: Sendable {
	let requestIdentifier: String
	let threadIdentifier: String
	let article: NotificationArticleReference?
}

enum NotificationArticleGroup {

	static func select(from delivered: [DeliveredArticleNotification], selected: DeliveredArticleNotification) -> [DeliveredArticleNotification] {
		guard let selectedArticle = selected.article else { return [] }
		guard !selected.threadIdentifier.isEmpty else { return [selected] }

		var notifications = delivered.filter {
			$0.threadIdentifier == selected.threadIdentifier && $0.article?.accountID == selectedArticle.accountID
		}
		// The response itself was delivered, even if iOS removed it before the snapshot was read.
		if !notifications.contains(where: { $0.requestIdentifier == selected.requestIdentifier }) {
			notifications.append(selected)
		}
		return notifications
	}

	static func identifiersToRemove(from notifications: [DeliveredArticleNotification], marked: Set<NotificationArticleReference>) -> [String] {
		notifications.compactMap {
			guard let reference = $0.article, marked.contains(reference) else { return nil }
			return $0.requestIdentifier
		}
	}
}
