#if os(macOS)
import AppKit
import XCTest

@testable import NetNewsWire

@MainActor final class SidebarDefaultsNotificationTests: XCTestCase {
	func testBackgroundDefaultsNotificationUpdatesSidebarOnMainActor() async throws {
		let controller = SidebarViewController()
		_ = controller.view
		let expected = AppDefaults.shared.hideReadFolders
		controller.treeControllerDelegate.isReadFoldersFiltered = !expected

		await Task.detached {
			NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
		}.value

		for _ in 0..<100 {
			if controller.treeControllerDelegate.isReadFoldersFiltered == expected {
				break
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		XCTAssertEqual(controller.treeControllerDelegate.isReadFoldersFiltered, expected)
	}
}
#endif
