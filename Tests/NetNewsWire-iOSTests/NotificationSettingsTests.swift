#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import NetNewsWire

@MainActor final class NotificationSettingsTests: XCTestCase {
	func testNotificationRowOpensSettingsAndRendersChineseAtNarrowWidth() async throws {
		let settings = try XCTUnwrap(UIStoryboard(name: "Settings", bundle: .main).instantiateViewController(withIdentifier: "SettingsViewController") as? SettingsViewController)
		let navigation = UINavigationController(rootViewController: settings)
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		window.rootViewController = navigation
		window.makeKeyAndVisible()
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		settings.loadViewIfNeeded()
		let index = IndexPath(row: 0, section: 0)
		let cell = settings.tableView(settings.tableView, cellForRowAt: index)
		XCTAssertEqual(cell.accessibilityIdentifier, "settings.notifications")
		XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
		settings.tableView(settings.tableView, didSelectRowAt: index)
		XCTAssertTrue(navigation.topViewController is UIHostingController<NotificationSettingsView>)
		try await Task.sleep(for: .milliseconds(400))
		for style in [UIUserInterfaceStyle.light, .dark] {
			window.overrideUserInterfaceStyle = style
			try await Task.sleep(for: .milliseconds(150))
			window.layoutIfNeeded()
			attach(window, name: style == .light ? "Notifications Light" : "Notifications Dark")
		}
		let narrow = UIHostingController(rootView: NotificationSettingsView().environment(\.locale, Locale(identifier: "zh-Hans")))
		narrow.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
		navigation.setViewControllers([narrow], animated: false)
		window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
		try await Task.sleep(for: .milliseconds(300))
		window.layoutIfNeeded()
		XCTAssertEqual(narrow.view.bounds.width, 375, accuracy: 1)
		attach(window, name: "Notifications Narrow Large Text")
		let scroll = try XCTUnwrap(scrollView(in: narrow.view))
		for page in 0..<20 {
			window.layoutIfNeeded()
			attach(window, name: "Notifications Narrow Large Text Page \(page)")
			let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
			if scroll.contentOffset.y >= bottom - 1 {
				break
			}
			let next = min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.6)
			scroll.setContentOffset(CGPoint(x: 0, y: next), animated: false)
			try await Task.sleep(for: .milliseconds(100))
		}
		attach(window, name: "Notifications Narrow Large Text Keywords")
	}

	func testAuthorSwitchesPersistIndependentlyWhileNotificationRoutesAreDisabled() async throws {
		let defaults = UserDefaults.standard
		let authorKeys = [KeywordNotificationPreferences.blockingMatchesAuthorsKey, KeywordNotificationPreferences.matchesAuthorsKey]
		let keys = authorKeys + [KeywordNotificationPreferences.enabledKey, KeywordNotificationPreferences.blockingEnabledKey, KeywordNotificationPreferences.ignoresCaseKey, KeywordNotificationPreferences.blockingIgnoresCaseKey]
		let saved = keys.map { defaults.object(forKey: $0) }
		defer {
			for (key, value) in zip(keys, saved) {
				defaults.set(value, forKey: key)
			}
		}
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		for authorKey in authorKeys {
			for key in keys {
				defaults.set(key == authorKey, forKey: key)
			}
			let hosting = UIHostingController(rootView: NotificationSettingsView())
			window.rootViewController = UINavigationController(rootViewController: hosting)
			window.makeKeyAndVisible()
			try await Task.sleep(for: .milliseconds(300))
			let scroll = try XCTUnwrap(scrollView(in: hosting.view))
			var authorSwitch: UISwitch?
			// SwiftUI keeps identifiers in its accessibility tree, not on the backing UISwitch.
			// Only the selected author preference is enabled, so exercise that native control.
			for _ in 0..<20 {
				window.layoutIfNeeded()
				if let toggle = switches(in: hosting.view).first(where: \.isOn) {
					authorSwitch = toggle
					break
				}
				let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
				scroll.setContentOffset(CGPoint(x: 0, y: min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.6)), animated: false)
				try await Task.sleep(for: .milliseconds(100))
			}
			let toggle = try XCTUnwrap(authorSwitch, "Missing author switch for \(authorKey)")
			XCTAssertTrue(toggle.isEnabled)
			for value in [false, true] {
				toggle.setOn(value, animated: false)
				toggle.sendActions(for: .valueChanged)
				try await Task.sleep(for: .milliseconds(100))
				XCTAssertEqual(defaults.bool(forKey: authorKey), value)
				for otherKey in keys where otherKey != authorKey {
					XCTAssertFalse(defaults.bool(forKey: otherKey))
				}
			}
		}
	}

	func testNotificationLabelsAreBundledInEnglishAndChinese() throws {
		for (language, expected) in [("en", "Keyword Notifications"), ("zh-Hans", "关键词通知")] {
			let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
			let bundle = try XCTUnwrap(Bundle(path: path))
			XCTAssertEqual(bundle.localizedString(forKey: "Keyword Notifications", value: nil, table: "Localizable"), expected)
			XCTAssertEqual(bundle.localizedString(forKey: "Ignore Case", value: nil, table: "Localizable"), language == "en" ? "Ignore Case" : "忽略大小写")
			XCTAssertEqual(bundle.localizedString(forKey: "Block Notifications by Keyword", value: nil, table: "Localizable"), language == "en" ? "Block Notifications by Keyword" : "通知关键词屏蔽")
			XCTAssertEqual(bundle.localizedString(forKey: "Blocked Keywords", value: nil, table: "Localizable"), language == "en" ? "Blocked Keywords" : "屏蔽关键词")
			XCTAssertEqual(bundle.localizedString(forKey: "Match Author Names", value: nil, table: "Localizable"), language == "en" ? "Match Author Names" : "匹配作者名称")
		}
	}

	private func switches(in view: UIView) -> [UISwitch] {
		((view as? UISwitch).map { [$0] } ?? []) + view.subviews.flatMap { switches(in: $0) }
	}

	private func scrollView(in view: UIView) -> UIScrollView? {
		if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
			return scroll
		}
		for child in view.subviews {
			if let scroll = scrollView(in: child) {
				return scroll
			}
		}
		return nil
	}

	private func attach(_ window: UIWindow, name: String) {
		let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
			window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
		}
		let attachment = XCTAttachment(image: image)
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
#endif
