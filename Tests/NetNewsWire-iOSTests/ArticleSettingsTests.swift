#if os(iOS)
import XCTest
import UIKit
import SwiftUI
@testable import NetNewsWire

@MainActor final class ArticleSettingsTests: XCTestCase {
	func testBindingsPreserveExistingValuesAndOnlyChangeTheirOriginalKeys() {
		let original = ArticleSetting.allCases.map { AppDefaults.store.object(forKey: $0.rawValue) }
		defer {
			for (setting, value) in zip(ArticleSetting.allCases, original) {
				if let value { AppDefaults.store.set(value, forKey: setting.rawValue) }
				else { AppDefaults.store.removeObject(forKey: setting.rawValue) }
			}
		}
		XCTAssertEqual(ArticleSetting.allCases, [.doubleTapToGoBack, .automaticallyExpandArticleDetails])
		for enabled in [false, true] {
			for setting in ArticleSetting.allCases {
				AppDefaults.store.set(enabled, forKey: setting.rawValue)
			}
			let model = ArticleSettingsModel()
			for setting in ArticleSetting.allCases {
				let binding = model.binding(for: setting)
				XCTAssertEqual(binding.wrappedValue, enabled)
				binding.wrappedValue = !enabled
				XCTAssertEqual(AppDefaults.store.bool(forKey: setting.rawValue), !enabled)
				XCTAssertEqual(ArticleSettingsModel().binding(for: setting).wrappedValue, !enabled)
				for other in ArticleSetting.allCases where other != setting {
					XCTAssertEqual(AppDefaults.store.bool(forKey: other.rawValue), enabled)
				}
				binding.wrappedValue = enabled
			}
		}
	}

	func testMainSettingsOpensArticleFormAndRemovesInlineSwitches() throws {
		let settings = try XCTUnwrap(UIStoryboard(name: "Settings", bundle: .main)
			.instantiateViewController(withIdentifier: "SettingsViewController") as? SettingsViewController)
		let navigation = UINavigationController(rootViewController: settings)
		let index = try articleSettingsRow("articles.settings", in: settings)
		let cell = settings.tableView(settings.tableView, cellForRowAt: index)
		XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
		XCTAssertEqual((cell.viewWithTag(945) as? UILabel)?.text, ArticleQuickSettingsDestination.article.title)
		let count = settings.tableView(settings.tableView, numberOfRowsInSection: index.section)
		XCTAssertEqual(count, settings.traitCollection.userInterfaceIdiom == .phone ? 8 : 7)
		for row in 0..<count {
			let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: row, section: index.section))
			XCTAssertNil(cell.viewWithTag(942), "Auto-expand must no longer appear inline")
			XCTAssertFalse(labels(in: cell).contains { $0.text == ArticleSetting.doubleTapToGoBack.title })
		}
		_ = try articleSettingsRow("articles.media", in: settings)
		_ = try articleSettingsRow("articles.translation", in: settings)
		settings.tableView(settings.tableView, didSelectRowAt: index)
		XCTAssertTrue(navigation.topViewController is UIHostingController<ArticleSettingsView>)
		XCTAssertEqual(ArticleQuickSettingsDestination.allCases, [.article, .media, .translation, .cache])
	}

	func testArticleFormAtNarrowWidthWithLargeText() async throws {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		let hosting = UIHostingController(rootView: ArticleSettingsView())
		hosting.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
		window.rootViewController = UINavigationController(rootViewController: hosting)
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		window.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
		try await Task.sleep(for: .milliseconds(400))
		window.layoutIfNeeded()
		XCTAssertEqual(hosting.view.bounds.width, 320, accuracy: 1)
		let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
			window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
		}
		let attachment = XCTAttachment(image: image)
		attachment.name = "Article Settings Narrow Large Text"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	func testArticleLabelsAreBundledInEnglishAndChinese() throws {
		let translations = [
			"Article Settings": "文章设置",
			"Double-Tap to Go Back": "双击返回",
			"Automatically Expand Collapsed Content": "自动展开折叠正文"
		]
		for language in ["en", "zh-Hans"] {
			let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
			let bundle = try XCTUnwrap(Bundle(path: path))
			for (key, chinese) in translations {
				XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: "Localizable"), language == "en" ? key : chinese)
			}
		}
	}

	private func labels(in view: UIView) -> [UILabel] {
		((view as? UILabel).map { [$0] } ?? []) + view.subviews.flatMap { labels(in: $0) }
	}
}
#endif
