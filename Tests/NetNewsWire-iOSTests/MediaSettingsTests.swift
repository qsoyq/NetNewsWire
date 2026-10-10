#if os(iOS)
import XCTest
import UIKit
import SwiftUI
@testable import NetNewsWire

@MainActor final class MediaSettingsTests: XCTestCase {
	func testAllBindingsImmediatelyPersistOnlyTheirOriginalSetting() async throws {
		let original = snapshotSettings()
		defer { restoreSettings(original) }
		for setting in MediaSetting.allCases { AppDefaults.store.set(false, forKey: setting.rawValue) }
		let notifications = expectation(description: "Preview and prefetch change notifications")
		notifications.expectedFulfillmentCount = 4
		let observer = NotificationCenter.default.addObserver(forName: .videoPreviewSettingsDidChange, object: nil, queue: .main) { _ in notifications.fulfill() }
		defer { NotificationCenter.default.removeObserver(observer) }
		let model = MediaSettingsModel()
		XCTAssertEqual(MediaSetting.allCases.count, 10)
		for setting in MediaSetting.allCases {
			let binding = model.binding(for: setting)
			XCTAssertFalse(binding.wrappedValue)
			binding.wrappedValue = true
			XCTAssertTrue(AppDefaults.store.bool(forKey: setting.rawValue), setting.rawValue)
			XCTAssertTrue(MediaSettingsModel().binding(for: setting).wrappedValue)
			for other in MediaSetting.allCases where other != setting {
				XCTAssertFalse(AppDefaults.store.bool(forKey: other.rawValue), "Changing \(setting.rawValue) also changed \(other.rawValue)")
			}
			binding.wrappedValue = false
			XCTAssertFalse(AppDefaults.store.bool(forKey: setting.rawValue))
		}
		await fulfillment(of: [notifications], timeout: 1)
	}

	func testMainMediaRowOpensFormAndKeepsTranslationAndDisclosureEntrypoints() async throws {
		let settings = try settingsController()
		let navigation = UINavigationController(rootViewController: settings)
		let (window, previous) = try show(navigation)
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		let index = try articleSettingsRow("articles.media", in: settings)
		let row = settings.tableView(settings.tableView, cellForRowAt: index)
		XCTAssertEqual(row.accessoryType, .disclosureIndicator)
		XCTAssertEqual((row.viewWithTag(944) as? UILabel)?.text, NSLocalizedString("Media", comment: ""))
		_ = try articleSettingsRow("articles.translation", in: settings)
		_ = try articleSettingsRow("articles.autoExpandDetails.row", in: settings)
		settings.tableView(settings.tableView, didSelectRowAt: index)
		XCTAssertTrue(navigation.topViewController is UIHostingController<MediaSettingsView>)
		try await Task.sleep(for: .milliseconds(300))
		attach(window, name: "Media Settings Navigation")
	}

	func testClearConfirmationCancelAndConfirmForImagesVideosAndPreviewCache() async throws {
		let imageURL = URL(string: "https://example.invalid/media-cache-image-\(UUID().uuidString).jpg")!
		let videoURL = URL(string: "https://example.invalid/media-cache-video-\(UUID().uuidString).mp4")!
		let image = Data([1, 2, 3])
		let video = Data([4, 5, 6])
		let preview = Data([7, 8, 9])
		VideoCacheDatabase.shared.cacheData(url: imageURL.absoluteString, data: image, contentType: "image/jpeg")
		VideoCacheDatabase.shared.cacheData(url: videoURL.absoluteString, data: video, contentType: "video/mp4")
		let epoch = await VideoPreviewCache.shared.epoch()
		await VideoPreviewCache.shared.store(preview, for: videoURL, epoch: epoch)
		let settings = MediaSetting.allCases.map { AppDefaults.store.bool(forKey: $0.rawValue) }
		let model = MediaSettingsModel()
		let hosting = UIHostingController(rootView: MediaSettingsView(model: model))
		let (window, previous) = try show(UINavigationController(rootViewController: hosting))
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		try await Task.sleep(for: .milliseconds(300))
		model.requestCacheClear()
		var alert: UIAlertController?
		for _ in 0..<100 {
			alert = presentedAlert(window.rootViewController)
			if alert != nil { break }
			try await Task.sleep(for: .milliseconds(10))
		}
		let confirmation = try XCTUnwrap(alert)
		XCTAssertEqual(confirmation.title, NSLocalizedString("Clear Media Cache", comment: ""))
		XCTAssertEqual(confirmation.message, NSLocalizedString("Clear cached article images, videos, and first-frame previews?", comment: ""))
		XCTAssertEqual(Set(confirmation.actions.map(\.style)), Set([.cancel, .destructive]))
		XCTAssertEqual(Set(confirmation.actions.compactMap(\.title)), Set([
			NSLocalizedString("Cancel Media Cache Clear", comment: ""),
			NSLocalizedString("Confirm Media Cache Clear", comment: "")
		]))
		try await Task.sleep(for: .milliseconds(400))
		attach(window, name: "Media Cache Confirmation")
		model.cancelCacheClear()
		confirmation.dismiss(animated: false)
		XCTAssertFalse(model.showsCacheConfirmation)
		XCTAssertEqual(VideoCacheDatabase.shared.cachedData(for: imageURL.absoluteString)?.data, image)
		XCTAssertEqual(VideoCacheDatabase.shared.cachedData(for: videoURL.absoluteString)?.data, video)
		let preserved = await VideoPreviewCache.shared.data(for: videoURL)
		XCTAssertEqual(preserved, preview)
		model.requestCacheClear()
		await model.confirmCacheClear()
		XCTAssertFalse(model.showsCacheConfirmation)
		XCTAssertFalse(model.isClearingCache)
		XCTAssertNil(VideoCacheDatabase.shared.cachedData(for: imageURL.absoluteString))
		XCTAssertNil(VideoCacheDatabase.shared.cachedData(for: videoURL.absoluteString))
		let cleared = await VideoPreviewCache.shared.data(for: videoURL)
		XCTAssertNil(cleared)
		XCTAssertEqual(MediaSetting.allCases.map { AppDefaults.store.bool(forKey: $0.rawValue) }, settings)
	}

