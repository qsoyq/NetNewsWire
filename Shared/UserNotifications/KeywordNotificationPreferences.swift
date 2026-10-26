import Foundation

struct KeywordNotificationPreferences {
	static let enabledKey = "keywordNotificationsEnabled"
	static let keywordsKey = "notificationKeywords"
	static let ignoresCaseKey = "notificationKeywordsIgnoreCase"
	static let blockingEnabledKey = "notificationKeywordBlockingEnabled"
	static let blockedKeywordsKey = "notificationBlockedKeywords"
	static let blockingIgnoresCaseKey = "notificationBlockedKeywordsIgnoreCase"
	static let matchesAuthorsKey = "notificationKeywordsMatchAuthors"
	static let blockingMatchesAuthorsKey = "notificationBlockedKeywordsMatchAuthors"

	var isEnabled = false
	var keywordsText = ""
	var ignoresCase = true
	var isBlockingEnabled = false
	var blockedKeywordsText = ""
	var blockingIgnoresCase = true
	var matchesAuthors = false
	var blockingMatchesAuthors = false

	static var current: Self {
		Self(isEnabled: UserDefaults.standard.bool(forKey: enabledKey),
			keywordsText: UserDefaults.standard.string(forKey: keywordsKey) ?? "",
			ignoresCase: UserDefaults.standard.object(forKey: ignoresCaseKey) as? Bool ?? true,
			isBlockingEnabled: UserDefaults.standard.bool(forKey: blockingEnabledKey),
			blockedKeywordsText: UserDefaults.standard.string(forKey: blockedKeywordsKey) ?? "",
			blockingIgnoresCase: UserDefaults.standard.object(forKey: blockingIgnoresCaseKey) as? Bool ?? true,
			matchesAuthors: UserDefaults.standard.bool(forKey: matchesAuthorsKey),
			blockingMatchesAuthors: UserDefaults.standard.bool(forKey: blockingMatchesAuthorsKey))
	}

	var keywords: [String] {
		Self.parseKeywords(keywordsText)
	}

	var blockedKeywords: [String] {
		Self.parseKeywords(blockedKeywordsText)
	}

	private static func parseKeywords(_ text: String) -> [String] {
		text.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}

}
