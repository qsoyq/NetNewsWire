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
		if let scroll = scrollView(in: narrow.view) {
			for _ in 0..<6 {
				scroll.layoutIfNeeded()
				scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
				try await Task.sleep(for: .milliseconds(50))
			}
			attach(window, name: "Notifications Narrow Large Text Keywords")
		}
	}

	func testNotificationLabelsAreBundledInEnglishAndChinese() throws {
		for (language, expected) in [("en", "Keyword Notifications"), ("zh-Hans", "关键词通知")] {
			let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
			let bundle = try XCTUnwrap(Bundle(path: path))
			XCTAssertEqual(bundle.localizedString(forKey: "Keyword Notifications", value: nil, table: "Localizable"), expected)
			XCTAssertEqual(bundle.localizedString(forKey: "Ignore Case", value: nil, table: "Localizable"), language == "en" ? "Ignore Case" : "忽略大小写")
		}
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