	func testMediaFormInLightDarkAndNarrowAccessibilitySize() async throws {
		let original = snapshotSettings()
		defer { restoreSettings(original) }
		for setting in MediaSetting.allCases { AppDefaults.store.set(true, forKey: setting.rawValue) }
		for style in [UIUserInterfaceStyle.light, .dark] {
			let hosting = UIHostingController(rootView: MediaSettingsView())
			let navigation = UINavigationController(rootViewController: hosting)
			let (window, previous) = try show(navigation)
			window.overrideUserInterfaceStyle = style
			try await Task.sleep(for: .milliseconds(400))
			attach(window, name: style == .light ? "Media Settings Light" : "Media Settings Dark")
			if let scroll = scrollView(in: hosting.view) {
				try await scrollToBottom(scroll)
				try await Task.sleep(for: .milliseconds(200))
				attach(window, name: style == .light ? "Media Settings Cache Light" : "Media Settings Cache Dark")
			}
			window.isHidden = true
			previous?.makeKeyAndVisible()
		}
		let hosting = UIHostingController(rootView: MediaSettingsView())
		hosting.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
		let navigation = UINavigationController(rootViewController: hosting)
		let (window, previous) = try show(navigation)
		defer { window.isHidden = true; previous?.makeKeyAndVisible() }
		window.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
		try await Task.sleep(for: .milliseconds(400))
		window.layoutIfNeeded()
		XCTAssertEqual(hosting.view.bounds.width, 320, accuracy: 1)
		attach(window, name: "Media Settings Narrow Large Text")
		if let scroll = scrollView(in: hosting.view) {
			try await scrollToBottom(scroll)
			try await Task.sleep(for: .milliseconds(300))
			attach(window, name: "Media Settings Narrow Large Text Cache")
		}
	}

	func testMediaLabelsAreBundledInEnglishAndSimplifiedChinese() throws {
		for (language, title) in [("en", "Media"), ("zh-Hans", "媒体")] {
			let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
			let bundle = try XCTUnwrap(Bundle(path: path))
			XCTAssertEqual(bundle.localizedString(forKey: "Media", value: nil, table: "Localizable"), title)
			let key = "Go to Next Article After Video Ends"
			let expected = language == "en" ? key : "播放结束后进入下一篇"
			XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: "Localizable"), expected)
			XCTAssertEqual(bundle.localizedString(forKey: "Cancel Media Cache Clear", value: nil, table: "Localizable"), language == "en" ? "Cancel" : "取消")
			XCTAssertEqual(bundle.localizedString(forKey: "Confirm Media Cache Clear", value: nil, table: "Localizable"), language == "en" ? "Clear" : "清除")
		}
	}

	private func snapshotSettings() -> [String: Any] {
		var values: [String: Any] = [:]
		for setting in MediaSetting.allCases {
			if let value = AppDefaults.store.object(forKey: setting.rawValue) { values[setting.rawValue] = value }
		}
		return values
	}
	private func restoreSettings(_ values: [String: Any]) {
		for setting in MediaSetting.allCases {
			if let value = values[setting.rawValue] {
				AppDefaults.store.set(value, forKey: setting.rawValue)
			} else {
				AppDefaults.store.removeObject(forKey: setting.rawValue)
			}
		}
		NotificationCenter.default.post(name: .videoPreviewSettingsDidChange, object: nil)
	}
	private func settingsController() throws -> SettingsViewController {
		try XCTUnwrap(UIStoryboard(name: "Settings", bundle: .main).instantiateViewController(withIdentifier: "SettingsViewController") as? SettingsViewController)
	}
	private func show(_ root: UIViewController) throws -> (UIWindow, UIWindow?) {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
		let previous = scene.windows.first(where: \.isKeyWindow)
		let window = UIWindow(windowScene: scene)
		window.rootViewController = root
		window.makeKeyAndVisible()
		return (window, previous)
	}
	private func presentedAlert(_ root: UIViewController?) -> UIAlertController? {
		guard let root else { return nil }
		if let alert = root as? UIAlertController { return alert }
		if let presented = root.presentedViewController, let alert = presentedAlert(presented) { return alert }
		for child in root.children { if let alert = presentedAlert(child) { return alert } }
		return nil
	}
	private func scrollView(in view: UIView) -> UIScrollView? {
		if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
		for child in view.subviews { if let scroll = scrollView(in: child) { return scroll } }
		return nil
	}
	private func scrollToBottom(_ scroll: UIScrollView) async throws {
		// Form estimates offscreen row heights; allow each newly visible row to measure.
		for _ in 0..<6 {
			scroll.layoutIfNeeded()
			scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
			try await Task.sleep(for: .milliseconds(50))
		}
	}
	private func attach(_ window: UIWindow, name: String) {
		window.layoutIfNeeded()
		let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
		let attachment = XCTAttachment(image: image)
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
#endif
