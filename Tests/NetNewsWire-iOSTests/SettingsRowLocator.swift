#if os(iOS)
import XCTest
import UIKit
@testable import NetNewsWire

@MainActor func articleSettingsRow(_ identifier: String, in settings: SettingsViewController) throws -> IndexPath {
	settings.loadViewIfNeeded()
	let table = try XCTUnwrap(settings.tableView)
	for section in 0..<settings.numberOfSections(in: table) {
		for row in 0..<settings.tableView(table, numberOfRowsInSection: section) {
			let index = IndexPath(row: row, section: section)
			if settings.tableView(table, cellForRowAt: index).accessibilityIdentifier == identifier { return index }
		}
	}
	return try XCTUnwrap(nil as IndexPath?, "Missing settings row: \(identifier)")
}
#endif
