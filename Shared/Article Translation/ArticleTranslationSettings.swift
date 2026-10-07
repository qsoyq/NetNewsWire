import Foundation
import Security

enum ArticleTranslationDisplayMode: String, Codable, CaseIterable, Identifiable {
	case bilingual
	case replaceOriginal
	var id: Self { self }
	var title: String { ArticleTranslationStrings.text(self == .bilingual ? "Below Original" : "Replace Original") }
}

enum ArticleTranslationLanguage: String, Codable, CaseIterable, Identifiable {
	case simplifiedChinese = "简体中文"
	case traditionalChinese = "繁体中文"
	case japanese = "日语"
	case english = "英语"
	var id: Self { self }
	var title: String {
		switch self {
		case .simplifiedChinese: ArticleTranslationStrings.text("Simplified Chinese")
		case .traditionalChinese: ArticleTranslationStrings.text("Traditional Chinese")
		case .japanese: ArticleTranslationStrings.text("Japanese")
		case .english: ArticleTranslationStrings.text("English")
		}
	}
	var languageTag: String {
		switch self {
		case .simplifiedChinese: "zh-Hans"
		case .traditionalChinese: "zh-Hant"
		case .japanese: "ja"
		case .english: "en"
		}
	}
}

struct ArticleTranslationPreferences: Codable, Equatable {
	static let defaultPath = "/responses"
	var baseURL = "https://api.openai.com/v1"
	var path = ""
	var model = ""
	var language = ArticleTranslationLanguage.simplifiedChinese
	var displayMode = ArticleTranslationDisplayMode.bilingual
	var automaticallyTranslate = false
	var prefetchNextArticleTranslation = false
	var manuallyTranslate = false
	var concurrentRequests = 4

	var isEnabled: Bool { automaticallyTranslate || manuallyTranslate }
	init() {}

	private enum CodingKeys: String, CodingKey {
		case baseURL, path, model, language, displayMode, automaticallyTranslate, prefetchNextArticleTranslation, manuallyTranslate, concurrentRequests
	}

	init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
		path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
		model = try values.decodeIfPresent(String.self, forKey: .model) ?? model
		displayMode = try values.decodeIfPresent(ArticleTranslationDisplayMode.self, forKey: .displayMode) ?? .bilingual
		automaticallyTranslate = try values.decodeIfPresent(Bool.self, forKey: .automaticallyTranslate) ?? false
		prefetchNextArticleTranslation = try values.decodeIfPresent(Bool.self, forKey: .prefetchNextArticleTranslation) ?? false
		manuallyTranslate = try values.decodeIfPresent(Bool.self, forKey: .manuallyTranslate) ?? false
		concurrentRequests = min(8, max(1, try values.decodeIfPresent(Int.self, forKey: .concurrentRequests) ?? 4))
		let savedLanguage = try values.decodeIfPresent(String.self, forKey: .language) ?? language.rawValue
		language = ArticleTranslationLanguage(rawValue: savedLanguage) ?? {
			switch savedLanguage.lowercased() {
			case "en", "english": .english
			case "ja", "japanese", "日本語": .japanese
			case "zh-hant", "zh-tw", "繁體中文": .traditionalChinese
			default: .simplifiedChinese
			}
		}()
		// Old preferences stored either a base address or the complete Responses URL.
		if !values.contains(.path), var components = URLComponents(string: baseURL) {
			var oldPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			if oldPath == "responses" { oldPath = "" }
			else if oldPath.hasSuffix("/responses") { oldPath.removeLast("/responses".count) }
			else if oldPath.isEmpty { oldPath = "v1" }
			components.path = oldPath.isEmpty ? "" : "/" + oldPath
			baseURL = components.string ?? baseURL
		}
	}
}

@MainActor enum ArticleTranslationSettings {
	static let didChange = Notification.Name("ArticleTranslationSettingsDidChange")
	private static let preferencesKey = "ArticleTranslationPreferences"
	private static var keychainQuery: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "NetNewsWire") + ".articleTranslation",
		 kSecAttrAccount as String: "apiKey"]
	}

	static var preferences: ArticleTranslationPreferences {
		guard let data = UserDefaults.standard.data(forKey: preferencesKey),
			let preferences = try? JSONDecoder().decode(ArticleTranslationPreferences.self, from: data) else {
			return ArticleTranslationPreferences()
		}
		return preferences
	}

	static func apiKey() throws -> String {
		var query = keychainQuery
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound {
			return ""
		}
		guard status == errSecSuccess, let data = result as? Data else {
			throw KeychainError(status: status)
		}
		return String(decoding: data, as: UTF8.self)
	}

	static func configuration() throws -> ArticleTranslationConfiguration {
		let settings = preferences
		return try ArticleTranslationConfiguration(baseURL: settings.baseURL, path: settings.path, apiKey: apiKey(), model: settings.model, language: settings.language.rawValue)
	}

	static func save(_ preferences: ArticleTranslationPreferences, apiKey: String) throws {
		let data = try JSONEncoder().encode(preferences)
		let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		if preferences.isEnabled {
			_ = try ArticleTranslationConfiguration(baseURL: preferences.baseURL, path: preferences.path, apiKey: secret, model: preferences.model, language: preferences.language.rawValue)
		}
		var status: OSStatus
		if secret.isEmpty {
			status = SecItemDelete(keychainQuery as CFDictionary)
			if status == errSecItemNotFound { status = errSecSuccess }
		} else {
			let attributes = [kSecValueData as String: Data(secret.utf8)]
			status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
			if status == errSecItemNotFound {
				var query = keychainQuery
				query.merge(attributes) { _, value in value }
				query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
				status = SecItemAdd(query as CFDictionary, nil)
			}
		}
		guard status == errSecSuccess else {
			throw KeychainError(status: status)
		}
		UserDefaults.standard.set(data, forKey: preferencesKey)
		NotificationCenter.default.post(name: didChange, object: nil)
	}

	private struct KeychainError: LocalizedError {
		let status: OSStatus
		var errorDescription: String? {
			String.localizedStringWithFormat(ArticleTranslationStrings.text("Unable to access the translation API key in Keychain (%ld)."), Int(status))
		}
	}
}
