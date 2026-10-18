import Foundation

struct KeywordNotificationPreferences {
	static let enabledKey = "keywordNotificationsEnabled"
	static let keywordsKey = "notificationKeywords"
	static let ignoresCaseKey = "notificationKeywordsIgnoreCase"

	var isEnabled = false
	var keywordsText = ""
	var ignoresCase = true

	static var current: Self {
		Self(isEnabled: UserDefaults.standard.bool(forKey: enabledKey),
			keywordsText: UserDefaults.standard.string(forKey: keywordsKey) ?? "",
			ignoresCase: UserDefaults.standard.object(forKey: ignoresCaseKey) as? Bool ?? true)
	}

	var keywords: [String] {
		keywordsText.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}

}
