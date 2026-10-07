#if os(iOS)
import XCTest
import UIKit
import SwiftUI
@testable import NetNewsWire

@MainActor final class ArticleTranslationSettingsTests: XCTestCase {
	func testSettingsSaveKeyInKeychainAndKeepItOutOfPreferences() throws {
		let originalPreferences = ArticleTranslationSettings.preferences
		let originalKey = try ArticleTranslationSettings.apiKey()
		defer { try? ArticleTranslationSettings.save(originalPreferences, apiKey: originalKey) }
		var preferences = ArticleTranslationPreferences()
		preferences.baseURL = "https://example.com/v1"
		preferences.model = "test-model"
		preferences.path = "/custom/responses"
		preferences.language = .traditionalChinese
		preferences.displayMode = .replaceOriginal
		preferences.automaticallyTranslate = true
		preferences.prefetchNextArticleTranslation = true
		preferences.manuallyTranslate = true
		try ArticleTranslationSettings.save(preferences, apiKey: "nnw-validation-key")
		XCTAssertEqual(ArticleTranslationSettings.preferences, preferences)
		XCTAssertEqual(try ArticleTranslationSettings.apiKey(), "nnw-validation-key")
		let storedData = try XCTUnwrap(UserDefaults.standard.data(forKey: "ArticleTranslationPreferences"))
		XCTAssertFalse(String(decoding: storedData, as: UTF8.self).contains("nnw-validation-key"))
	}

	func testSettingsRowOpensTranslationFormInLightAndDarkAppearance() async throws {
		_ = try ArticleTranslationSettings.apiKey()
		let storyboard = UIStoryboard(name: "Settings", bundle: .main)
		let settings = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "SettingsViewController") as? SettingsViewController)
		let navigation = UINavigationController(rootViewController: settings)
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previousWindow = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		window.rootViewController = navigation
		window.makeKeyAndVisible()
		defer {
			window.isHidden = true
			previousWindow?.makeKeyAndVisible()
		}
		settings.loadViewIfNeeded()
		let translationRow = IndexPath(row: 12, section: 4)
		let cell = settings.tableView(settings.tableView, cellForRowAt: translationRow)
		XCTAssertEqual((cell.viewWithTag(941) as? UILabel)?.text, ArticleTranslationStrings.text("Article Translation"))
		XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
		settings.tableView(settings.tableView, didSelectRowAt: translationRow)
		XCTAssertTrue(navigation.topViewController is UIHostingController<ArticleTranslationSettingsView>)
		for style in [UIUserInterfaceStyle.light, .dark] {
			window.overrideUserInterfaceStyle = style
			try await Task.sleep(for: .milliseconds(600))
			window.layoutIfNeeded()
			let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
			let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
			let attachment = XCTAttachment(image: image)
			attachment.name = style == .light ? "Translation Settings Light" : "Translation Settings Dark"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
	}
}
#endif
